-- Draconic Reactor CC Control (single-monitor, compatible with simple lib/button)
-- Target: Minecraft 1.20.1 + CC:Tweaked + Draconic Evolution reactor peripheral + Flux Networks flow gates
-- Features:
-- - Fill/Stable mode (settings: mode = "fill"|"stable")
-- - Output ramp + safety throttling (prevents shield/heat runaway when output is cranked)
-- - DEV logging (default ON) -> logs/reactor.csv + logs/events.log
-- - Alarms: one redstone side + optional speakers (any count)

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
setDefault("alarmSide", "top")          -- redstone side
setDefault("alarmSpeakerEnabled", true) -- speak() if speakers exist

-- Fill mode params
setDefault("outMaxFill", 6500000)       -- target ramp ceiling
setDefault("tempSoftFill", 7400)
setDefault("rampStepFill", 200000)
setDefault("rampIntervalFill", 0.4)

-- Stable mode params
setDefault("outMaxStable", 800000)
setDefault("tempSoftStable", 7200)
setDefault("rampStepStable", 50000)
setDefault("rampIntervalStable", 0.6)

-- Field control
setDefault("targetStrength", 50)        -- %
setDefault("lowFieldHard", 10)          -- emergency cutoff
setDefault("lowFieldSoft", 20)          -- start throttling output
setDefault("inputSmooth", 0.35)         -- 0..1
setDefault("inMin", 10)
setDefault("inMax", 50000000)

-- Safety
setDefault("maxTemp", 6500)             -- emergency shutdown
setDefault("safeTempRestart", 5000)     -- restart allowed below

settings.save()

local function S(k) return settings.get(k) end

-- =========================
-- Peripherals
-- =========================
local reactor = f.periphSearch("draconic_reactor")
if not reactor then error("No draconic_reactor found") end

local monitor = f.periphSearch("monitor")
if not monitor then error("No monitor found") end

local speakers = { peripheral.find("speaker") } -- can be empty

-- button.lua (simple) grabs peripheral.find("monitor") at load.
-- Ensure the *one* monitor we want is discoverable as "monitor".
-- If you have multiple monitors connected, disconnect extras for now.

-- =========================
-- Logging (DEV mode)
-- =========================
local function ensureDir(path)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

ensureDir("logs/reactor.csv")
ensureDir("logs/events.log")

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

local function logCSV(ri, inFlow, outFlow)
  if not S("devMode") then return end
  if not fs.exists("logs/reactor.csv") then
    appendLine("logs/reactor.csv",
      "ts,mode,status,temp,field_pct,sat_pct,fuel_pct,gen,in_flow,out_flow,action")
  end
  local ts = os.epoch("utc")
  local fuelPct = 100 - math.floor((ri.fuelConversion / ri.maxFuelConversion) * 10000 + 0.5)/100
  local fieldPct = math.floor((ri.fieldStrength / ri.maxFieldStrength) * 10000 + 0.5)/100
  local satPct = math.floor((ri.energySaturation / ri.maxEnergySaturation) * 10000 + 0.5)/100
  appendLine("logs/reactor.csv", table.concat({
    ts, S("mode"), ri.status, string.format("%.1f", ri.temperature),
    fieldPct, satPct, fuelPct,
    math.floor(ri.generationRate+0.5),
    inFlow, outFlow,
    (actionText or "")
  }, ","))
end

-- =========================
-- Flow gates (Flux Networks)
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

  if gateIn and gateOut and gateInName ~= gateOutName then
    return gateIn, gateOut
  end

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
-- Helpers
-- =========================
local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function pct(v, maxv)
  if maxv == 0 then return 0 end
  return math.floor((v / maxv) * 10000 + 0.5) / 100
end

local lastAlarmMsg = ""
local lastAlarmTs = 0
local function alarm(on, msg)
  -- Redstone alarm
  if alarmSide and alarmSide ~= "" then
    pcall(redstone.setOutput, alarmSide, on)
  end

  if not on then
    lastAlarmMsg = ""
    return
  end

  msg = msg or "ALARM"
  local now = os.epoch("utc") or 0

  -- Don't spam; but replay if message changes or after a bit
  local shouldPlay = (msg ~= lastAlarmMsg) or (now - lastAlarmTs > 3000)
  lastAlarmMsg = msg

  if alarmSpeakerEnabled and shouldPlay then
    lastAlarmTs = now
    -- Find all speakers and play a loud-ish sound
    local found = { peripheral.find("speaker") }
    for _, sp in ipairs(found) do
      pcall(sp.playSound, "minecraft:block.note_block.pling", 1.0, 1.0)
    end
  end

  if msg and msg ~= "" then
    setAction(msg, colors.red)
  end
end

-- =========================
-- UI + Actions
-- =========================
monitor.setTextScale(0.5)
f.firstSet({ monitor = monitor, X = monitor.getSize(), Y = select(2, monitor.getSize()) })

local monX, monY = monitor.getSize()
local mon = { monitor = monitor, X = monX, Y = monY }

local function clearScreen()
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  monitor.setCursorPos(1,1)
  button.screen()
end

local actionText = "Booting..."
local actionColor = colors.gray

local function setAction(txt, col)
  actionText = txt or actionText
  actionColor = col or actionColor
end

local function toggleMode()
  local m = S("mode")
  if m == "fill" then settings.set("mode", "stable") else settings.set("mode", "fill") end
  settings.save()
  setAction("Mode -> "..S("mode"), colors.lightBlue)
  logEvent("Mode changed to "..S("mode"))
end

local function toggleReactor()
  local ri = reactor.getReactorInfo()
  if ri.status == "running" then
    reactor.stopReactor()
    setAction("Stopping reactor", colors.orange)
    logEvent("stopReactor()")
  elseif ri.status == "stopping" then
    reactor.activateReactor()
    setAction("Activating reactor", colors.green)
    logEvent("activateReactor()")
  else
    reactor.chargeReactor()
    setAction("Charging reactor", colors.orange)
    logEvent("chargeReactor()")
  end
end

local function rebootSystem()
  logEvent("reboot")
  os.reboot()
end

local function drawFrame()
  clearScreen()
  f.draw_line(mon, 2, 2, monX - 2, colors.gray)
  f.draw_line(mon, 2, 22, monX - 2, colors.gray)
  f.draw_line_y(mon, 2, 2, 22, colors.gray)
  f.draw_line_y(mon, monX - 1, 2, 22, colors.gray)
  f.draw_text(mon, 4, 2, " DRACONIC CONTROL ", colors.white, colors.black)

  f.draw_line(mon, 2, 26, monX - 2, colors.gray)
  f.draw_line(mon, 2, monY - 1, monX - 2, colors.gray)
  f.draw_line_y(mon, 2, 26, monY - 1, colors.gray)
  f.draw_line_y(mon, monX - 1, 26, monY - 1, colors.gray)
end

local function setupButtons()
  button.clearTable()

  -- Top row buttons
  local x = 4
  button.setButton("toggle", "Toggle Reactor", function() toggleReactor() end, x, 28, x + 14, 30, 0, 0, colors.blue)
  x = x + 16
  button.setButton("mode", "Mode: "..S("mode"), function() toggleMode() end, x, 28, x + 12, 30, 0, 0, colors.purple)
  x = x + 14
  button.setButton("reboot", "Reboot", function() rebootSystem() end, x, 28, x + 8, 30, 0, 0, colors.blue)

  -- Output adjust (small set)
  local function changeOut(delta)
  -- User setpoint (what you want). CC may temporarily limit for safety, but will restore.
  outUserTarget = clamp(outUserTarget + delta, 0, outMax)
  if not safetyLimited then
    outTarget = outUserTarget
    gateSet(gateOut, outTarget)
  end
end

-- =========================
-- Control logic
-- =========================
local curIn = clamp(gateGet(gateIn), S("inMin"), S("inMax"))
local outUserTarget = gateGet(gateOut)
local outTarget = outUserTarget
local safetyLimited = false

local function params()
  if S("mode") == "fill" then
    return S("outMaxFill"), S("tempSoftFill"), S("rampStepFill"), S("rampIntervalFill")
  else
    return S("outMaxStable"), S("tempSoftStable"), S("rampStepStable"), S("rampIntervalStable")
  end
end

local function throttleOutput(ri)
  -- Only override user output when we're in a dangerous state (crit+).
  local temp = ri.temperature
  local fieldPct = ri.fieldStrength * 100
  local tempCrit = S("tempCrit")
  local tempWarn = S("tempWarn")
  local fieldCrit = S("fieldCrit")
  local fieldWarn = S("fieldWarn")

  if temp >= tempCrit or fieldPct <= fieldCrit then
    if not safetyLimited then
      alarm(true, "CRIT! Taking over output control")
    end
    safetyLimited = true
    -- Cut output fast to reduce heating, but don't go negative.
    outTarget = math.max(0, outTarget - S("maxOutRate") * 4)
    gateSet(gateOut, outTarget)
    return
  end

  -- Back to safe: restore user setpoint when we're below WARN again (hysteresis).
  if safetyLimited and temp <= tempWarn and fieldPct >= fieldWarn then
    safetyLimited = false
    outTarget = outUserTarget
    alarm(false, "OK - returning output to user target")
  end
end

local function controlInput(ri)
  local cur = gateGet(gateIn)
  local fieldPct = ri.fieldStrength * 100

  local mode = S("mode")
  local target = (mode == "fill") and S("fieldTargetFill") or S("fieldTargetStable")

  -- Safety: if field is too low, jam the injector hard.
  if fieldPct <= S("fieldFailsafe") then
    alarm(true, "FIELD FAILSAFE! Forcing max field input")
    gateSet(gateIn, inMax)
    return
  end

  -- Piecewise control (stable is gentle near target; fill is aggressive).
  local err = target - fieldPct

  local gain = 15000
  local maxDelta = S("maxInRate") * 4

  if mode == "stable" then
    -- Gentle band around target to stop oscillation
    if fieldPct >= 23 and fieldPct <= 28 then
      gain = 4000
      maxDelta = math.max(20000, S("maxInRate")) -- smaller steps
    end
    if fieldPct >= 24.5 and fieldPct <= 25.5 then
      -- deadband: don't touch
      return
    end
    if fieldPct > 30 then
      gain = 12000
      maxDelta = S("maxInRate") * 2
    end
  else
    -- fill mode: faster recovery
    gain = 20000
    maxDelta = S("maxInRate") * 6
  end

  -- If we're approaching warn temps, bias towards more field (safer).
  if ri.temperature >= S("tempWarn") then
    err = err + 5 -- push field up
  end

  local delta = clamp(err * gain, -maxDelta, maxDelta)
  local want = clamp(cur + delta, 0, inMax)
  gateSet(gateIn, want)
end

local lastRamp = 0

local function rampOutput()
  local cur = gateGet(gateOut)
  local want = clamp(outTarget, 0, outMax)
  local step = S("maxOutRate")
  local next = cur
  if want > cur then
    next = math.min(cur + step, want)
  elseif want < cur then
    next = math.max(cur - step, want)
  end
  gateSet(gateOut, next)
end

-- =========================
-- Main loops
-- =========================
local function drawStatus(ri)
  local fuelPct = 100 - pct(ri.fuelConversion, ri.maxFuelConversion)
  local fieldPct = pct(ri.fieldStrength, ri.maxFieldStrength)
  local satPct = pct(ri.energySaturation, ri.maxEnergySaturation)

  f.draw_text(mon, 4, 4, "Status: "..tostring(ri.status), colors.white, colors.black)
  f.draw_text(mon, 4, 6, "Temp: "..string.format("%.1fC", ri.temperature), colors.white, colors.black)
  f.draw_text(mon, 4, 8, "Generation: "..f.format_int(ri.generationRate).." rf/t", colors.lime, colors.black)
  f.draw_text(mon, 4, 10, "Input gate: "..f.format_int(gateGet(gateIn)).." rf/t", colors.lightBlue, colors.black)
  f.draw_text(mon, 4, 11, "Output gate: "..f.format_int(gateGet(gateOut)).." rf/t", colors.lightBlue, colors.black)
  f.draw_text(mon, 4, 13, "Saturation: "..satPct.."%", colors.green, colors.black)
  f.progress_bar(mon, 4, 14, monX - 7, satPct, 100, colors.green, colors.lightGray)
  f.draw_text(mon, 4, 16, "Field: "..fieldPct.."%", colors.cyan, colors.black)
  f.progress_bar(mon, 4, 17, monX - 7, fieldPct, 100, colors.cyan, colors.lightGray)
  f.draw_text(mon, 4, 19, "Fuel: "..fuelPct.."%", colors.orange, colors.black)
  f.progress_bar(mon, 4, 20, monX - 7, fuelPct, 100, colors.orange, colors.lightGray)

  f.draw_text(mon, 4, 24, "Action: "..actionText, actionColor, colors.black)
end

local function uiLoop()
  while true do
    local ri = reactor.getReactorInfo()
    if ri then
      -- Alarm thresholds (speaker/redstone) + hard shutdown
      local temp = ri.temperature
      local fieldPct = ri.fieldStrength * 100

      if temp >= S("tempShutdown") then
        alarm(true, "TEMP SHUTDOWN!")
        reactor.stopReactor()
        gateSet(gateOut, 0)
        gateSet(gateIn, inMax)
      elseif temp >= S("tempCrit") then
        alarm(true, "TEMP CRIT!")
      elseif temp >= S("tempWarn") then
        alarm(true, "TEMP WARN")
      end

      if fieldPct <= S("fieldCrit") then
        alarm(true, "FIELD CRIT!")
      elseif fieldPct <= S("fieldWarn") then
        alarm(true, "FIELD WARN")
      end
      drawFrame()
      setupButtons()
      drawStatus(ri)
      button.screen()
      logCSV(ri, gateGet(gateIn), gateGet(gateOut))
    end
    sleep(0.25)
  end
end

local function controlLoop()
  while true do
    local ri = reactor.getReactorInfo()
    if ri then
      throttleOutput(ri)
      controlInput(ri)
      rampOutput()

      -- emergency fuel
      local fuelPct = 100 - pct(ri.fuelConversion, ri.maxFuelConversion)
      if fuelPct <= 10 then alarm(true, "Fuel low") setAction("Fuel low", colors.red) end
    end
    sleep(0.1)
  end
end

-- Start
logEvent("startup")
clearScreen()
drawFrame()
setupButtons()
setAction("Running ("..S("mode")..")", colors.lightBlue)

parallel.waitForAny(button.clickEvent, uiLoop, controlLoop)
