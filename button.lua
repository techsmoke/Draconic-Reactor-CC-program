-- button.lua (CC:Tweaked os.loadAPI compatible)
--
-- Minimal button helper used by Draconic reactor CC programs.
--
-- os.loadAPI semantics:
--   After `os.loadAPI('lib/button')`, the global `button` becomes the API
--   environment table for this file. Because of that we must define API
--   functions as top-level globals (setButton, screen, clickEvent, ...),
--   NOT as `button.setButton = ...`.

local buttons = {}
local monitors = {}

local function defaultMonitors()
  monitors = { peripheral.find("monitor") }
end

defaultMonitors()

-- Optional: explicitly set monitors to draw on (e.g. single monitor).
function setMonitors(ms)
  if type(ms) == "table" and #ms > 0 then
    monitors = ms
  else
    defaultMonitors()
  end
end

-- Backwards-compat aliases some forks used
setMonitorsS = setMonitors

function clearTable()
  buttons = {}
end

function setButton(name, title, func, xmin, ymin, xmax, ymax, elem, elem2, color)
  buttons[name] = {
    title = tostring(title or ""),
    func = func,
    xmin = xmin,
    ymin = ymin,
    xmax = xmax,
    ymax = ymax,
    elem = elem,
    elem2 = elem2,
    color = color or colors.blue,
  }
end

local function drawOneButton(m, b)
  if not m or not b then return end

  m.setBackgroundColor(b.color)
  m.setTextColor(colors.white)

  local yMid = math.floor((b.ymin + b.ymax) / 2)
  local width = (b.xmax - b.xmin)
  local title = b.title or ""
  local xMid = math.floor((width - #title) / 2)

  for y = b.ymin, b.ymax do
    m.setCursorPos(b.xmin, y)
    if y == yMid then
      for x = 0, width do
        if x == xMid then
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

-- Draw all known buttons.
-- If targetMonitor is provided, draw only on that monitor.
function screen(targetMonitor)
  local ms
  if targetMonitor then
    ms = { targetMonitor }
  else
    if #monitors == 0 then defaultMonitors() end
    ms = monitors
  end

  for _, m in ipairs(ms) do
    -- don't clear here; caller controls background/UI
    for _, b in pairs(buttons) do
      if type(b) == "table" and b.xmin ~= nil then
        drawOneButton(m, b)
      end
    end
  end
end

function checkxy(x, y)
  for _, b in pairs(buttons) do
    if type(b) == "table" and b.xmin ~= nil then
      if y >= b.ymin and y <= b.ymax and x >= b.xmin and x <= b.xmax then
        if type(b.func) == "function" then
          b.func(b.elem, b.elem2)
        end
        return true
      end
    end
  end
  return false
end

-- Blocking event loop; intended to be run in parallel with your main loop.
function clickEvent()
  while true do
    local _, _, x, y = os.pullEvent("monitor_touch")
    checkxy(x, y)
  end
end
