-- button API (os.loadAPI compatible)
-- Exposes: setButton, clearTable, screen, checkxy, clickEvent

-- IMPORTANT for os.loadAPI:
--  - define functions at top-level (no 'button.' prefix)
--  - no 'return'

if not button then button = {} end

local function isButtonDef(v)
  return type(v) == "table" and v.xmin and v.ymin and v.xmax and v.ymax
end

function clearTable()
  for k, v in pairs(button) do
    if isButtonDef(v) then button[k] = nil end
  end
end

function setButton(name, title, func, xmin, ymin, xmax, ymax, elem, elem2, color)
  button[name] = {
    title = tostring(title or ""),
    func  = func,
    xmin  = xmin, ymin = ymin, xmax = xmax, ymax = ymax,
    color = color or colors.blue,
    elem  = elem, elem2 = elem2,
  }
end

local function fill(m, b)
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

function screen(targetMonitor)
  local ms = {}
  if targetMonitor then
    ms = { targetMonitor }
  else
    ms = { peripheral.find("monitor") }
  end

  for _, m in ipairs(ms) do
    for _, v in pairs(button) do
      if isButtonDef(v) then fill(m, v) end
    end
  end
end

function checkxy(x, y)
  for _, v in pairs(button) do
    if isButtonDef(v) then
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

function clickEvent()
  while true do
    local _, _, x, y = os.pullEvent("monitor_touch")
    checkxy(x, y)
  end
end
