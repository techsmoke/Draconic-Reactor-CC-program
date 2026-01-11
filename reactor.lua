-- Draconic Reactor CC Control (techsmoke fork)
-- Goals:
--  - Multi-monitor support (same UI on all monitors)
--  - Multi-speaker alarm + single redstone alarm output
--  - Fill/Stable mode
--  - Output ramp + temperature/safety throttling
--  - DEV logging (default ON) to logs/reactor.csv + logs/events.log
--
-- Dependencies:
--   lib/f.lua
--   lib/button.lua

os.loadAPI("lib/f")
os.loadAPI("lib/button")

-- =========================
-- Settings (persistent)
-- =========================
settings.load()

local function setDefault(key, val)
  if settings.get(key) == nil then settings.set(key, val) end
end

-- DEV mode default ON for debugging (as requested)
setDefault("devMode", true)

-- Alarm config
setDefault("alarmSide", "top")          -- one redstone line for ALL alarms
setDefault("alarmSpeakerEnabled", true)

-- Control modes
setDefault("mode", "fill")              -- "fill" or "stable"

-- Fill mode params
setDefault("outMaxFill", 6500000)       -- rf/t target for fast fill
setDefault("tempSoftFill", 7400)        -- start throttling output here
setDefault("rampStepFill", 200000)      -- rf/t per ramp step
setDefault("rampIntervalFill", 0.4)     -- seconds

-- Stable mode params
setDefault("outMaxStable", 800000)      -- cap in stable
setDefault("tempSoftStable", 7200)
setDefault("rampStepStable", 50000)
setDefault("rampIntervalStable", 0.6)
setDefault("satTarget", 55)             -- %
setDefault("satBand", 10)               -- +/- band

-- Field control
setDefault("targetStrength", 50)        -- %
setDefault("lowFieldHard", 15)          -- emergency cutoff
setDefault("lowFieldSoft", 30)          -- warning + output throttle kick-in
setDefault("inputSmooth", 0.35)         -- 0..1, higher = faster response
setDefault("inMin", 10)
setDefault("inMax", 50000000)

-- Safety
setDefault("maxTemp", 7750)             -- emergency shutdown
setDefault("safeTempRestart", 3000)

-- Save defaults
settings.save()

-- =========================
-- Peripherals
-- =========================
local function findAll(periphType)
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == periphType then
      out[#out+1] = peripheral.wrap(name)
    end
  end
  return out
end

local reactor = f.periphSearch("draconic_reactor")
if not reactor then error("No draconic_reactor found on the network") end

local monitors = findAll("monitor")
if #monitors == 0 then error("No monitors found on the network") end

local speakers = findAll("speaker") -- can be 0

if button.setMonitors then button.setMonitors(monitors) end

-- =========================
-- Flow gate setup (one-time)
-- =========================
local function listGateNames()
  local names = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "flow_gate" then
      names[#names+1] = n
    end
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

  -- Need detection
  local gates = listGateNames()
  if #gates < 2 then error("Need at least 2 flow_gates on the network") end

  -- show setup text
  for _, m in ipairs(monitors) do
    m.setTextScale(0.5)
    m.setBackgroundColor(colors.black)
    m.clear()
    m.setCursorPos(1,1)
    m.setTextColor(colors.white)
    m.write("SETUP: Flow gates")
    m.setCursorPos(1,3)
    m.write("Set INPUT gate (injector)")
    m.setCursorPos(1,4)
    m.write("Signal LOW to 10 RF/t.")
    m.setCursorPos(1,6)
    m.write("Waiting...")
  end
  print("SETUP: Set INPUT flow gate (injector) Signal LOW to 10 RF/t...")

  local deadline = os.clock() + 60
  while os.clock() < deadline do
    local foundIn, foundOut
    for _, name in ipairs(gates) do
      local g = peripheral.wrap(name)
      local v = gateGet(g)
      if v == 10 then
        foundIn = name
      else
        foundOut = name
      end
    end
    if foundIn and foundOut and foundIn ~= foundOut then
      settings.set("gateInName", foundIn)
      settings.set("gateOutName", foundOut)
      settings.save()
      print("Detected gateIn="..foundIn.." gateOut="..foundOut)
      return peripheral.wrap(foundIn), peripheral.wrap(foundOut)
    end
    sleep(0.25)
  end

  error("Flow gate detection timeout. Set INPUT gate to 10 RF/t (Signal LOW).")
end

local gateIn, gateOut = setupFlowGatesOnce()

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
  if not settings.get("devMode") then return end
  appendLine("logs/events.log", tostring(os.epoch("utc")) .. " " .. msg)
end

local function logHeaderIfMissing()
  if not settings.get("devMode") then return end
  if fs.exists("logs/reactor.csv") then
    local size = fs.getSize("logs/reactor.csv")
    if size and size > 0 then return end
  end
  appendLine("logs/reactor.csv", "ts,status,tempC,fieldPct,satPct,genRFt,fieldInRFt,outGateRFt,inGateRFt,fuelConvNbT,fieldDrainRFt,action")
end

logHeaderIfMissing()

-- =========================
-- Alarm (speakers + redstone)
-- =========================
local alarmMutedUntil = 0

local function setAlarmRedstone(on)
  local side = settings.get("alarmSide")
  if side and redstone and redstone.setOutput then
    pcall(function() redstone.setOutput(side, on and true or false) end)
  end
end

local function playAlarmSound(level)
  if not settings.get("alarmSpeakerEnabled") then return end
  if #speakers == 0 then return end

  -- throttle: don't spam
  local now = os.epoch("utc")
  if now < alarmMutedUntil then return end

  for _, spk in ipairs(speakers) do
    pcall(function()
      -- sound names vary by CC version; "minecraft:block.note_block.pling" is widely available
      if level == "crit" then
        spk.playSound("minecraft:block.note_block.bell", 1.0, 0.5)
      else
        spk.playSound("minecraft:block.note_block.pling", 1.0, 1.0)
      end
    end)
  end
end

local function alarm(level, on)
  setAlarmRedstone(on)
  if on then
    playAlarmSound(level)
  end
end

-- =========================
-- UI helpers
-- =========================
local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

local function pct(v, vmax)
  if not vmax or vmax == 0 then return 0 end
  return math.floor((v / vmax) * 10000) / 100
end

local function formatInt(n) return f.format_int(n) end

local function getTempColor(t)
  if t <= 5000 then return colors.green end
  if t <= 6500 then return colors.orange end
  return colors.red
end

local function getPctColor(p, good, warn)
  if p >= good then return colors.green end
  if p >= warn then return colors.orange end
  return colors.red
end

local function drawUI(ri)
  -- Build buttons once per redraw cycle (button lib draws on all monitors)
  button.clearTable()

  local mode = settings.get("mode")
  local dev = settings.get("devMode") and "ON" or "OFF"

  -- header + action buttons
  button.setButton("toggle", "Toggle", function()
    local s = reactor.getReactorInfo().status
    if s == "running" then reactor.stopReactor()
    elseif s == "stopping" then reactor.activateReactor()
    else reactor.chargeReactor() end
    logEvent("UI: toggle reactor")
  end, 2, 1, 12, 3, 0, 0, colors.blue)

  button.setButton("mode", "Mode: "..string.upper(mode), function()
    local m = settings.get("mode")
    settings.set("mode", (m == "fill") and "stable" or "fill")
    settings.save()
    logEvent("UI: mode="..settings.get("mode"))
  end, 14, 1, 31, 3, 0, 0, colors.blue)

  button.setButton("dev", "DEV: "..dev, function()
    settings.set("devMode", not settings.get("devMode"))
    settings.save()
    logEvent("UI: devMode="..tostring(settings.get("devMode")))
    logHeaderIfMissing()
  end, 33, 1, 44, 3, 0, 0, colors.blue)

  button.setButton("mute", "Mute 60s", function()
    alarmMutedUntil = os.epoch("utc") + 60000
    logEvent("UI: mute 60s")
  end, 46, 1, 58, 3, 0, 0, colors.blue)

  -- output controls
  local outLabel = "OUT "..formatInt(gateGet(gateOut))
  button.setButton("outDown", "-100k", function()
    gateSet(gateOut, math.max(0, gateGet(gateOut) - 100000))
    logEvent("UI: out -100k")
  end, 2, 18, 10, 20, 0, 0, colors.lightBlue)

  button.setButton("outUp", "+100k", function()
    gateSet(gateOut, gateGet(gateOut) + 100000)
    logEvent("UI: out +100k")
  end, 12, 18, 20, 20, 0, 0, colors.lightBlue)

  button.setButton("outUpBig", "+1M", function()
    gateSet(gateOut, gateGet(gateOut) + 1000000)
    logEvent("UI: out +1M")
  end, 22, 18, 28, 20, 0, 0, colors.lightBlue)

  -- info text is drawn separately per monitor by f helpers in renderAll()
end

local function renderAll(ri, statusLine, actionLine)
  for _, m in ipairs(monitors) do
    local mx, my = m.getSize()
    local mon = { monitor = m, X = mx, Y = my }

    m.setTextScale(0.5)
    m.setBackgroundColor(colors.black)
    m.clear()

    -- draw static info
    f.draw_text(mon, 2, 5, "Status:", colors.white, colors.black)
    f.draw_text(mon, 12, 5, statusLine, colors.white, colors.black)

    f.draw_text(mon, 2, 7, "Temp:", colors.white, colors.black)
    f.draw_text(mon, 12, 7, string.format("%.1fC", ri.temperature), getTempColor(ri.temperature), colors.black)

    local fieldPct = pct(ri.fieldStrength, ri.maxFieldStrength)
    local satPct = pct(ri.energySaturation, ri.maxEnergySaturation)

    f.draw_text(mon, 2, 9, "Field:", colors.white, colors.black)
    f.draw_text(mon, 12, 9, string.format("%.2f%%", fieldPct), getPctColor(fieldPct, 50, settings.get("lowFieldSoft")), colors.black)

    f.draw_text(mon, 2, 10, "Sat:", colors.white, colors.black)
    f.draw_text(mon, 12, 10, string.format("%.2f%%", satPct), getPctColor(satPct, 60, 30), colors.black)

    f.draw_text(mon, 2, 12, "Gen:", colors.white, colors.black)
    f.draw_text(mon, 12, 12, formatInt(ri.generationRate).." rf/t", colors.lime, colors.black)

    f.draw_text(mon, 2, 13, "Field In:", colors.white, colors.black)
    f.draw_text(mon, 12, 13, formatInt(ri.fieldDrainRate).." rf/t", colors.lightBlue, colors.black)

    f.draw_text(mon, 2, 15, "Gate OUT:", colors.white, colors.black)
    f.draw_text(mon, 12, 15, formatInt(gateGet(gateOut)).." rf/t", colors.lightBlue, colors.black)

    f.draw_text(mon, 2, 16, "Gate IN:", colors.white, colors.black)
    f.draw_text(mon, 12, 16, formatInt(gateGet(gateIn)).." rf/t", colors.lightBlue, colors.black)

    f.draw_text(mon, 2, 22, actionLine, colors.white, colors.black)

    -- Draw buttons on this monitor
    button.screen(m)
  end
end

-- =========================
-- Control logic
-- =========================
local function getModeParams()
  local mode = settings.get("mode")
  if mode == "stable" then
    return {
      outMax = settings.get("outMaxStable"),
      tempSoft = settings.get("tempSoftStable"),
      rampStep = settings.get("rampStepStable"),
      rampInterval = settings.get("rampIntervalStable"),
    }
  end
  return {
    outMax = settings.get("outMaxFill"),
    tempSoft = settings.get("tempSoftFill"),
    rampStep = settings.get("rampStepFill"),
    rampInterval = settings.get("rampIntervalFill"),
  }
end

local function desiredOutput(ri)
  local p = getModeParams()
  local target = p.outMax

  -- stable mode: regulate around saturation target
  if settings.get("mode") == "stable" then
    local satPct = pct(ri.energySaturation, ri.maxEnergySaturation)
    local satT = settings.get("satTarget")
    local band = settings.get("satBand")
    if satPct > satT + band then
      target = math.max(0, math.floor(target * 0.6))
    elseif satPct < satT - band then
      target = math.min(p.outMax, math.floor(target * 1.0))
    end
  end

  -- temperature throttle (soft)
  local tSoft = p.tempSoft
  local tHard = settings.get("maxTemp")
  if ri.temperature >= tSoft then
    local factor = 1 - ((ri.temperature - tSoft) / math.max(1, (tHard - tSoft)))
    factor = clamp(factor, 0, 1)
    target = math.floor(target * factor)
  end

  -- field/saturation throttle (soft)
  local fieldPct = pct(ri.fieldStrength, ri.maxFieldStrength)
  local satPct = pct(ri.energySaturation, ri.maxEnergySaturation)
  if fieldPct <= settings.get("lowFieldSoft") or satPct <= 25 then
    target = math.floor(target * 0.5)
  end

  return clamp(target, 0, p.outMax)
end

local lastOutSet = 0
local lastRampTime = 0
local lastIn = gateGet(gateIn)
local lastLogTime = 0

local function computeInputGate(ri)
  -- Same formula idea as original StormFusions:
  -- desiredIn = fieldDrainRate / (1 - targetStrength)
  local targetStrength = settings.get("targetStrength")
  local denom = (1 - (targetStrength / 100))
  if denom < 0.05 then denom = 0.05 end
  local desired = ri.fieldDrainRate / denom

  desired = clamp(desired, settings.get("inMin"), settings.get("inMax"))

  -- smoothing
  local alpha = clamp(settings.get("inputSmooth"), 0, 1)
  local newIn = math.floor(lastIn + (desired - lastIn) * alpha)
  newIn = clamp(newIn, settings.get("inMin"), settings.get("inMax"))
  lastIn = newIn
  return newIn
end

local function checkEmergency(ri)
  local fieldPct = pct(ri.fieldStrength, ri.maxFieldStrength)
  local fuelPct = 100 - pct(ri.fuelConversion, ri.maxFuelConversion)

  if fuelPct <= 10 then return "Fuel Low" end
  if ri.status == "running" and fieldPct <= settings.get("lowFieldHard") then return "Field Critical" end
  if ri.temperature >= settings.get("maxTemp") then return "Overheat" end
  return nil
end

local function mainLoop()
  while true do
    local ri = reactor.getReactorInfo()
    if not ri then
      sleep(0.5)
    else
      local fieldPct = pct(ri.fieldStrength, ri.maxFieldStrength)
      local satPct = pct(ri.energySaturation, ri.maxEnergySaturation)

      -- emergency handling
      local reason = checkEmergency(ri)
      local actionLine = "OK"
      if reason then
        pcall(function() reactor.stopReactor() end)
        actionLine = "EMERGENCY: "..reason.." -> STOP"
        alarm("crit", true)
        logEvent("EMERGENCY: "..reason)
      else
        -- warning alarm
        local warn = (ri.temperature >= getModeParams().tempSoft) or (fieldPct <= settings.get("lowFieldSoft")) or (satPct <= 25)
        alarm(warn and "warn" or "warn", warn)

        -- input gate control
        if ri.status == "running" then
          local newIn = computeInputGate(ri)
          pcall(function() gateSet(gateIn, newIn) end)
        elseif ri.status == "warming_up" then
          -- help charge faster
          pcall(function() gateSet(gateIn, math.max(gateGet(gateIn), 900000)) end)
        end

        -- output control (ramp towards desired)
        local now = os.clock()
        local p = getModeParams()
        if now - lastRampTime >= p.rampInterval then
          local want = desiredOutput(ri)
          local cur = gateGet(gateOut)
          local nextOut = cur
          if cur < want then nextOut = math.min(want, cur + p.rampStep) end
          if cur > want then nextOut = math.max(want, cur - p.rampStep) end
          if nextOut ~= cur then
            pcall(function() gateSet(gateOut, nextOut) end)
          end
          lastRampTime = now
          lastOutSet = want
        end
      end

      -- status line
      local statusLine = tostring(ri.status)

      -- buttons (global table) + render
      drawUI(ri)
      renderAll(ri, statusLine, actionLine)

      -- DEV logging (1 Hz)
      if settings.get("devMode") then
        local nowMs = os.epoch("utc")
        if nowMs - lastLogTime >= 1000 then
          local line = table.concat({
            tostring(nowMs),
            tostring(ri.status),
            string.format("%.1f", ri.temperature),
            string.format("%.2f", pct(ri.fieldStrength, ri.maxFieldStrength)),
            string.format("%.2f", pct(ri.energySaturation, ri.maxEnergySaturation)),
            tostring(ri.generationRate),
            tostring(ri.fieldDrainRate),
            tostring(gateGet(gateOut)),
            tostring(gateGet(gateIn)),
            tostring(ri.fuelConversion),
            tostring(ri.fieldDrainRate),
            ""
          }, ",")
          appendLine("logs/reactor.csv", line)
          lastLogTime = nowMs
        end
      end
    end

    sleep(0.1)
  end
end

-- Run: UI clicks + main loop
parallel.waitForAny(mainLoop, button.clickEvent)
