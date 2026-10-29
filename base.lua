-- Tower Base v1: reads your power buffer (and AE2, if connected) and broadcasts it
-- to your Smart Glasses and screens over an Ender Modem.
-- Needs: this computer + an Ender Modem + a wired modem network reaching the energy cube.
-- Optional: an ME Bridge on the same network.
-- Run:  base        Stop: hold Ctrl+T

---------------------------------- settings ----------------------------------
local INTERVAL = 2       -- seconds between updates
local CUBE     = nil     -- e.g. "energyCube_0"; nil finds the first Mekanism energy cube / induction port
local PROTOCOL = "tower"
-------------------------------------------------------------------------------

local function wireless()
  return peripheral.find("modem", function(_, m) return m.isWireless() end)
end
local ender = wireless()
if not ender then error("No Ender Modem on this computer. Put one on any side.", 0) end
rednet.open(peripheral.getName(ender))

local function findCube()
  if CUBE then return peripheral.wrap(CUBE) end
  for _, n in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(n) or ""
    if (t:find("[Ee]nergy[Cc]ube") or t:find("[Ii]nduction")) and peripheral.wrap(n).getEnergyFilledPercentage then
      return peripheral.wrap(n), n
    end
  end
end

local last = nil   -- previous reading, for net FE/t
local function readPower(cube)
  local ok, stored = pcall(cube.getEnergy)
  local ok2, max = pcall(cube.getMaxEnergy)
  if not ok or not ok2 or not max or max <= 0 then return nil end
  local now = os.clock()
  local net = nil
  if last and now > last.t then net = (stored - last.e) / ((now - last.t) * 20) end   -- FE per tick
  last = { e = stored, t = now }
  return { pct = stored / max, stored = stored, max = max, net = net }
end

local function readAE(me)
  local ok, used = pcall(me.getUsedItemStorage)
  local ok2, max = pcall(me.getMaxItemStorage)
  if not ok or not ok2 or not used or not max or max <= 0 then return nil end
  return { pct = used / max }
end

local function fmtFE(v)
  local a = math.abs(v)
  if a < 0.5 then return "0" end
  local s = a >= 1e9 and ("%.1fG"):format(a / 1e9) or a >= 1e6 and ("%.1fM"):format(a / 1e6)
         or a >= 1e3 and ("%.1fk"):format(a / 1e3) or ("%d"):format(math.floor(a + 0.5))
  return (v < 0 and "-" or "+") .. s
end

term.clear(); term.setCursorPos(1, 1)
print("Tower Base broadcasting on '" .. PROTOCOL .. "'. Hold Ctrl+T to stop.")
while true do
  local cube, cubeName = findCube()
  local me = peripheral.find("me_bridge")
  local msg = { kind = "base", day = os.day(), time = os.time() }
  if cube then msg.power = readPower(cube) end
  if me then msg.ae = readAE(me) end
  rednet.broadcast(msg, PROTOCOL)

  local _, y = term.getCursorPos()
  term.setCursorPos(1, 3); term.clearLine()
  if msg.power then
    local p = msg.power
    write(("Power %3d%%  %s FE/t"):format(math.floor(p.pct * 100 + 0.5), p.net and fmtFE(p.net) or "..."))
  else
    write("Power: no energy cube found on the network")
  end
  term.setCursorPos(1, 4); term.clearLine()
  write(msg.ae and ("AE2   %3d%% full"):format(math.floor(msg.ae.pct * 100 + 0.5)) or "AE2: no ME Bridge (optional)")
  sleep(INTERVAL)
end
