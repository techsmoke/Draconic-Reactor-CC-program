-- Draconic Reactor CC Controller (techsmoke)
-- CraftOS files (no .lua): reactor, lib/f, lib/button
-- NOTE: This version keeps the original UI/output controls and ONLY patches field behaviour:
--  * STABLE: generation-tiered field target with hysteresis (25% / 50% / FULL)
--  * FILL: always FULL field input (99.999T RF/t)

os.loadAPI("lib/f")
os.loadAPI("lib/button")

-- --- Button API compatibility (older/newer button.lua variants) ---
if type(button) ~= "table" then error("button API not loaded (lib/button)") end
if type(button.clearTable) ~= "function" then
  function button.clearTable()
    for k,v in pairs(button) do
      if type(v)=="table" and v.xmin and v.xmax and v.ymin and v.ymax then button[k]=nil end
    end
  end
end
if type(button.setMonitors) ~= "function" then function button.setMonitors(_) end end
if type(button.clickEvent) ~= "function" then
  -- minimal monitor_touch dispatcher for button rectangles
  function button.clickEvent()
    while true do
      local _, _, x, y = os.pullEvent("monitor_touch")
      for _,b in pairs(button) do
        if type(b)=="table" and b.func and x>=b.xmin and x<=b.xmax and y>=b.ymin and y<=b.ymax then
          pcall(b.func)
        end
      end
    end
  end
end
-- ------------------------------------------------------------------

local MODE_STABLE = "STABLE"
local MODE_FILL   = "FILL"

local cfg = {
  mode = MODE_STABLE,
  targetOutput = 600000,

  tempWarn = 5000,
  tempCrit = 6000,
  tempShutdown = 6500,

  -- OLD behaviour kept for UI; values still displayed.
  fieldTargetStable = 25,
  fieldTargetFill   = 85,

  fieldWarn = 20,
  fieldCrit = 15,
  fieldFail = 10,
  fieldRelease = 50,

  inputMin = 10,
  inputMax = 10000000,

  outputMin = 0,
  outputMax = 100000000,

  loopDt = 0.2,
  uiFps = 6,

  stableStepFast = 25000,
  stableStepSlow = 6000,
  fillStep = 120000,

  safetyStepMulWarn = 2.0,
  safetyStepMulCrit = 3.5,

  stableDeadbandLo = 24.5,
  stableDeadbandHi = 25.5,

  alarmRedstoneSide = "top",
  alarmSpeakerEnabled = true,
  alarmRepeatMs = 3000,

  -- ===== PATCH: tiered generation control (ONLY behavioural change) =====
  genLowToMidUp     = 4200000,  -- 4.2M
  genMidToLowDown   = 3800000,  -- 3.8M
  genMidToHighUp    = 5200000,  -- 6.2M
  genHighToMidDown  = 4900000,  -- 5.8M

  fieldTargetLow = 25,
  fieldTargetMid = 50,

  fullFieldInput = 99999000000000, -- 99.999T RF/t (set injector gate LOW to this)
  -- =====================================================================
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

local function fmtNum(n)
  n = tonumber(n) or 0
  if n >= 1e12 then return string.format("%.3fT", n/1e12) end
  if n >= 1e9  then return string.format("%.2fG", n/1e9) end
  if n >= 1e6  then return string.format("%.2fM", n/1e6) end
  if n >= 1e3  then return string.format("%.1fk", n/1e3) end
  return tostring(math.floor(n+0.5))
end

local function safeCall(obj, method, ...)
  if not obj or type(method) ~= "string" then return false end
  if type(obj[method]) ~= "function" then return false end
  return pcall(obj[method], ...)
end

local function reactorStop(r)
  if safeCall(r, "shutdownReactor") then return true end
  if safeCall(r, "stopReactor") then return true end
  if safeCall(r, "deactivateReactor") then return true end
  return false
end
local function reactorCharge(r) safeCall(r, "chargeReactor") end
local function reactorActivate(r) safeCall(r, "activateReactor") end

local function saveCfg()
  local h = fs.open(CFG_PATH, "w")
  h.writeLine(cfg.mode)
  h.writeLine(tostring(cfg.targetOutput))
  h.close()
end

local function loadCfg()
  if not fs.exists(CFG_PATH) then saveCfg(); return end
  local h = fs.open(CFG_PATH, "r")
  local m = h.readLine()
  local to = h.readLine()
  h.close()
  if m == MODE_STABLE or m == MODE_FILL then cfg.mode = m end
  if to then cfg.targetOutput = tonumber(to) or cfg.targetOutput end
end

local monitor = f.periphSearch("monitor")
local reactor = f.periphSearch("draconic_reactor")
if not monitor then error("No monitor found") end
if not reactor then error("No draconic_reactor found") end

local speakers = { peripheral.find("speaker") }

local function wrapGate(name)
  if name and peripheral.isPresent(name) and peripheral.getType(name) == "flow_gate" then
    return peripheral.wrap(name)
  end
  return nil
end

local function loadFlowGates()
  if not fs.exists("flowgate_names.txt") then return nil end
  local h = fs.open("flowgate_names.txt", "r")
  local inName = h.readLine()
  local outName = h.readLine()
  h.close()
  local gIn = wrapGate(inName)
  local gOut = wrapGate(outName)
  if gIn and gOut and inName ~= outName then return gIn, gOut end
  return nil
end

local function detectFlowGates()
  local gateNames = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "flow_gate" then gateNames[#gateNames+1] = n end
  end
  if #gateNames < 2 then error("Need at least 2 flow_gates") end
  print("SETUP: Set INPUT flow gate (injector) Signal LOW to 10 RF/t...")
  local deadline = os.clock() + 120
  while os.clock() < deadline do
    local foundIn, foundOut
    for _, name in ipairs(gateNames) do
      local g = peripheral.wrap(name)
      local ok, v = pcall(g.getSignalLowFlow)
      if ok then
        if v == 10 then foundIn = name else foundOut = name end
      end
    end
    if foundIn and foundOut and foundIn ~= foundOut then
      local h = fs.open("flowgate_names.txt", "w")
      h.writeLine(foundIn)
      h.writeLine(foundOut)
      h.close()
      return peripheral.wrap(foundIn), peripheral.wrap(foundOut)
    end
    sleep(0.25)
  end
  -- PATCH: no newline inside string
  error("Flow gate detection timeout. Set INPUT gate Signal LOW = 10 RF/t.")
end

local gateIn, gateOut = loadFlowGates()
if not gateIn or not gateOut then gateIn, gateOut = detectFlowGates() end

local function getLow(g)
  local ok, v = pcall(g.getSignalLowFlow)
  if not ok then return 0 end
  return tonumber(v) or 0
end
local function setLow(g, v)
  v = math.floor((tonumber(v) or 0) + 0.5)
  pcall(g.setSignalLowFlow, v)
end

-- Alarm
local alarmOn = false
local lastAlarmPlay = 0
local function alarmSet(on, _msg)
  alarmOn = on and true or false
  if cfg.alarmRedstoneSide and cfg.alarmRedstoneSide ~= "" then
    pcall(redstone.setOutput, cfg.alarmRedstoneSide, alarmOn)
  end
end

local function alarmLoop()
  while true do
    if alarmOn then
      local now = os.epoch("utc") or 0
      if cfg.alarmSpeakerEnabled and (now - lastAlarmPlay >= cfg.alarmRepeatMs) then
        lastAlarmPlay = now
        if #speakers == 0 then speakers = { peripheral.find("speaker") } end
        for _, sp in ipairs(speakers) do
          pcall(sp.playSound, "minecraft:block.note_block.pling", 1.0, 1.0)
        end
      end
    end
    sleep(0.25)
  end
end

-- UI helpers
monitor.setTextScale(0.5)
local monX, monY = monitor.getSize()
local lastDraw = 0
local lastUi = {}

local function bar(width, percent)
  percent = clamp(percent, 0, 100)
  local fill = math.floor((percent / 100) * width + 0.5)
  return string.rep("#", fill) .. string.rep("-", width - fill)
end

local function clearLine(y)
  monitor.setCursorPos(1, y)
  monitor.write(string.rep(" ", monX))
end

local function drawIfChanged(key, y, line, col)
  if lastUi[key] ~= line then
    clearLine(y)
    monitor.setCursorPos(1, y)
    if col then monitor.setTextColor(col) end
    monitor.write(line)
    lastUi[key] = line
  end
end

local function initUi()
  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.white)
  monitor.clear()

  button.clearTable()
  local y = 1
  button.setButton("mode", "MODE", function()
    cfg.mode = (cfg.mode == MODE_STABLE) and MODE_FILL or MODE_STABLE
    saveCfg()
  end, 1, y, 6, y+1, nil, nil, colors.blue)

  button.setButton("stop", "STOP", function() reactorStop(reactor) end, 8, y, 13, y+1, nil, nil, colors.red)
  button.setButton("charge", "CHRG", function() reactorCharge(reactor) end, 15, y, 20, y+1, nil, nil, colors.orange)
  button.setButton("start", "START", function() reactorActivate(reactor) end, 22, y, 28, y+1, nil, nil, colors.green)

  local y2 = 4
  button.setButton("out-100k", "-100k", function()
    cfg.targetOutput = clamp(cfg.targetOutput - 100000, cfg.outputMin, cfg.outputMax); saveCfg()
  end, 1, y2, 7, y2+1, nil, nil, colors.gray)

  button.setButton("out-10k", "-10k", function()
    cfg.targetOutput = clamp(cfg.targetOutput - 10000, cfg.outputMin, cfg.outputMax); saveCfg()
  end, 9, y2, 14, y2+1, nil, nil, colors.gray)

  button.setButton("out+10k", "+10k", function()
    cfg.targetOutput = clamp(cfg.targetOutput + 10000, cfg.outputMin, cfg.outputMax); saveCfg()
  end, 16, y2, 21, y2+1, nil, nil, colors.gray)

  button.setButton("out+100k", "+100k", function()
    cfg.targetOutput = clamp(cfg.targetOutput + 100000, cfg.outputMin, cfg.outputMax); saveCfg()
  end, 23, y2, 29, y2+1, nil, nil, colors.gray)

  button.screen(monitor)
end

-- State machine
local STATE_NORMAL   = "NORMAL"
local STATE_WARN     = "WARN"
local STATE_CRIT     = "CRIT"
local STATE_FAILSAFE = "FAILSAFE"
local STATE_SHUTDOWN = "SHUTDOWN"

local state = STATE_NORMAL
local safetyClampOut = nil

local function classify(temp, fieldP)
  if temp >= cfg.tempShutdown then return STATE_SHUTDOWN end
  if fieldP <= cfg.fieldFail then return STATE_FAILSAFE end
  if temp >= cfg.tempCrit or fieldP <= cfg.fieldCrit then return STATE_CRIT end
  if temp >= cfg.tempWarn or fieldP <= cfg.fieldWarn then return STATE_WARN end
  return STATE_NORMAL
end

local function fuelPercent(ri)
  local used = pct(ri.fuelConversion, ri.maxFuelConversion)
  return clamp(100 - used, 0, 100)
end

local function fieldStep(fieldP)
  if cfg.mode == MODE_FILL then return cfg.fillStep end
  if fieldP >= 30 then return cfg.stableStepFast end
  if fieldP >= 23 and fieldP <= 28 then return cfg.stableStepSlow end
  return cfg.stableStepFast
end

-- ===== PATCH: generation-tiered stable field behaviour with hysteresis =====
local fieldTier = "LOW" -- LOW / MID / HIGH
local function updateFieldTier(gen)
  if fieldTier == "LOW" then
    if gen >= cfg.genLowToMidUp then fieldTier = "MID" end
  elseif fieldTier == "MID" then
    if gen >= cfg.genMidToHighUp then fieldTier = "HIGH"
    elseif gen <= cfg.genMidToLowDown then fieldTier = "LOW" end
  elseif fieldTier == "HIGH" then
    if gen <= cfg.genHighToMidDown then fieldTier = "MID" end
  end
end
-- ========================================================================

local function controlTick()
  local ri = reactor.getReactorInfo()
  if not ri then error("getReactorInfo returned nil") end

  local temp   = tonumber(ri.temperature) or 0
  local fieldP = pct(ri.fieldStrength, ri.maxFieldStrength)
  local satP   = pct(ri.energySaturation, ri.maxEnergySaturation)
  local fuelP  = fuelPercent(ri)
  local gen    = tonumber(ri.generationRate) or 0
  local inFlow = tonumber(ri.fieldInputRate) or 0
  local status = tostring(ri.status or "unknown")

  local newState = classify(temp, fieldP)

  if newState == STATE_SHUTDOWN then
    state = STATE_SHUTDOWN
    alarmSet(true, "TEMP SHUTDOWN")
    reactorStop(reactor)
    setLow(gateIn, cfg.inputMax)
    setLow(gateOut, 0)
    safetyClampOut = 0

  elseif newState == STATE_FAILSAFE then
    state = STATE_FAILSAFE
    alarmSet(true, "FIELD FAILSAFE")
    reactorStop(reactor)
    setLow(gateIn, cfg.inputMax)
    setLow(gateOut, 0)
    safetyClampOut = 0

  else
    if state == STATE_FAILSAFE then
      if fieldP >= cfg.fieldRelease and temp < cfg.tempCrit then
        alarmSet(false, "")
        safetyClampOut = nil
        state = newState
        reactorCharge(reactor)
        reactorActivate(reactor)
      else
        setLow(gateIn, cfg.inputMax)
        setLow(gateOut, 0)
      end
    else
      state = newState
    end
  end

  if state == STATE_CRIT then
    alarmSet(true, "CRIT")
  elseif state == STATE_WARN then
    alarmSet(true, "WARN")
  elseif state == STATE_NORMAL then
    alarmSet(false, "")
  end

  -- Output control (unchanged)
  local appliedOut = cfg.targetOutput
  if state == STATE_CRIT then
    local curOut = getLow(gateOut)
    if not safetyClampOut then safetyClampOut = curOut end
    safetyClampOut = clamp((safetyClampOut or curOut) - 200000, cfg.outputMin, cfg.outputMax)
    appliedOut = math.min(cfg.targetOutput, safetyClampOut)
  elseif state == STATE_WARN or state == STATE_NORMAL then
    safetyClampOut = nil
    appliedOut = cfg.targetOutput
  end
  if state == STATE_FAILSAFE or state == STATE_SHUTDOWN then appliedOut = 0 end

  setLow(gateOut, clamp(appliedOut, cfg.outputMin, cfg.outputMax))
  if temp < cfg.tempWarn and fieldP > cfg.fieldWarn and state ~= STATE_FAILSAFE and state ~= STATE_SHUTDOWN then
    setLow(gateOut, clamp(cfg.targetOutput, cfg.outputMin, cfg.outputMax))
  end

  -- =========================
  -- FIELD CONTROL (PATCHED)
  -- =========================
  local curIn = getLow(gateIn)

  if cfg.mode == MODE_FILL then
    -- Fill Mode: permanent full field input
    setLow(gateIn, cfg.fullFieldInput)

  else
    -- Stable Mode: tier by generation with hysteresis
    updateFieldTier(gen)

    if fieldTier == "HIGH" then
      -- Full input
      setLow(gateIn, cfg.fullFieldInput)

    else
      local targetField = (fieldTier == "MID") and cfg.fieldTargetMid or cfg.fieldTargetLow

      -- Keep original deadband behaviour for 25% normal state
      if targetField == 25 and fieldP >= cfg.stableDeadbandLo and fieldP <= cfg.stableDeadbandHi and state == STATE_NORMAL then
        -- no-op
      else
        local step = fieldStep(fieldP)
        if state == STATE_WARN then step = step * cfg.safetyStepMulWarn end
        if state == STATE_CRIT then step = step * cfg.safetyStepMulCrit end

        local err = targetField - fieldP
        local newIn = curIn

        if math.abs(err) >= 0.25 then
          if err > 0 then newIn = curIn + step else newIn = curIn - step end
        end

        if fieldP <= cfg.fieldWarn then newIn = curIn + step * 2 end
        if fieldP <= cfg.fieldCrit then newIn = curIn + step * 4 end

        newIn = clamp(newIn, cfg.inputMin, cfg.inputMax)
        setLow(gateIn, newIn)
      end
    end
  end

  -- UI draw (unchanged except we show tier for debugging)
  local now = os.clock()
  local drawPeriod = 1 / cfg.uiFps
  if now - lastDraw >= drawPeriod then
    lastDraw = now
    drawIfChanged("mode", 7, string.format("Mode: %s | Target OUT: %s | Tier: %s", cfg.mode, fmtNum(cfg.targetOutput), fieldTier), colors.white)
    drawIfChanged("state", 8, string.format("State: %s | Status: %s", state, status), colors.white)
    drawIfChanged("temp", 10, string.format("Temp: %sC (W %d C %d SD %d)", fmtNum(temp), cfg.tempWarn, cfg.tempCrit, cfg.tempShutdown),
      (temp >= cfg.tempCrit) and colors.red or (temp >= cfg.tempWarn and colors.orange or colors.lime))
    drawIfChanged("field", 11, string.format("Field: %.2f%% (W %d C %d F %d REL %d)", fieldP, cfg.fieldWarn, cfg.fieldCrit, cfg.fieldFail, cfg.fieldRelease),
      (fieldP <= cfg.fieldCrit) and colors.red or (fieldP <= cfg.fieldWarn and colors.orange or colors.lime))
    drawIfChanged("satfuel", 12, string.format("Saturation: %.2f%% | Fuel: %.2f%%", satP, fuelP), colors.white)
    drawIfChanged("rates", 13, string.format("Gen: %s/t | FieldIn: %s/t", fmtNum(gen), fmtNum(inFlow)), colors.white)
    drawIfChanged("gates", 14, string.format("Gate IN: %s | Gate OUT: %s", fmtNum(getLow(gateIn)), fmtNum(getLow(gateOut))), colors.white)
    local bw = math.max(10, monX - 12)
    drawIfChanged("bar_field", 16, "Field ["..bar(bw, fieldP).."]", colors.white)
    drawIfChanged("bar_sat", 17, "Sat ["..bar(bw, satP).."]", colors.white)
    drawIfChanged("bar_fuel", 18, "Fuel ["..bar(bw, fuelP).."]", colors.white)
  end
end

loadCfg()
initUi()

setLow(gateOut, clamp(cfg.targetOutput, cfg.outputMin, cfg.outputMax))
if getLow(gateIn) < cfg.inputMin then setLow(gateIn, cfg.inputMin) end

local function controlLoop()
  while true do
    controlTick()
    sleep(cfg.loopDt)
  end
end

parallel.waitForAny(
  function() button.clickEvent() end,
  controlLoop,
  alarmLoop
)
