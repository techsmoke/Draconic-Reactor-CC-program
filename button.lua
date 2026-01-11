-- button.lua
-- Minimal Button API for CC:Tweaked (os.loadAPI compatible)
-- Provides:
--   button.setButton(...)
--   button.clearTable()
--   button.screen([monitor])     -- draw buttons (all known monitors or one)
--   button.clickEvent()          -- blocking monitor_touch loop
--   button.setMonitors(list)     -- set monitor peripherals explicitly (optional)
--
-- This file MUST NOT use `local button = {}` or `return button` when loaded via os.loadAPI.

button = button or {}

-- wrapped monitor peripherals we draw on
local _monitors = {}

local function _defaultMonitors()
  local ms = { peripheral.find("monitor") }
  if #ms > 0 then
    _monitors = ms
  else
    _monitors = {}
  end
end

_defaultMonitors()

function button.setMonitors(ms)
  if type(ms) == "table" and #ms > 0 then
    _monitors = ms
  else
    _defaultMonitors()
  end
end

-- Backwards compat (some forks used this name)
button.setMonitorsS = button.setMonitors
button.setMonitor = function(m) button.setMonitors({ m }) end

-- Remove only button definitions; keep API functions intact
function button.clearTable()
  for name, data in pairs(button) do
    if type(data) == "table" and data.xmin ~= nil then
      button[name] = nil
    end
  end
end

function button.setButton(name, title, func, xmin, ymin, xmax, ymax, elem, elem2, color)
  button[name] = {
    title = tostring(title or ""),
    func  = func,
    xmin  = xmin,
    ymin  = ymin,
    xmax  = xmax,
    ymax  = ymax,
    color = color or colors.blue,
    elem  = elem,
    elem2 = elem2,
  }
end

local function _fill(m, bData)
  m.setBackgroundColor(bData.color)
  m.setTextColor(colors.white)

  local yspot = math.floor((bData.ymin + bData.ymax) / 2)
  local width = (bData.xmax - bData.xmin)
  local title = tostring(bData.title or "")
  local xspot = math.floor((width - #title) / 2)

  for y = bData.ymin, bData.ymax do
    m.setCursorPos(bData.xmin, y)
    if y == yspot then
      for x = 0, width do
        if x == xspot then
          m.write(title)
          x = x + #title - 1
        else
          m.write(" ")
        end
      end
    else
      m.write(string.rep(" ", width + 1))
    end
  end

  m.setBackgroundColor(colors.black)
end

function button.screen(targetMonitor)
  local ms
  if targetMonitor then
    ms = { targetMonitor }
  else
    ms = _monitors
    if #ms == 0 then
      _defaultMonitors()
      ms = _monitors
    end
  end

  for _, m in ipairs(ms) do
    for _, data in pairs(button) do
      if type(data) == "table" and data.xmin ~= nil then
        _fill(m, data)
      end
    end
  end
end

function button.checkxy(x, y)
  for _, data in pairs(button) do
    if type(data) == "table" and data.xmin ~= nil then
      if y >= data.ymin and y <= data.ymax and x >= data.xmin and x <= data.xmax then
        if type(data.func) == "function" then
          data.func(data.elem, data.elem2)
        end
        return true
      end
    end
  end
  return false
end

function button.clickEvent()
  while true do
    local _, _, x, y = os.pullEvent("monitor_touch")
    button.checkxy(x, y)
  end
end
