-- Draconic Reactor CC Controller (techsmoke fork)
-- Target: single monitor, robust failsafes, user-set output lock until CRIT.
-- Install layout (CraftOS): reactor, lib/f, lib/button (no .lua)
-- Repo layout (GitHub): reactor.lua, f.lua, button.lua

os.loadAPI("lib/f")
os.loadAPI("lib/button")

-- =========================
-- Config (your spec)
-- =========================
local MODE_STABLE = "STABLE"
local MODE_FILL   = "FILL"

local cfg = {
  mode = MODE_STABLE,

  -- Output control: user target, CC may clamp only at/above CRIT conditions.
  targetOutput = 600000,   -- RF/t (or OP/t, whatever the gate uses)

  -- Temp fail-safe (same for both modes)
  tempWarn     = 5000,
  tempCrit     = 6000,
  tempShutdown = 6500,

  -- Field fail-safe (same for both modes)
  fieldTargetStable = 25,  -- %
  fieldTargetFill   = 85,  -- % "voll rein"
  fieldWarn   = 20,        -- %
  fieldCrit   = 15,        -- %
  fieldFail   = 10,        -- % trigger
  fieldRelease= 50,        -- % release threshold (conservative)

  -- Input gate regulation aggressiveness (ΔRF/t per tick)
  -- Tick here is control loop interval (default 0.2s).
  stableStep  = 25000,     -- slow correction
  fillStep    = 120000,    -- fast correction
  critStepMul = 3.0,       -- when in WARN/CRIT, multiply step

  -- Gate bounds
  inputMin = 10,           -- keep at least 10 so detection stays sane
  inputMax = 10000000,     -- 10M RF/t cap (adjust if you want)
  outputMin = 0,
  outputMax = 100000000,   -- 100M cap (adjust)

  -- Recovery behavior
  autoCharge = true,
  autoActivate = true,

  -- UI
  uiFps = 6,               -- limit redraw rate to stop flicker
  loopDt = 0.2,            -- control tick
}

local CFG_PATH = "reactorconfig.txt"

local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function pct(n, d)
  if not n or not d or d == 0 then return 0 end
  local v = (n / d) * 100
  if v ~= v or v == math.huge or v == -math.huge then return 0 end
  return v
end

local function safeCall(obj, method, ...)
  if not obj or type(method) ~= "string" then return false end
  if type(obj[method]) ~= "function" then return false end
  local ok, res = pcall(obj[method], ...)
  return ok, res
end

local function reactorStop(r)
  if safeCall(r, "shutdownReactor") then return true end
  if safeCall(r, "stopReactor") then return true end
  if safeCall(r, "deactivateReactor") then return true end
  return false
end

local function reactorCharge(r)
  return safeCall(r, "chargeReactor")
end

local function reactorActivate(r)
  return safeCall(r, "activateReactor")
end

local function saveCfg()
  local fcfg = fs.open(CFG_PATH, "w")
  fcfg.writeLine(cfg.mode)
  fcfg.writeLine(tostring(cfg.targetOutput))
  fcfg.close()
end

local function loadCfg()
  if not fs.exists(CFG_PATH) then
    saveCfg()
    return
  end
  local fcfg = fs.open(CFG_PATH, "r")
  local m = fcfg.readLine()
  local to = fcfg.readLine()
  fcfg.close()
  if m == MODE_STABLE or m == MODE_FILL then cfg.mode = m end
  if to then cfg.targetOutput = tonumber(to) or cfg.targetOutput end
end

-- =========================
-- Peripherals
-- =========================
local monitor = f.periphSearch("monitor")
local reactor = f.periphSearch("draconic_reactor")

if not monitor then error("No valid monitor was found") end
if not reactor then error("No reactor was found") end

local monX, monY = monitor.getSize()
local mon = { monitor = monitor, X = monX, Y = monY }
f.firstSet(mon)

-- Flow gate detection (set INPUT low-signal to 10 manually once)
local function detectFlowGates()
  local gates = { peripheral.find("flow_gate") }
  if #gates < 2 then error("Less than 2 flow gates detected!") end

  print("Set INPUT flow gate low-signal to 10 (manual). Waiting for detection...")
  local inputGate, outputGate, inputName, outputName

  while not inputGate do
    sleep(1)
    for _, name in pairs(peripheral.getNames()) do
      if peripheral.getType(name) == "flow_gate" then
        local gate = peripheral.wrap(name)
        local ok, setFlow = pcall(gate.getSignalLowFlow)
        if ok and setFlow == 10 then
          inputGate, inputName = gate, name
        else
          outputGate, outputName = gate, name
        end
      end
    end
  end

  if not outputGate then error("Could not identify output gate!") end

  local fh = fs.open("flowgate_names.txt", "w")
  fh.writeLine(inputName)
  fh.writeLine(outputName)
  fh.close()

  return inputGate, outputGate, inputName, outputName
end

local function loadFlowGates()
  if not fs.exists("flowgate_names.txt") then return nil end
  local fh = fs.open("flowgate_names.txt", "r")
  local inName = fh.readLine()
  local outName = fh.readLine()
  fh.close()
  if inName and outName and peripheral.isPresent(inName) and peripheral.isPresent(outName) then
    return peripheral.wrap(inName), peripheral.wrap(outName), inName, outName
  end
  return nil
end

local inputGate, outputGate = loadFlowGates()
if not inputGate or not outputGate then
  inputGate, outputGate = detectFlowGates()
end

-- =========================
-- Gate helpers
-- =========================
local function getLow(g)
  local ok, v = pcall(g.getSignalLowFlow)
  if not ok then return 0 end
  return tonumber(v) or 0
end

local function setLow(g, v)
  v = math.floor((tonumber(v) or 0) + 0.5)
  return pcall(g.setSignalLowFlow, v)
end

-- =========================
-- UI
-- =========================
local lastDraw = 0
local lastUi = {}

local function bar(width, percent)
  percent = clamp(percent, 0, 100)
  local fill = math.floor((percent / 100) * width + 0.5)
  return string.rep("#", fill) .. string.rep("-", width - fill)
end

local function writeAt(x, y, txt, col)
  monitor.setCursorPos(x, y)
  if col then monitor.setTextColor(col) end
  monitor.write(txt)
end

local function clearLine(y)
  monitor.setCursorPos(1, y)
  monitor.write(string.rep(" ", monX))
end

local function drawIfChanged(key, y, line, col)
  if lastUi[key] ~= line then
    clearLine(y)
    writeAt(1, y, line, col)
    lastUi[key] = line
  end
end

local function fmtNum(n)
  n = tonumber(n) or 0
  if n >= 1e9 then return string.format("%.2fG", n/1e9) end
  if n >= 1e6 then return string.format("%.2fM", n/1e6) end
  if n >= 1e3 then return string.format("%.1fk", n/1e3) end
  return tostring(math.floor(n+0.5))
end

local function setButtons()
  button.clearTable()

  local y = 1
  button.setButton("mode", "MODE", function()
    cfg.mode = (cfg.mode == MODE_STABLE) and MODE_FILL or MODE_STABLE
    saveCfg()
  end, 1, y, 6, y+1, nil, nil, colors.blue)

  button.setButton("stop", "STOP", function()
    reactorStop(reactor)
  end, 8, y, 13, y+1, nil, nil, colors.red)

  button.setButton("charge", "CHRG", function()
    reactorCharge(reactor)
  end, 15, y, 20, y+1, nil, nil, colors.orange)

  button.setButton("start", "START", function()
    reactorActivate(reactor)
  end, 22, y, 28, y+1, nil, nil, colors.green)

  local y2 = 4
  button.setButton("out-100k", "-100k", function()
    cfg.targetOutput = clamp(cfg.targetOutput - 100000, cfg.outputMin, cfg.outputMax)
    saveCfg()
  end, 1, y2, 7, y2+1, nil, nil, colors.gray)

  button.setButton("out-10k", "-10k", function()
    cfg.targetOutput = clamp(cfg.targetOutput - 10000, cfg.outputMin, cfg.outputMax)
    saveCfg()
  end, 9, y2, 14, y2+1, nil, nil, colors.gray)

  button.setButton("out+10k", "+10k", function()
    cfg.targetOutput = clamp(cfg.targetOutput + 10000, cfg.outputMin, cfg.outputMax)
    saveCfg()
  end, 16, y2, 21, y2+1, nil, nil, colors.gray)

  button.setButton("out+100k", "+100k", function()
    cfg.targetOutput = clamp(cfg.targetOutput + 100000, cfg.outputMin, cfg.outputMax)
    saveCfg()
  end, 23, y2, 29, y2+1, nil, nil, colors.gray)

  button.screen(monitor)
end

local function initUi()
  monitor.setTextScale(0.5)
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  monitor.setCursorPos(1,1)
  monitor.setTextColor(colors.white)
  setButtons()
end

-- =========================
-- Control state machine
-- =========================
local STATE_NORMAL   = "NORMAL"
local STATE_WARN     = "WARN"
local STATE_CRIT     = "CRIT"
local STATE_FAILSAFE = "FAILSAFE"
local STATE_SHUTDOWN = "SHUTDOWN"

local state = STATE_NORMAL
local lastTemp = nil
local lastTempTime = nil
local safetyClampOut = nil

local function classify(temp, fieldP)
  if temp >= cfg.tempShutdown then return STATE_SHUTDOWN end
  if fieldP <= cfg.fieldFail then return STATE_FAILSAFE end
  if temp >= cfg.tempCrit or fieldP <= cfg.fieldCrit then return STATE_CRIT end
  if temp >= cfg.tempWarn or fieldP <= cfg.fieldWarn then return STATE_WARN end
  return STATE_NORMAL
end

local function computeTempRate(temp, now)
  if not lastTemp or not lastTempTime then
    lastTemp, lastTempTime = temp, now
    return 0
  end
  local dt = now - lastTempTime
  if dt <= 0 then return 0 end
  local rate = (temp - lastTemp) / dt
  lastTemp, lastTempTime = temp, now
  return rate
end

local function getFuelPercent(ri)
  local used = pct(ri.fuelConversion, ri.maxFuelConversion)
  return clamp(100 - used, 0, 100)
end

local function desiredFieldTarget()
  return (cfg.mode == MODE_FILL) and cfg.fieldTargetFill or cfg.fieldTargetStable
end

local function controlTick()
  local ri = reactor.getReactorInfo()
  if not ri then error("Reactor invalid: getReactorInfo returned nil") end

  local now = os.clock()
  local temp = tonumber(ri.temperature) or 0
  local fieldP = pct(ri.fieldStrength, ri.maxFieldStrength)
  local satP = pct(ri.energySaturation, ri.maxEnergySaturation)
  local fuelP = getFuelPercent(ri)
  local gen = tonumber(ri.generationRate) or 0
  local fieldIn = tonumber(ri.fieldInputRate) or 0
  local status = tostring(ri.status or "unknown")
  local tempRate = computeTempRate(temp, now)

  local newState = classify(temp, fieldP)

  -- Hard actions
  if newState == STATE_SHUTDOWN then
    state = STATE_SHUTDOWN
    reactorStop(reactor)
    setLow(inputGate, cfg.inputMax)
    setLow(outputGate, 0)
    safetyClampOut = 0
  elseif newState == STATE_FAILSAFE then
    state = STATE_FAILSAFE
    reactorStop(reactor)
    setLow(inputGate, cfg.inputMax)
    setLow(outputGate, 0)
    safetyClampOut = 0
  else
    if state == STATE_FAILSAFE then
      if fieldP >= cfg.fieldRelease and temp < cfg.tempCrit then
        safetyClampOut = nil
        state = newState
        if cfg.autoCharge then reactorCharge(reactor) end
        if cfg.autoActivate then reactorActivate(reactor) end
      else
        setLow(inputGate, cfg.inputMax)
        setLow(outputGate, 0)
      end
    else
      state = newState
    end
  end

  -- Output application
  local appliedOut = cfg.targetOutput
  local inCrit = (state == STATE_CRIT) or (state == STATE_SHUTDOWN) or (state == STATE_FAILSAFE)

  if inCrit then
    local curOut = getLow(outputGate)
    if not safetyClampOut then safetyClampOut = curOut end

    local sev = 0
    if temp >= cfg.tempCrit then sev = sev + (temp - cfg.tempCrit) / 200 end
    if fieldP <= cfg.fieldCrit then sev = sev + (cfg.fieldCrit - fieldP) / 2 end
    if tempRate > 50 then sev = sev + 1 end

    local drop = 200000 * clamp(sev, 0, 10)
    safetyClampOut = clamp((safetyClampOut or curOut) - drop, cfg.outputMin, cfg.outputMax)
    appliedOut = math.min(cfg.targetOutput, safetyClampOut)
  else
    safetyClampOut = nil
    appliedOut = cfg.targetOutput
  end

  setLow(outputGate, clamp(appliedOut, cfg.outputMin, cfg.outputMax))

  -- Recover output under WARN
  if temp < cfg.tempWarn and fieldP > cfg.fieldWarn then
    setLow(outputGate, clamp(cfg.targetOutput, cfg.outputMin, cfg.outputMax))
  end

  -- Field control (mode speed differs)
  local targetField = desiredFieldTarget()
  local curIn = getLow(inputGate)
  local step = (cfg.mode == MODE_FILL) and cfg.fillStep or cfg.stableStep

  if state == STATE_WARN or state == STATE_CRIT then
    step = step * cfg.critStepMul
  end

  if tempRate > 60 then step = step * 1.75
  elseif tempRate > 30 then step = step * 1.35 end

  local err = targetField - fieldP
  local newIn = curIn
  if math.abs(err) >= 0.5 then
    newIn = (err > 0) and (curIn + step) or (curIn - step)
  end

  -- Force upward when field is low
  if fieldP <= cfg.fieldWarn then newIn = curIn + step * 2 end
  if fieldP <= cfg.fieldCrit then newIn = curIn + step * 4 end

  newIn = clamp(newIn, cfg.inputMin, cfg.inputMax)
  setLow(inputGate, newIn)

  -- UI
  local drawPeriod = 1 / cfg.uiFps
  if now - lastDraw >= drawPeriod then
    lastDraw = now

    drawIfChanged("mode", 7, string.format("Mode: %s | Target OUT: %s", cfg.mode, fmtNum(cfg.targetOutput)), colors.white)
    drawIfChanged("state", 8, string.format("State: %s | Stat: %s", state, status), colors.white)

    drawIfChanged("temp", 10, string.format("Temp: %sC (dT %.1f/s)  W %d C %d SD %d",
      fmtNum(temp), tempRate, cfg.tempWarn, cfg.tempCrit, cfg.tempShutdown),
      (temp >= cfg.tempCrit) and colors.red or (temp >= cfg.tempWarn and colors.orange or colors.lime))

    drawIfChanged("field", 11, string.format("Field: %.2f%%  W %d C %d F %d REL %d",
      fieldP, cfg.fieldWarn, cfg.fieldCrit, cfg.fieldFail, cfg.fieldRelease),
      (fieldP <= cfg.fieldCrit) and colors.red or (fieldP <= cfg.fieldWarn and colors.orange or colors.lime))

    drawIfChanged("satfuel", 12, string.format("Saturation: %.2f%% | Fuel: %.2f%%", satP, fuelP), colors.white)
    drawIfChanged("rates", 13, string.format("Gen: %s/t | FieldIn: %s/t", fmtNum(gen), fmtNum(fieldIn)), colors.white)
    drawIfChanged("gates", 14, string.format("Gate IN: %s | Gate OUT: %s", fmtNum(getLow(inputGate)), fmtNum(getLow(outputGate))), colors.white)

    local bw = math.max(10, monX - 12)
    drawIfChanged("bar_field", 16, "Field ["..bar(bw, fieldP).."]", colors.white)
    drawIfChanged("bar_sat",   17, "Sat   ["..bar(bw, satP).."]", colors.white)
    drawIfChanged("bar_fuel",  18, "Fuel  ["..bar(bw, fuelP).."]", colors.white)
  end
end

-- =========================
-- Main
-- =========================
loadCfg()
initUi()

setLow(outputGate, clamp(cfg.targetOutput, cfg.outputMin, cfg.outputMax))
if getLow(inputGate) < cfg.inputMin then setLow(inputGate, cfg.inputMin) end

local function mainLoop()
  while true do
    controlTick()
    sleep(cfg.loopDt)
  end
end

parallel.waitForAny(mainLoop, button.clickEvent)
