-- Multi-monitor button helper (techsmoke)
-- CC:Tweaked os.loadAPI() compatible:
--  - NO 'local button = {}'
--  - NO 'return button'
--
-- Backwards compatible API used by reactor.lua:
--   button.setButton(...)
--   button.clearTable()
--   button.screen([monitor])
--   button.clickEvent()
--
-- Optional:
--   button.setMonitors({monitor1, monitor2, ...})

button = button or {}

-- store button definitions inside global table to remain compatible with older scripts
-- (some scripts iterate pairs(button) and expect the definitions there)
local _internalKeys = {
  setMonitors=true, clearTable=true, setButton=true, screen=true, checkxy=true, clickEvent=true
}

local function _isButtonDef(v)
  return type(v) == "table" and v.xmin ~= nil and v.ymin ~= nil and v.xmax ~= nil and v.ymax ~= nil
end

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

function button.clearTable()
  for k, v in pairs(button) do
    if _isButtonDef(v) then
      button[k] = nil
    end
  end
end

function button.setButton(name, title, func, xmin, ymin, xmax, ymax, elem, elem2, color)
  button[name] = {
    title = tostring(title or ""),
    func  = func,
    xmin  = xmin, ymin = ymin, xmax = xmax, ymax = ymax,
    color = color or colors.blue,
    elem  = elem,
    elem2 = elem2,
  }
end

local function _fill(m, b)
  m.setBackgroundColor(b.color or colors.blue)
  m.setTextColor(colors.white)

  local yMid  = math.floor((b.ymin + b.ymax) / 2)
  local width = (b.xmax - b.xmin)
  local title = tostring(b.title or "")
  local xMid  = math.floor((width + 1 - #title) / 2)

  for y = b.ymin, b.ymax do
    m.setCursorPos(b.xmin, y)
    if y == yMid then
      if #title > (width + 1) then
        m.write(string.sub(title, 1, width + 1))
      else
        m.write(string.rep(" ", math.max(0, xMid)))
        m.write(title)
        local rest = (width + 1) - (xMid + #title)
        if rest > 0 then m.write(string.rep(" ", rest)) end
      end
    else
      m.write(string.rep(" ", width + 1))
    end
  end

  m.setBackgroundColor(colors.black)
  m.setTextColor(colors.white)
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
    for _, v in pairs(button) do
      if _isButtonDef(v) then
        _fill(m, v)
      end
    end
  end
end

function button.checkxy(x, y)
  for _, v in pairs(button) do
    if _isButtonDef(v) then
      if y >= v.ymin and y <= v.ymax and x >= v.xmin and x <= v.xmax then
        if type(v.func) == "function" then
          v.func(v.elem, v.elem2)
        end
        return true
      end
    end
  end
  return false
end

-- IMPORTANT: clickEvent MUST be a function reference (for parallel.waitForAny)
-- so reactor.lua can call: parallel.waitForAny(mainLoop, button.clickEvent)
function button.clickEvent()
  while true do
    local _, _, x, y = os.pullEvent("monitor_touch")
    button.checkxy(x, y)
  end
end
