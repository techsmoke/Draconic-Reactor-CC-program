-- Multi-monitor button helper (techsmoke)
-- CC:Tweaked os.loadAPI() compatible:
--  - NO 'local button = {}'
--  - NO 'return button'
--
-- Backwards compatible:
--   button.setButton(...)
--   button.clearTable()
--   button.screen([monitor])   -- draw on all monitors or a specific one
--   button.clickEvent()        -- blocks and dispatches monitor touches
--
-- New:
--   button.setMonitors({monitor1, monitor2, ...})

button = button or {}

-- Internal button storage (NOT on `button` table to avoid conflicts)
local _buttons = {}
local _monitors = {}

local function _defaultMonitors()
  local ms = { peripheral.find("monitor") }
  if #ms > 0 then
    _monitors = ms
  else
    _monitors = {}
  end
end

-- Initialize monitor list once (can be overridden later)
_defaultMonitors()

-- Allow main program to provide monitor list explicitly
function button.setMonitors(ms)
  if type(ms) == "table" and #ms > 0 then
    _monitors = ms
  else
    _defaultMonitors()
  end
end

-- Remove all button definitions
function button.clearTable()
  _buttons = {}
end

-- Create/replace a button definition
function button.setButton(name, title, func, xmin, ymin, xmax, ymax, elem, elem2, color)
  _buttons[name] = {
    title = tostring(title or ""),
    func  = func,
    xmin  = xmin, ymin = ymin, xmax = xmax, ymax = ymax,
    color = color or colors.blue,
    elem  = elem,
    elem2 = elem2,
  }
end

local function _fill(m, b)
  m.setBackgroundColor(b.color)
  m.setTextColor(colors.white)

  local yMid  = math.floor((b.ymin + b.ymax) / 2)
  local width = (b.xmax - b.xmin)
  local title = b.title
  local xMid  = math.floor((width + 1 - #title) / 2)

  for y = b.ymin, b.ymax do
    m.setCursorPos(b.xmin, y)

    if y == yMid then
      -- build line with centered title
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

-- Draw buttons:
--  - if targetMonitor given -> only that one
--  - else -> all known monitors (auto-detect fallback)
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
    for _, b in pairs(_buttons) do
      _fill(m, b)
    end
  end
end

-- Hit test + dispatch
function button.checkxy(x, y)
  for _, b in pairs(_buttons) do
    if y >= b.ymin and y <= b.ymax and x >= b.xmin and x <= b.xmax then
      if type(b.func) == "function" then
        b.func(b.elem, b.elem2)
      end
      return true
    end
  end
  return false
end

-- Blocking event loop: reacts to monitor_touch from ANY monitor
function button.clickEvent()
  while true do
    local _, _, x, y = os.pullEvent("monitor_touch")
    button.checkxy(x, y)
  end
end
