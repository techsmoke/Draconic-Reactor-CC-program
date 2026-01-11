-- Draconic Reactor CC Control (techsmoke fork)
-- Minecraft 1.20.1 + CC:Tweaked + Draconic Evolution + Flux Networks (flow_gate)
-- Files on computer (CraftOS): reactor, lib/f, lib/button  (no .lua)
-- Features:
--  - Stable/Fill mode
--  - Output setpoint + safety takeover (only at/above CRIT; returns below WARN)
--  - DEV logging (default ON) -> logs/reactor.csv + logs/events.log
--  - Alarms: redstone side + speakers (any count)
--  - Field control:
--      * FILL: forces full field input (99.999T RF/t)
--      * STABLE: generation-tiered field target with hysteresis:
--          LOW  (<=3.8M .. <4.2M hysteresis): target 25%
--          MID  (>=4.2M .. <6.2M, down at 3.8M): target 50%
--          HIGH (>=6.2M, down at 5.8M): full field input (99.999T RF/t)

os.loadAPI("lib/f")
os.loadAPI("lib/button")

-- =========================
-- Settings (persistent)
-- =========================
settings.load()

local function setDefault(k, v)
  if settings.get(k) == nil then settings.set(k, v) end
end

-- DEV mode default ON (requested)
setDefault("devMode", true)

-- Mode: "fill" or "stable"
setDefault("mode", "fill")

-- Alarm outputs
setDefault("alarmSide", "top")              -- redstone side, "" to disable
setDefault("alarmSpeakerEnabled", true)     -- play on any speakers found

-- Output control
setDefault("outMaxFill", 6500000)
setDefault("outMaxStable", 800000)

-- Safety thresholds (your spec)
setDefault("tempWarn", 5000)
setDefault("tempCrit", 6000)
setDefault("maxTemp", 6500)                -- emergency shutdown (TEMP SHUTDOWN)

setDefault("fieldWarn", 20)                -- percent
setDefault("fieldCrit", 15)                -- percent
setDefault("fieldFailsafe", 10)            -- percent -> failsafe latch
setDefault("fieldRelease", 50)             -- percent -> release latch

-- Rate limits / smoothing
setDefault("maxOutRate", 200000)           -- RF/t per control tick when cutting output for safety
setDefault("maxInRate", 200000)            -- RF/t per control tick for changing injector gate
setDefault("inMin", 10)

-- Control loop timing
setDefault("loopDt", 0.2)
setDefault("uiFps", 6)

-- Field tier config (STABLE, generation-based)
setDefault("genLowToMidUp", 4200000)       -- 4.2M up
setDefault("genMidToLowDown", 3800000)     -- 3.8M down
setDefault("genMidToHighUp", 6200000)      -- 6.2M up
setDefault("genHighToMidDown", 5800000)    -- 5.8M down

setDefault("fieldTargetLow", 25)           -- %
setDefault("fieldTargetMid", 50)           -- %
setDefault("fullFieldInput", 99999000000000) -- 99.999T RF/t

-- Input clamp for normal regulation (not used when forcing full field input)
setDefault("inMaxNormal", 50000000)

settings.save()

local function S(k) return settings.get(k) end

-- =========================
-- Helpers
-- =========================
local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function pct(v, maxv)
  if not maxv or maxv == 0 then return 0 end
  return math.floor((v / maxv) * 10000 + 0.5) / 100
end

local function fmtNum(n)
  n = tonumber(n) or 0
  if n >= 1e12 then return string.format("%.3fT", n/1e12) end
  if n >= 1e9  then return string.format("%.2fG", n/1e9) end
  if n >= 1e6  then return string.format("%.2fM", n/1e6) end
  if n >= 1e3  then return string.format("%.1fk", n/1e3) end
  return tostring(math.floor(n+0.5))
end

-- =========================
-- Peripherals
-- =========================
local reactor = f.periphSearch("draconic_reactor")
if not reactor then error("No draconic_reactor found") end

local monitor = f.periphSearch("monitor")
if not monitor then error("No monitor found") end

local function findSpeakers()
  return { peripheral.find("speaker") }
end

-- =========================
-- Logging (DEV mode)
-- =========================
local function ensureDir(path)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function appendLine(path, line)
  ensureDir(path)
  local h = fs.open(path, "a")
  h.writeLine(line)
  h.close()
end

local function logEvent(msg)
  if not S("devMode") then return end
  appendLine("logs/events.log", tostring(os.epoch("utc")) .. " " .. tostring(msg))
end

local actionText = ""

local function logCSV(ri, inFlow, outFlow, fieldTier)
  if not S("devMode") then return end
  if not fs.exists("logs/reactor.csv") then
    appendLine("logs/reactor.csv", "ts,mode,tier,status,temp,field_pct,sat_pct,fuel_pct,gen,in_flow,out_flow,action")
  end
  local ts = os.epoch("utc")
  local fuelPct = 100 - math.floor((ri.fuelConversion / ri.maxFuelConversion) * 10000 + 0.5)/100
  local fieldPct = math.floor((ri.fieldStrength / ri.maxFieldStrength) * 10000 + 0.5)/100
  local satPct = math.floor((ri.energySaturation / ri.maxEnergySaturation) * 10000 + 0.5)/100
  appendLine("logs/reactor.csv", table.concat({
    ts,
    S("mode"),
    tostring(fieldTier or ""),
    tostring(ri.status),
    string.format("%.1f", ri.temperature),
    fieldPct,
    satPct,
    fuelPct,
    math.floor((ri.generationRate or 0)+0.5),
    inFlow,
    outFlow,
    tostring(actionText or "")
  }, ","))
end

-- =========================
-- Flow gates (Flux Networks) with one-time identification
-- =========================
local function listGateNames()
  local names = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "flow_gate" then names[#names+1] = n end
  end
  return names
end

local function wrapGate(name)
  if name and peripheral.isPresent(name) and peripheral.getType(name) == "flow_gate" then
    return peripheral.wrap(name)
  end
  return nil
end

local function gateGet(g) return g.getSignalLowFlow() end
local function gateSet(g, v) g.setSignalLowFlow(v) end

local function setupFlowGatesOnce()
  local gateInName = settings.get("gateInName")
  local gateOutName = settings.get("gateOutName")
  local gateIn = wrapGate(gateInName)
  local gateOut = wrapGate(gateOutName)
  if gateIn and gateOut and gateInName ~= gateOutName then return gateIn, gateOut end

  local gates = listGateNames()
  if #gates < 2 then error("Need at least 2 flow_gates on the network") end

  monitor.setTextScale(0.5)
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  monitor.setCursorPos(1,1)
  monitor.setTextColor(colors.white)
  monitor.write("SETUP: Flow gates")
  monitor.setCursorPos(1,3)
  monitor.write("Set INPUT gate (injector)")
  monitor.setCursorPos(1,4)
  monitor.write("Signal LOW to 10 RF/t.")
  monitor.setCursorPos(1,6)
  monitor.write("Waiting...")

  print("SETUP: Set INPUT flow gate (injector) Signal LOW to 10 RF/t...")
  local deadline = os.clock() + 90

  while os.clock() < deadline do
    local foundIn, foundOut
    for _, name in ipairs(gates) do
      local g = peripheral.wrap(name)
      local v = gateGet(g)
      if v == 10 then foundIn = name else foundOut = name end
    end
    if foundIn and foundOut and foundIn ~= foundOut then
      settings.set("gateInName", foundIn)
      settings.set("gateOutName", foundOut)
      settings.save()
      print("Detected gateIn="..foundIn.." gateOut="..foundOut)
      logEvent("Detected gates: in="..foundIn.." out="..foundOut)
      return peripheral.wrap(foundIn), peripheral.wrap(foundOut)
    end
    sleep(0.25)
  end

  error("Flow gate detection timeout. Set INPUT gate Signal LOW = 10 RF/t.")
end

local gateIn, gateOut = setupFlowGatesOnce()

-- =========================
-- Alarm
-- =========================
local lastAlarmMsg = ""
local lastAlarmTs = 0

local function alarm(on, msg)
  local alarmSide = S("alarmSide")
  local alarmSpeakerEnabled = S("alarmSpeakerEnabled")

  if alarmSide and alarmSide ~= "" then
    pcall(redstone.setOutput, alarmSide, on and true or false)
  end

  if not on then
    lastAlarmMsg = ""
    return
  end

  msg = msg or "ALARM"
  local now = os.epoch("utc") or 0
  local shouldPlay = (msg ~= lastAlarmMsg) or (now - lastAlarmTs > 3000)
  lastAlarmMsg = msg

  if alarmSpeakerEnabled and shouldPlay then
    lastAlarmTs = now
    for _, sp in ipairs(findSpeakers()) do
      pcall(sp.playSound, "minecraft:block.note_block.pling", 1.0, 1.0)
    end
  end

  actionText = msg
end

-- =========================
-- UI + Buttons
-- =========================
monitor.setTextScale(0.5)
monitor.setBackgroundColor(colors.black)
monitor.setTextColor(colors.white)
monitor.clear()

local monX = monitor.getSize()
local lastDraw = 0
local lastUi = {}

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

-- Normalize button API variants
local function normalizeButtonAPI()
  if type(button) ~= "table" then button = {} end
  if type(button.clearTable) ~= "function" and type(clearTable) == "function" then button.clearTable = clearTable end
  if type(button.setButton) ~= "function" and type(setButton) == "function" then button.setButton = setButton end
  if type(button.screen) ~= "function" and type(screen) == "function" then button.screen = screen end
  if type(button.clickEvent) ~= "function" and type(clickEvent) == "function" then button.clickEvent = clickEvent end
end
normalizeButtonAPI()

local function toggleMode()
  local m = S("mode")
  if m == "fill" then settings.set("mode", "stable") else settings.set("mode", "fill") end
  settings.save()
  actionText = "Mode -> "..S("mode")
  logEvent(actionText)
end

local function toggleReactor()
  local ri = reactor.getReactorInfo()
  if ri.status == "running" then
    reactor.stopReactor()
    actionText = "Stopping reactor"
    logEvent("stopReactor()")
  elseif ri.status == "stopping" then
    reactor.activateReactor()
    actionText = "Activating reactor"
    logEvent("activateReactor()")
  else
    reactor.chargeReactor()
    actionText = "Charging reactor"
    logEvent("chargeReactor()")
  end
end

local function rebootSystem()
  logEvent("reboot")
  os.reboot()
end

local function drawButtons()
  if button.clearTable then button.clearTable() end
  if button.setButton then
    local x = 2
    button.setButton("toggle", "Toggle", toggleReactor, x, 1, x+8, 2, 0, 0, colors.blue) x = x+10
    button.setButton("mode", "Mode", toggleMode, x, 1, x+7, 2, 0, 0, colors.purple) x = x+9
    button.setButton("reboot", "Reboot", rebootSystem, x, 1, x+8, 2, 0, 0, colors.red)
  end
  if button.screen then button.screen(monitor) end
end

drawButtons()

-- =========================
-- Control logic
-- =========================
local fieldTier = "LOW" -- LOW/MID/HIGH (stable only)
local failsafeLatched = false

local outUserTarget = gateGet(gateOut)
local outTarget = outUserTarget
local safetyLimited = false

local function updateFieldTier(gen)
  local up1 = S("genLowToMidUp")
  local dn1 = S("genMidToLowDown")
  local up2 = S("genMidToHighUp")
  local dn2 = S("genHighToMidDown")

  if fieldTier == "LOW" then
    if gen >= up1 then fieldTier = "MID" end
  elseif fieldTier == "MID" then
    if gen >= up2 then fieldTier = "HIGH"
    elseif gen <= dn1 then fieldTier = "LOW" end
  elseif fieldTier == "HIGH" then
    if gen <= dn2 then fieldTier = "MID" end
  end
end

local function applyOutputSafety(ri)
  local temp = ri.temperature or 0
  local fieldPct = pct(ri.fieldStrength, ri.maxFieldStrength)

  if temp >= S("tempCrit") or fieldPct <= S("fieldCrit") then
    if not safetyLimited then
      alarm(true, "CRIT! Output takeover")
      logEvent("Safety takeover output")
    end
    safetyLimited = true
    outTarget = math.max(0, outTarget - S("maxOutRate") * 4)
    gateSet(gateOut, outTarget)
    return
  end

  if safetyLimited and temp <= S("tempWarn") and fieldPct >= S("fieldWarn") then
    safetyLimited = false
    outTarget = outUserTarget
    alarm(false, "OK - output restored")
    logEvent("Safety release output")
  end
end

local function applyFieldControl(ri)
  local mode = S("mode")
  local fieldPct = pct(ri.fieldStrength, ri.maxFieldStrength)
  local gen = ri.generationRate or 0
  local temp = ri.temperature or 0

  if temp >= S("maxTemp") then
    failsafeLatched = true
    alarm(true, "TEMP SHUTDOWN")
    logEvent("TEMP SHUTDOWN")
    pcall(reactor.stopReactor)
  end

  if fieldPct <= S("fieldFailsafe") then
    failsafeLatched = true
    alarm(true, "FIELD FAILSAFE")
    logEvent("FIELD FAILSAFE")
    pcall(reactor.stopReactor)
  end

  if failsafeLatched then
    gateSet(gateIn, S("fullFieldInput"))
    gateSet(gateOut, 0)
    if fieldPct >= S("fieldRelease") and temp < S("tempCrit") then
      failsafeLatched = false
      alarm(false, "Recovered")
      logEvent("Failsafe released")
      gateSet(gateOut, outTarget)
      pcall(reactor.chargeReactor)
      pcall(reactor.activateReactor)
    end
    return
  end

  if mode == "fill" then
    gateSet(gateIn, S("fullFieldInput"))
    return
  end

  updateFieldTier(gen)

  if fieldTier == "HIGH" then
    gateSet(gateIn, S("fullFieldInput"))
    return
  end

  local target = (fieldTier == "MID") and S("fieldTargetMid") or S("fieldTargetLow")

  local cur = gateGet(gateIn)
  local inMax = S("inMaxNormal")
  local step = S("maxInRate")

  if temp >= S("tempWarn") or fieldPct <= S("fieldWarn") then
    step = step * 2
  end

  local err = target - fieldPct
  local newIn = cur
  if math.abs(err) >= 0.25 then
    if err > 0 then newIn = cur + step else newIn = cur - step end
  end

  if fieldPct <= S("fieldWarn") then newIn = cur + step * 2 end
  if fieldPct <= S("fieldCrit") then newIn = cur + step * 4 end

  newIn = clamp(newIn, S("inMin"), inMax)
  gateSet(gateIn, newIn)
end

local function uiLoop()
  while true do
    local now = os.clock()
    local drawPeriod = 1 / S("uiFps")
    if now - lastDraw >= drawPeriod then
      lastDraw = now
      local ri = reactor.getReactorInfo()
      local fieldP = pct(ri.fieldStrength, ri.maxFieldStrength)
      local satP = pct(ri.energySaturation, ri.maxEnergySaturation)
      local fuelP = 100 - pct(ri.fuelConversion, ri.maxFuelConversion)
      local gen = ri.generationRate or 0

      drawIfChanged("hdr", 4, "DRACONIC CONTROL | Mode: "..S("mode").." | Tier: "..tostring(fieldTier), colors.white)
      drawIfChanged("out", 5, "Out(user/cur): "..fmtNum(outUserTarget).." / "..fmtNum(outTarget), colors.white)
      drawIfChanged("gen", 6, "Gen: "..fmtNum(gen).."  Temp: "..string.format("%.1f", ri.temperature), colors.white)
      drawIfChanged("field", 7, "Field: "..string.format("%.2f", fieldP).." %  Sat: "..string.format("%.2f", satP).." %  Fuel: "..string.format("%.2f", fuelP).." %", colors.white)
      drawIfChanged("gate", 8, "Gate IN: "..fmtNum(gateGet(gateIn)).."  Gate OUT: "..fmtNum(gateGet(gateOut)), colors.white)
      drawIfChanged("act", 10, "Action: "..tostring(actionText or ""), colors.orange)
    end
    sleep(0.05)
  end
end

local function controlLoop()
  while true do
    local ri = reactor.getReactorInfo()

    local outMax = (S("mode") == "fill") and S("outMaxFill") or S("outMaxStable")
    outUserTarget = clamp(outUserTarget, 0, outMax)

    if not safetyLimited and not failsafeLatched then
      outTarget = outUserTarget
      gateSet(gateOut, outTarget)
    end

    applyOutputSafety(ri)
    applyFieldControl(ri)

    logCSV(ri, gateGet(gateIn), gateGet(gateOut), fieldTier)

    sleep(S("loopDt"))
  end
end

local function buttonLoop()
  if button and type(button.clickEvent) == "function" then
    button.clickEvent()
  else
    while true do sleep(1) end
  end
end

parallel.waitForAny(buttonLoop, uiLoop, controlLoop)
