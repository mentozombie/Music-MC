-- Tower Glasses v1.1: ore X-ray + base HUD for Advanced Peripherals Smart Glasses.
-- Glasses slots:  peripherals = Geo Scanner, Ender Modem
--                 modules     = Overlay Module, Hotkey Module
-- Hotkey (G by default):  tap = X-ray on/off,  hold = all ores / valuables only
-- Run on the glasses:  glasses        Stop: hold Ctrl+T

---------------------------------- settings ----------------------------------
local CORNER     = "left"   -- HUD in the top "left" or top "right" corner
local XRAY_START = true     -- X-ray on when the program starts
local KEEP_DIST  = 20       -- forget ores farther away than this many blocks
local OPACITY    = 0.35     -- how solid the ore boxes look (0 to 1)
local PROTOCOL   = "tower"
-------------------------------------------------------------------------------

local RADIUS = 8   -- the glasses' Geo Scanner can only scan 8 blocks for free (no fuel in glasses)

if not smartglasses then error("Run this on Smart Glasses.", 0) end
local ov = smartglasses.modules["advancedperipherals:overlay"]
if not ov then error("Put an Overlay Module in the glasses.", 0) end
local geo = peripheral.find("geo_scanner")
local ender = peripheral.find("modem", function(_, m) return m.isWireless() end)
if ender then rednet.open(peripheral.getName(ender)) end

ov.clear()
ov.setAutoUpdate(false)

------------------------------- ore detection -------------------------------
local ORES = {   -- name contains, box colour, valuable?
  { "ancient_debris", 0xc07bff, true }, { "allthemodium", 0xffd84a, true }, { "vibranium", 0x40ffd2, true },
  { "unobtainium", 0xe07bff, true },    { "diamond", 0x55f6ff, true },      { "emerald", 0x45e36e, true },
  { "uranium", 0xa6ff3d, true },        { "gold", 0xffd23b, true },         { "redstone", 0xff3b3b, false },
  { "lapis", 0x3d6bff, false },         { "iron", 0xe0aa82, false },        { "copper", 0xe57a3d, false },
  { "coal", 0x5c5c5c, false },          { "quartz", 0xf2f2f2, false },      { "osmium", 0x9cbcde, false },
  { "tin", 0xcfd6de, false },           { "lead", 0x7272aa, false },        { "silver", 0xdfe6f0, false },
  { "nickel", 0xd6d6a6, false },        { "zinc", 0xaacfb4, false },        { "aluminum", 0xd6d6d6, false },
  { "platinum", 0xb8e6ff, false },      { "iridium", 0xe6e6ff, false },     { "fluorite", 0xff9fe6, false },
  { "certus", 0xa6dcff, false },        { "sulfur", 0xf2e64a, false },
}
local kind = {}   -- block name -> { colour, valuable } or false
local function classify(b)
  local n = b.name
  local k = kind[n]
  if k ~= nil then return k end
  local ore = n:find("_ore$") or n:find(":ore_") or n:find("ancient_debris")
  if not ore and type(b.tags) == "table" then
    for t in pairs(b.tags) do
      if t:find("c:ores$") or t:find("c:ores/") then ore = true; break end
    end
  end
  k = false
  if ore then
    k = { 0xffffff, false }
    for _, o in ipairs(ORES) do
      if n:find(o[1], 1, true) then k = { o[2], o[3] }; break end
    end
  end
  kind[n] = k
  return k
end

------------------------------------ state ------------------------------------
local xray, mode = XRAY_START, "all"
local ores, shownCount = {}, 0
local base, baseAt, radio, radioAt = nil, nil, nil, nil

local function visible(o) return xray and (mode == "all" or o.valuable) end
local function applyVisibility()
  shownCount = 0
  for _, o in pairs(ores) do
    local v = visible(o)
    o.obj.setEnabled(v)
    if v then shownCount = shownCount + 1 end
  end
  ov.update()
end

local function newBox(o)
  o.obj = ov.createBox({ x = o.x + 0.5, y = o.y + 0.5, z = o.z + 0.5, sizeX = 1, sizeY = 1, sizeZ = 1,
                         color = o.color, opacity = OPACITY, depthTest = false, depthMask = false,
                         enabled = visible(o) })
end

------------------------------------- HUD -------------------------------------
local PW, LH, ROWS = 172, 11, 6
local GOLD, DIM, TEXT, GOOD, WARN, BAD = 0xffb300, 0xa8936a, 0xfff3d6, 0x7bdc5a, 0xffd23b, 0xff5a4a
local HUD_OBJECTS = 1 + 2 * ROWS
local bg, labels, values, lastX, lastY
local function buildHud()
  bg = ov.createRectangle({ gui = true, x = 0, y = 0, sizeX = PW, sizeY = 10, color = 0x100c05, opacity = 0.55 })
  labels, values, lastX, lastY = {}, {}, nil, nil
  for i = 1, ROWS do
    labels[i] = ov.createText({ gui = true, content = "", color = DIM, shadow = true })
    values[i] = ov.createText({ gui = true, content = "", color = TEXT, shadow = true })
  end
end
buildHud()

-- The mod wipes everything drawn whenever the glasses leave your head.
-- When that happens, draw it all again from scratch.
local function rebuild()
  ov.clear()
  buildHud()
  for _, o in pairs(ores) do newBox(o) end
  ov.update()
end

local function fmtFE(v)
  local a = math.abs(v)
  if a < 0.5 then return "0" end
  local s = a >= 1e9 and ("%.1fG"):format(a / 1e9) or a >= 1e6 and ("%.1fM"):format(a / 1e6)
         or a >= 1e3 and ("%.1fk"):format(a / 1e3) or ("%d"):format(math.floor(a + 0.5))
  return (v < 0 and "-" or "+") .. s
end
local function fmtTime(s)
  s = math.max(0, math.floor(s))
  return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end
local function clock()
  local h = os.time()
  local hh, mm = math.floor(h), math.floor((h % 1) * 60)
  local h12 = hh % 12
  if h12 == 0 then h12 = 12 end
  return ("%d:%02d %s"):format(h12, mm, hh >= 12 and "PM" or "AM")
end
local function cut(s, n) if #s <= n then return s end return s:sub(1, n - 1) .. "." end

local function drawHud()
  local now = os.clock()
  local rows = {}
  rows[#rows + 1] = { "TOWER", clock() .. "  Day " .. os.day(), GOLD, TEXT }

  local fresh = base and now - baseAt < 10
  if fresh and base.power then
    local p = base.power
    local pct = math.floor(p.pct * 100 + 0.5)
    local c = pct >= 50 and GOOD or pct >= 20 and WARN or BAD
    rows[#rows + 1] = { "PWR", pct .. "%" .. (p.net and ("  " .. fmtFE(p.net) .. " FE/t") or ""), DIM, c }
  elseif ender then
    rows[#rows + 1] = { "PWR", fresh and "no energy cube found" or "no signal from base", DIM, DIM }
  end
  if fresh and base.ae then
    local pct = math.floor(base.ae.pct * 100 + 0.5)
    rows[#rows + 1] = { "AE2", pct .. "% full", DIM, pct >= 90 and BAD or pct >= 75 and WARN or TEXT }
  end
  if radio and now - radioAt < 10 then
    local pos = radio.pos + (radio.playing and (now - radioAt) or 0)
    local song = cut(radio.title .. " - " .. radio.artist, 22)
    rows[#rows + 1] = { radio.playing and "PLAY" or "PAUSE", song .. "  " .. fmtTime(math.min(pos, radio.dur)), DIM, TEXT }
  end
  if not geo then
    rows[#rows + 1] = { "XRAY", "add a Geo Scanner", DIM, BAD }
  else
    rows[#rows + 1] = { "XRAY", xray and ((mode == "all" and "all ores" or "valuables") .. "  " .. shownCount .. " near") or "off",
                        DIM, xray and GOOD or DIM }
  end
  local alert
  if fresh and base.power and base.power.pct < 0.2 then alert = "LOW POWER"
  elseif fresh and base.ae and base.ae.pct >= 0.9 then alert = "AE2 ALMOST FULL"
  elseif not ender then alert = "no Ender Modem: base stats off" end
  if alert then rows[#rows + 1] = { "!", alert, BAD, BAD } end

  local w, h, scale = ov.getGuiSize()
  local sw = (w or 854) / ((scale and scale > 0) and scale or 2)
  local x0 = CORNER == "right" and math.floor(sw - PW - 4) or 4
  local y0 = 4
  if x0 ~= lastX or y0 ~= lastY then bg.setPos(x0, y0, 0); lastX, lastY = x0, y0 end
  bg.setSizes(PW, #rows * LH + 5)
  for i = 1, ROWS do
    local r = rows[i]
    labels[i].setPos(x0 + 4, y0 + 3 + (i - 1) * LH, 0)
    values[i].setPos(x0 + 40, y0 + 3 + (i - 1) * LH, 0)
    if r then
      labels[i].setContent(r[1]); labels[i].setColor(r[3]); labels[i].setEnabled(true)
      values[i].setContent(r[2]); values[i].setColor(r[4]); values[i].setEnabled(true)
    else
      labels[i].setEnabled(false); values[i].setEnabled(false)
    end
  end
  ov.update()
end

----------------------------------- scanning -----------------------------------
local function scanLoop()
  while true do
    if xray and geo then
      local me = smartglasses.getOwner()
      local ok, res = pcall(geo.scanBlocks, RADIUS)
      if me and ok and type(res) == "table" then
        local px, py, pz = me.x, me.y, me.z
        local seen = {}
        for _, b in ipairs(res) do
          local k = classify(b)
          if k then
            -- scan coords are block centre minus your position
            local bx, by, bz = math.floor(px + b.x), math.floor(py + b.y), math.floor(pz + b.z)
            local key = bx .. "," .. by .. "," .. bz
            seen[key] = true
            if not ores[key] then
              local o = { x = bx, y = by, z = bz, color = k[1], valuable = k[2] }
              newBox(o)
              ores[key] = o
            end
          end
        end
        for key, o in pairs(ores) do
          local dx, dy, dz = o.x + 0.5 - px, o.y + 0.5 - py, o.z + 0.5 - pz
          local d2 = dx * dx + dy * dy + dz * dz
          if (d2 <= (RADIUS - 1) ^ 2 and not seen[key]) or d2 > KEEP_DIST ^ 2 then
            ov.removeObject(o.obj.getId())       -- mined, or too far away
            ores[key] = nil
          end
        end
        applyVisibility()
      end
    end
    sleep(2.05)
  end
end

------------------------------------ events ------------------------------------
local function eventLoop()
  drawHud()
  local tmr = os.startTimer(1)
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "rednet_message" and c == PROTOCOL and type(b) == "table" then
      if b.kind == "base" then base, baseAt = b, os.clock()
      elseif b.kind == "radio" then radio, radioAt = b, os.clock() end
    elseif e == "glasses_key_pressed" then
      if (b or 0) >= 400 then mode = (mode == "all") and "valuable" or "all" else xray = not xray end
      applyVisibility(); drawHud()
    elseif e == "glasses_rebuild" then
      rebuild(); applyVisibility(); drawHud()
    elseif e == "timer" and a == tmr then
      drawHud(); tmr = os.startTimer(1)
    end
  end
end

-- notices when you put the glasses back on (or the drawing got wiped) and redraws
local function watchLoop()
  local was = true
  while true do
    local eq = smartglasses.isEquipped()
    if eq and (not was or ov.getObjectsCount() < HUD_OBJECTS) then os.queueEvent("glasses_rebuild") end
    was = eq
    sleep(1)
  end
end

term.clear(); term.setCursorPos(1, 1)
print("Tower Glasses running.")
print(geo and "Geo Scanner: ok" or "Geo Scanner: missing (no X-ray)")
print(ender and "Ender Modem: ok" or "Ender Modem: missing (no base stats)")
print("Hotkey: tap = X-ray on/off, hold = all/valuables")
print("Hold Ctrl+T to stop.")
local ok, err = pcall(parallel.waitForAny, scanLoop, eventLoop, watchLoop)
ov.clear()
ov.update()
if not ok and err ~= "Terminated" then printError(err) end
print("Tower Glasses stopped.")
