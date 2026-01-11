-- Multi-monitor button helper (techsmoke)
-- CC:Tweaked os.loadAPI() expects globals in the API environment.
-- So: DO NOT make the main table local.

button = button or {}

local monitors = {}

local function defaultMonitors()
  local ms = { peripheral.find("monitor") }
  if #ms > 0 then monitors = ms end
end

defaultMonitors()

-- New: provide all monitors that should be used for drawing and touch handling
function button.setMonitors(ms)
  if type(ms) == "table" and #ms > 0 then
    monitors = ms
  else
    defaultMonitors()
  end
end

-- Clear only stored button definitions (not API functions)
function button.clearTable()
  for name, data in pairs(button) do
    if type(data) == "table" and data.xmin ~= nil then
      button[name] = nil
    end
  end
end

function button.setButton(name, title, func, xmin, ymin, xmax, ymax, elem, elem2, color)
  button[name] = {
    title = title,
    func = func,
    xmin = xmin, ymin = ymin,
    xmax = xmax, ymax = ymax,
    color = color or colors.blue,
    elem = elem, elem2 = elem2,
  }
end

local function fill(m, bData)
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

-- Draw all buttons on one monitor (internal) or all configured monitors
function button.screen(targetMonitor)
  local ms
  if targetMonitor then
    ms = { targetMonitor }
  else
    ms = monitors
  end

  for _, m in ipairs(ms) do
    for _, data in pairs(button) do
      if type(data) == "table" and data.xmin ~= nil then
        fill(m, data)
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

-- Blocking touch loop: accepts touches from ANY monitor in the network
function button.clickEvent()
  while true do
    local ev, side, x, y = os.pullEvent("monitor_touch")
    button.checkxy(x, y)
  end
end
