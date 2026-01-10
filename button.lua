
local button = {}
local mon = peripheral.find("monitor")

function clearTable()
   button = {}
end

function setButton(name, title, func, xmin, ymin, xmax, ymax, elem, elem2, color)
   button[name] = {}
   button[name]["title"] = title
   button[name]["func"] = func
      button[name]["active"] = false
      button[name]["xmin"] = xmin
      button[name]["ymin"] = ymin
      button[name]["xmax"] = xmax
      button[name]["ymax"] = ymax
      button[name]["color"] = color
      button[name]["elem"] = elem
      button[name]["elem2"] = elem2
end

-- stuff and things for buttons

function fill(text, color, bData)
   mon.setBackgroundColor(color)
   mon.setTextColor(colors.white)
   local yspot = math.floor((bData["ymin"] + bData["ymax"]) /2)
   local xspot = math.floor((bData["xmax"] - bData["xmin"] - string.len(bData["title"])) /2) +1
   for j = bData["ymin"], bData["ymax"] do
      mon.setCursorPos(bData["xmin"], j)
      if j == yspot then
         for k = 0, bData["xmax"] - bData["xmin"] - string.len(bData["title"]) +1 do
            if k == xspot then
               mon.write(bData["title"])
            else
               mon.write(" ")
            end
         end
      else
         for i = bData["xmin"], bData["xmax"] do
            mon.write(" ")
         end
      end
   end
   mon.setBackgroundColor(colors.black)
end

-- stuff and things for buttons

function screen()
   local currColor
   for name,data in pairs(button) do
      local on = data["active"]
      currColor = data["color"]
      fill(name, currColor, data)
   end
end

-- magical handler for clicky clicks

function checkxy(x, y)
   for name, data in pairs(button) do
      if y>=data["ymin"] and  y <= data["ymax"] then
         if x>=data["xmin"] and x<= data["xmax"] then
            data["func"](data["elem"], data["elem2"])
            --flash(data['name'])
            return true
            --data["active"] = not data["active"]
            --print(name)
         end
      end
   end
   return false
end

function clickEvent()
   while true do
      local myEvent={os.pullEvent("monitor_touch")}
      checkxy(myEvent[3], myEvent[4])
   end
end