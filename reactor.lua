-- StormFusions Draconic Reactor CC program (patched)
-- Patch goals (minimal):
-- 1) Keep shield stable when output is ramped hard (throttle output gate on unsafe conditions)
-- 2) Don't explode just because you start filling a huge storage
-- Everything else kept as close as possible.

os.loadAPI("lib/f")
os.loadAPI("lib/button")

-- === CONFIG (same defaults) ===
local targetStrength = 50          -- target field strength (%)
local maxTemp        = 7750        -- emergency temp (C)
local safeTemp       = 3000        -- temp where restart allowed
local lowFieldPer    = 15          -- emergency field cutoff (%)
local activateOnCharge = true
local version        = 0.31

-- Control behaviour
-- outputProtect:
--   When TRUE, the script will *temporarily* cap/reduce the OUTPUT flow gate if the reactor is getting unsafe.
--   This is the actual fix for "output spikes -> reactor overheats because shield can't keep up".
local outputProtect = true

-- thresholds for output protection
local minSatPercent        = 25    -- if saturation below this, cut output
local highTempSoftLimit    = 7200  -- start cutting output before maxTemp
local lowFieldSoftLimit    = 35    -- start cutting output before lowFieldPer

-- how aggressive we are when cutting output
local outStepBig  = 250000         -- rf/t per step when "really bad"
local outStepSmall= 50000          -- rf/t per step when "slightly bad"
local outMin      = 0              -- never go below this

-- Input gate control (kept from original, but clamped + smoothed a bit)
local autoInputGate = 1
local curInputGate  = 222000
local inMin         = 10
local inMax         = 50000000

-- === Peripherals ===
local monitor = f.periphSearch("monitor")
local reactor = f.periphSearch("draconic_reactor")

-- Flowgate detection: input gate must be set to 10 rf/t once to identify it.
local function detectFlowGates()
  local gates = { peripheral.find("flow_gate") }
  if #gates < 2 then
    error("Error: Less than 2 flow gates detected!")
  end

  print("Please set input flow gate to **10 RF/t** manually (Signal LOW).")
  local inputGate, outputGate, inputName, outputName

  while not inputGate do
    sleep(1)
    for _, name in pairs(peripheral.getNames()) do
      if peripheral.getType(name) == "flow_gate" then
        local gate = peripheral.wrap(name)
        local setFlow = gate.getSignalLowFlow()
        if setFlow == 10 then
          inputGate, inputName = gate, name
          print("Detected input gate:", name)
        else
          outputGate, outputName = gate, name
        end
      end
    end
  end

  if not outputGate then
    print("Error: Could not identify output gate!")
    return nil, nil, nil, nil
  end

  return inputGate, outputGate, inputName, outputName
end

local function saveFlowGateNames(inputName, outputName)
  local file = fs.open("flowgate_names.txt", "w")
  file.writeLine(inputName)
  file.writeLine(outputName)
  file.close()
  print("Saved flow gate names for reboot!")
end

local function loadFlowGateNames()
  if not fs.exists("flowgate_names.txt") then
    print("No saved flow gate names found! Running detection again...")
    return nil, nil, nil, nil
  end

  local file = fs.open("flowgate_names.txt", "r")
  local inputName = file.readLine()
  local outputName = file.readLine()
  file.close()

  print("Loaded saved flow gate names:", inputName, outputName)

  if peripheral.isPresent(inputName) and peripheral.isPresent(outputName) then
    return peripheral.wrap(inputName), peripheral.wrap(outputName), inputName, outputName
  end

  print("Saved peripherals not found! Running detection again...")
  return nil, nil, nil, nil
end

local function setupFlowGates()
  local inGate, outGate, inName, outName = loadFlowGateNames()
  if not inGate or not outGate then
    inGate, outGate, inName, outName = detectFlowGates()
    if inGate and outGate then
      saveFlowGateNames(inName, outName)
    else
      error("Flow gate setup failed! Make sure to set the input flow gate to 10 before running again!")
    end
  end
  return inGate, outGate
end

local inputFluxgate, fluxgate = setupFlowGates()

-- === Hard checks ===
if not monitor then error("No valid monitor was found") end
if not fluxgate then error("No valid output flow gate was found") end
if not inputFluxgate then error("No input flow gate was found. Please set the LOW signal value to 10 once.") end
if not reactor then error("No reactor was found") end

-- === Monitor wrapper (original style) ===
local monX, monY = monitor.getSize()
local mon = { monitor = monitor, X = monX, Y = monY }
f.firstSet(mon)

function mon.clear()
  mon.monitor.setBackgroundColor(colors.black)
  mon.monitor.clear()
  mon.monitor.setCursorPos(1, 1)
  button.screen()
end

-- === Persist config ===
local function save_config()
  local sw = fs.open("reactorconfig.txt", "w")
  sw.writeLine(autoInputGate)
  sw.writeLine(curInputGate)
  sw.close()
end

local function load_config()
  local sr = fs.open("reactorconfig.txt", "r")
  autoInputGate = tonumber(sr.readLine())
  curInputGate = tonumber(sr.readLine())
  sr.close()
end

if not fs.exists("reactorconfig.txt") then save_config() else load_config() end

-- === Helpers ===
local function reset()
  term.clear()
  term.setCursorPos(1, 1)
end

local function reactorStatus(r)
  local statusTable = {
    running   = { "Online",        colors.green },
    cold      = { "Offline",       colors.gray  },
    warming_up= { "Charging",      colors.orange},
    cooling   = { "Cooling Down",  colors.blue  },
    stopping  = { "Shutting Down", colors.red   },
  }
  return statusTable[r] or statusTable["stopping"]
end

local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

local function getPercentage(value, maxValue)
  return math.ceil(value / maxValue * 10000) * 0.01
end

local function getTempColor(temp)
  if temp <= 5000 then return colors.green end
  if temp <= 6500 then return colors.orange end
  return colors.red
end

local function getFieldColor(percent)
  if percent >= 50 then return colors.blue end
  if percent > 30 then return colors.orange end
  return colors.red
end

local function getFuelColor(percent)
  if percent >= 70 then return colors.green end
  if percent > 30 then return colors.orange end
  return colors.red
end

-- === Emergency handling (same behaviour) ===
local action = "None since reboot"
local actioncolor = colors.gray
local emergencyCharge = false
local emergencyTemp = false

local function ActionMenu() end -- forward decl

local function emergencyShutdown(message)
  reactor.stopReactor()
  actioncolor = colors.red
  action = message
  ActionMenu()
end

local function checkReactorSafety(ri)
  local fuelPercent = 100 - math.ceil(ri.fuelConversion / ri.maxFuelConversion * 10000) * 0.01
  local fieldPercent = math.ceil(ri.fieldStrength / ri.maxFieldStrength * 10000) * 0.01

  if fuelPercent <= 10 then
    emergencyShutdown("Fuel Low! Refuel Now!")
  elseif fieldPercent <= lowFieldPer and ri.status == "running" then
    emergencyShutdown("Field Strength Below "..lowFieldPer.."%!")
    reactor.chargeReactor()
    emergencyCharge = true
  elseif ri.temperature > maxTemp then
    emergencyShutdown("Reactor Overheated!")
    emergencyTemp = true
  end
end

-- === Output protection (THE FIX) ===
local function protectOutputIfNeeded(ri)
  if not outputProtect then return end
  if ri.status ~= "running" then return end

  local satPercent = getPercentage(ri.energySaturation, ri.maxEnergySaturation)
  local fieldPercent = getPercentage(ri.fieldStrength, ri.maxFieldStrength)
  local outNow = fluxgate.getSignalLowFlow()

  local severe = (ri.temperature >= maxTemp - 150) or (fieldPercent <= lowFieldPer + 2) or (satPercent <= 10)
  local soft   = (ri.temperature >= highTempSoftLimit) or (fieldPercent <= lowFieldSoftLimit) or (satPercent <= minSatPercent)

  if severe or soft then
    local step = severe and outStepBig or outStepSmall
    local newOut = clamp(outNow - step, outMin, outNow)
    if newOut ~= outNow then
      fluxgate.setSignalLowFlow(newOut)
      actioncolor = severe and colors.red or colors.orange
      action = severe and "Output throttled (SEVERE)" or "Output throttled"
    end
  end
end

-- === Terminal output (unchanged logic, but less spam) ===
local lastTerminalValues = {}
local function drawTerminalText(x, y, label, newValue)
  local key = label
  if lastTerminalValues[key] ~= newValue then
    term.setCursorPos(x, y)
    term.clearLine()
    term.write(label .. ": " .. newValue)
    lastTerminalValues[key] = newValue
  end
end

-- === Monitor UI (original menus) ===
local MenuText = "Loading..."
local currentMenu = "main"

local function clearMenuArea()
  for i = 26, monY - 1 do
    f.draw_line(mon, 2, i, monX - 2, colors.black)
  end
  button.clearTable()
  f.draw_line(mon, 2, 26, monX - 2, colors.gray)
  f.draw_line(mon, 2, monY - 1, monX - 2, colors.gray)
  f.draw_line_y(mon, 2, 26, monY - 1, colors.gray)
  f.draw_line_y(mon, monX - 1, 26, monY - 1, colors.gray)
  f.draw_text(mon, 4, 26, " " .. MenuText .. " ", colors.white, colors.black)
end

local function toggleReactor()
  local ri = reactor.getReactorInfo()
  if ri.status == "running" then
    reactor.stopReactor()
  elseif ri.status == "stopping" then
    reactor.activateReactor()
  else
    reactor.chargeReactor()
  end
end

ActionMenu = function()
  currentMenu = "action"
  MenuText = "ATTENTION"
  clearMenuArea()
  button.setButton("action", action, function() end, 5, 28, monX - 4, 30, 0, 0, colors.red)
  button.screen()
end

local function rebootSystem()
  os.reboot()
end

local function buttonMain() end -- forward decl

local function buttonControls()
  if currentMenu == "controls" then return end
  currentMenu = "controls"
  MenuText = "CONTROLS"
  clearMenuArea()

  local sLength = 6 + (string.len("Toggle Reactor") + 1)
  button.setButton("toggle", "Toggle Reactor", toggleReactor, 6, 28, sLength, 30, 0, 0, colors.blue)

  local sLength2 = (sLength + 12 + (string.len("Reboot")) + 1)
  button.setButton("reboot", "Reboot", rebootSystem, sLength + 12, 28, sLength2, 30, 0, 0, colors.blue)

  local sLength3 = 4 + (string.len("Back") + 1)
  button.setButton("back", "Back", buttonMain, 4, 32, sLength3, 34, 0, 0, colors.blue)
  button.screen()
end

local function updateReactorInfo() end -- forward decl

local function changeOutputValue(num, val)
  local cFlow = fluxgate.getSignalLowFlow()
  if val == 1 then cFlow = cFlow + num else cFlow = cFlow - num end
  if cFlow < outMin then cFlow = outMin end
  fluxgate.setSignalLowFlow(cFlow)
  updateReactorInfo()
end

local function outputMenu()
  if currentMenu == "output" then return end
  currentMenu = "output"
  MenuText = "OUTPUT"
  clearMenuArea()

  local buttonData = {
    {label = ">>>>", value = 1000000, changeType = 1},
    {label = ">>>",  value = 100000,  changeType = 1},
    {label = ">>",   value = 10000,   changeType = 1},
    {label = ">",    value = 1000,    changeType = 1},
    {label = "<",    value = 1000,    changeType = 0},
    {label = "<<",   value = 10000,   changeType = 0},
    {label = "<<<",  value = 100000,  changeType = 0},
    {label = "<<<<", value = 1000000, changeType = 0},
  }

  local spacing = 2
  local buttonY = 28
  local currentX = monX - 7

  for _, data in ipairs(buttonData) do
    local buttonLength = string.len(data.label) + 1
    local startX = currentX - buttonLength
    local endX = startX + buttonLength
    button.setButton(data.label, data.label, changeOutputValue, startX, buttonY, endX, buttonY + 2, data.value, data.changeType, colors.blue)
    currentX = currentX - buttonLength - spacing
  end

  local backLength = 4 + string.len("Back") + 1
  button.setButton("back", "Back", buttonMain, 4, 32, backLength, 34, 0, 0, colors.blue)
  button.screen()
end

buttonMain = function()
  if currentMenu == "main" then return end
  currentMenu = "main"
  MenuText = "MAIN MENU"
  clearMenuArea()

  local sLength = 4 + (string.len("Controls") + 1)
  button.setButton("controls", "Controls", buttonControls, 4, 28, sLength, 30, 0, 0, colors.blue)

  local sLength2 = (sLength + 13 + (string.len("Output")) + 1)
  button.setButton("output", "Output", outputMenu, sLength + 13, 28, sLength2, 30, 0, 0, colors.blue)
  button.screen()
end

local lastValues = {}
local function drawUpdatedText(x, y, label, value, color)
  local key = label
  if lastValues[key] ~= value then
    f.draw_text_lr(mon, x, y, 3, " ", " ", colors.white, color, colors.black)
    f.draw_text_lr(mon, x, y, 3, label, value, colors.white, color, colors.black)
    lastValues[key] = value
  end
end

updateReactorInfo = function()
  local ri = reactor.getReactorInfo()
  if not ri then return end

  drawUpdatedText(4, 4,  "Status:",         reactorStatus(ri.status)[1], reactorStatus(ri.status)[2])
  drawUpdatedText(4, 5,  "Generation:",     f.format_int(ri.generationRate) .. " rf/t", colors.lime)

  local tempColor = getTempColor(ri.temperature)
  drawUpdatedText(4, 7,  "Temperature:",    f.format_int(ri.temperature) .. "C", tempColor)

  drawUpdatedText(4, 9,  "Output Gate:",    f.format_int(fluxgate.getSignalLowFlow()) .. " rf/t", colors.lightBlue)
  drawUpdatedText(4, 10, "Input Gate:",     f.format_int(inputFluxgate.getSignalLowFlow()) .. " rf/t", colors.lightBlue)

  local satPercent = getPercentage(ri.energySaturation, ri.maxEnergySaturation)
  drawUpdatedText(4, 12, "Energy Saturation:", satPercent .. "%", colors.green)
  f.progress_bar(mon, 4, 13, monX - 7, satPercent, 100, colors.green, colors.lightGray)

  local fieldPercent = getPercentage(ri.fieldStrength, ri.maxFieldStrength)
  local fieldColor = getFieldColor(fieldPercent)
  drawUpdatedText(4, 15, "Field Strength:", fieldPercent .. "%", fieldColor)
  f.progress_bar(mon, 4, 16, monX - 7, fieldPercent, 100, fieldColor, colors.lightGray)

  local fuelPercent = 100 - getPercentage(ri.fuelConversion, ri.maxFuelConversion)
  local fuelColor = getFuelColor(fuelPercent)
  drawUpdatedText(4, 18, "Fuel:", fuelPercent .. "%", fuelColor)
  f.progress_bar(mon, 4, 19, monX - 7, fuelPercent, 100, fuelColor, colors.lightGray)
end

local function reactorInfoScreen()
  mon.clear()
  f.draw_text(mon, 2, 38, "Made by: StormFusions v" .. version .. " (patched)", colors.gray, colors.black)

  f.draw_line(mon, 2, 22, monX - 2, colors.gray)
  f.draw_line(mon, 2, 2,  monX - 2, colors.gray)
  f.draw_line_y(mon, 2, 2, 22, colors.gray)
  f.draw_line_y(mon, monX - 1, 2, 22, colors.gray)
  f.draw_text(mon, 4, 2, " INFO ", colors.white, colors.black)

  f.draw_line(mon, 2, 26,    monX - 2, colors.gray)
  f.draw_line(mon, 2, monY - 1, monX - 2, colors.gray)
  f.draw_line_y(mon, 2, 26, monY - 1, colors.gray)
  f.draw_line_y(mon, monX - 1, 26, monY - 1, colors.gray)
  f.draw_text(mon, 4, 26, " " .. MenuText .. " ", colors.white, colors.black)

  while true do
    updateReactorInfo()
    sleep(1)
  end
end

-- === Main control loop (FIXED behaviour) ===
local function reactorControl()
  reset()
  local lastIn = inputFluxgate.getSignalLowFlow()

  while true do
    local ri = reactor.getReactorInfo()
    if not ri then
      print("Reactor not setup correctly. Retrying in 2s...")
      sleep(2)
      goto continue
    end

    local i = 1
    for k, v in pairs(ri) do
      drawTerminalText(1, i, k, tostring(v))
      i = i + 1
    end
    i = i + 1
    drawTerminalText(1, i, "Output Gate", tostring(fluxgate.getSignalLowFlow()))
    i = i + 1
    drawTerminalText(1, i, "Input Gate", tostring(inputFluxgate.getSignalLowFlow()))

    if emergencyCharge then reactor.chargeReactor() end

    if ri.status == "warming_up" then
      inputFluxgate.setSignalLowFlow(900000)
      emergencyCharge = false
    elseif ri.status == "stopping" and ri.temperature < safeTemp and emergencyTemp then
      reactor.activateReactor()
      emergencyTemp = false
    elseif ri.status == "warming_up" and activateOnCharge then
      reactor.activateReactor()
    end

    if ri.status == "running" then
      local desiredIn = (autoInputGate == 1)
        and (ri.fieldDrainRate / (1 - (targetStrength / 100)))
        or curInputGate

      desiredIn = clamp(desiredIn, inMin, inMax)

      local newIn = math.floor(lastIn + (desiredIn - lastIn) * 0.2)
      newIn = clamp(newIn, inMin, inMax)

      i = i + 1
      drawTerminalText(1, i, "Target Gate", tostring(newIn))

      inputFluxgate.setSignalLowFlow(newIn)
      lastIn = newIn
    end

    protectOutputIfNeeded(ri)
    checkReactorSafety(ri)

    sleep(0.2)
    ::continue::
  end
end

-- === Boot ===
mon.clear()
mon.monitor.setTextScale(0.5)
buttonMain()

parallel.waitForAny(reactorInfoScreen, reactorControl, button.clickEvent)
