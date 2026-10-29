-- The Watcher v1: a floating robot eye that hunts you down.
-- Runs on the computer inside the eye box. First run (or "watcher setup") calibrates it.
-- Run:  watcher        Recalibrate: watcher setup        Stop: hold Ctrl+T

---------------------------------- settings ----------------------------------
local TEXT_SCALE      = 0.5   -- 0.5 = finer eye (heavier), 1 = chunkier (lighter)
local FPS             = 5     -- screen updates per second; lower it if the server lags
local WAKE            = 64    -- blocks: it notices you
local SHOW            = 24    -- blocks: music reactions kick in
local LOCK            = 12    -- blocks: it locks on
local UNLOCK          = 16    -- blocks: you break the lock
local VERTICAL_WEIGHT = 0.3   -- how much height counts toward distance (it lives up high)
local PROTOCOL        = "tower"
local CFG             = "watcher.cfg"
-------------------------------------------------------------------------------

local args = { ... }
local det = peripheral.find("player_detector")
if not det then error("No Player Detector found. It must touch the computer.", 0) end
local relay = peripheral.find("redstone_relay")
local ender = peripheral.find("modem", function(_, m) return m.isWireless() end)
if ender then rednet.open(peripheral.getName(ender)) end
local monNames = {}
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.getType(n) == "monitor" then monNames[#monNames + 1] = n end
end
if #monNames < 4 then
  error(("Found %d monitors, need 4. Right-click the 4 monitor modems so they turn red."):format(#monNames), 0)
end

------------------------------- players ---------------------------------------
local function players(range)
  local ok, list = pcall(det.getPlayersInRange, range)
  if not ok or type(list) ~= "table" then return {} end
  local out = {}
  for _, e in ipairs(list) do
    local name = type(e) == "table" and (e.name or e.username) or e
    local ok2, p = pcall(det.getPlayer, name)
    if ok2 and type(p) == "table" and p.x then out[#out + 1] = { name = name, x = p.x, y = p.y, z = p.z } end
  end
  return out
end

------------------------------- config / setup --------------------------------
local function loadCfg()
  if not fs.exists(CFG) then return nil end
  local f = fs.open(CFG, "r"); local t = textutils.unserialise(f.readAll()); f.close()
  if type(t) == "table" and t.center and t.faces then return t end
end
local function saveCfg(t) local f = fs.open(CFG, "w"); f.write(textutils.serialise(t)); f.close() end

local function bigText(m, lines, fg)
  m.setTextScale(3); m.setBackgroundColour(colors.black); m.setTextColour(fg or colors.white); m.clear()
  local w, h = m.getSize()
  local y0 = math.floor((h - #lines) / 2) + 1
  for i, s in ipairs(lines) do m.setCursorPos(math.max(1, math.floor((w - #s) / 2) + 1), y0 + i - 1); m.write(s) end
end

local function setup()
  term.clear(); term.setCursorPos(1, 1)
  print("THE WATCHER - setup")
  print("")
  print("Step 1: stand inside the box, right next to the cable in the middle, then press Enter.")
  read()
  local ps = players(8)
  if #ps == 0 then error("Couldn't see you. Stand inside the box and run 'watcher setup' again.", 0) end
  local me = ps[1]
  local center = { x = me.x, y = me.y + 2, z = me.z }
  print(("Centre: %d, %d, %d"):format(math.floor(center.x), math.floor(center.y), math.floor(center.z)))
  print("")
  print("Step 2: fly outside and tap each of the 4 screens once, in any order.")
  for _, n in ipairs(monNames) do bigText(peripheral.wrap(n), { "TAP ME" }, colors.cyan) end
  local faces, used, count = {}, {}, 0
  while count < 4 do
    local _, name = os.pullEvent("monitor_touch")
    if not used[name] then
      local best, bd
      for _, p in ipairs(players(24)) do
        local d = (p.x - center.x) ^ 2 + (p.z - center.z) ^ 2
        if not bd or d < bd then best, bd = p, d end
      end
      if best then
        local dx, dz = best.x - center.x, best.z - center.z
        local face = math.abs(dx) > math.abs(dz) and (dx > 0 and "east" or "west") or (dz > 0 and "south" or "north")
        if faces[face] then
          print("Already have " .. face .. " - tap a different screen.")
        else
          faces[face], used[name], count = name, true, count + 1
          bigText(peripheral.wrap(name), { face:upper(), "OK" }, colors.lime)
          print(("  %s = %s  (%d/4)"):format(face, name, count))
        end
      end
    end
  end
  local cfg = { center = center, faces = faces }
  saveCfg(cfg)
  print("")
  print("Saved. Starting the Watcher...")
  sleep(1.5)
  return cfg
end

local cfg = loadCfg()
if args[1] == "setup" or not cfg then cfg = setup() end
local CX, CY, CZ = cfg.center.x, cfg.center.y, cfg.center.z

------------------------------- screens ---------------------------------------
local ORDER = { "north", "west", "south", "east" }   -- walking to the right around the head
local mons = {}
for i, f in ipairs(ORDER) do
  local m = peripheral.wrap(cfg.faces[f])
  if not m then error("Monitor for the " .. f .. " side is missing. Run 'watcher setup'.", 0) end
  m.setTextScale(TEXT_SCALE); mons[i] = m
end
local CW, CH = mons[1].getSize()
for i = 2, 4 do local w, h = mons[i].getSize(); CW, CH = math.min(CW, w), math.min(CH, h) end
local PW, PH = CW * 2, CH * 3                   -- mini-pixels per screen
local MW = 7                                    -- screen width in blocks
local SEG = MW + 1                              -- one side of the strip: 7 screen blocks + 1 pillar
local BPX = PW / MW
local GAP = math.floor(BPX + 0.5)
local STRIP = (PW + GAP) * 4
local HEX = "0123456789abcdef"
local HC = {}; for i = 0, 15 do HC[i] = HEX:sub(i + 1, i + 1) end

-- palette (indices). Iris, rail and core get re-tinted from cyan to red as it gets interested.
local BG, GLASS, MET, MET2, CORE0, CORE1, RAIL, CORE2, CORE3, CORE4, HI, GAPC, BLADE, IRIS, IRIS2, BLADE2 =
      0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
local BASE = { [0] = 0x07050f, 0x0b0a12, 0x6f6a8f, 0xc9c4ec, 0x3a0630, 0x8a0e70, 0x2ee6ff, 0xff2bd6,
               0xff9aec, 0xfff0fb, 0xffffff, 0x120b22, 0x1f1636, 0x2ee6ff, 0x0a5cff, 0x3d2e66 }
local function setPal(i, rgb) for _, m in ipairs(mons) do m.setPaletteColour(2 ^ i, rgb) end end
for i = 0, 15 do setPal(i, BASE[i]) end
local function mix(a, b, t)
  local r = math.floor(bit32.rshift(a, 16) + (bit32.rshift(b, 16) - bit32.rshift(a, 16)) * t + 0.5)
  local g = math.floor(bit32.band(bit32.rshift(a, 8), 255) + (bit32.band(bit32.rshift(b, 8), 255) - bit32.band(bit32.rshift(a, 8), 255)) * t + 0.5)
  local bl = math.floor(bit32.band(a, 255) + (bit32.band(b, 255) - bit32.band(a, 255)) * t + 0.5)
  return r * 65536 + g * 256 + bl
end
local function tint(stops, t)
  local n = #stops - 1
  local k = math.min(n - 1, math.floor(t * n))
  return mix(stops[k + 1], stops[k + 2], t * n - k)
end
local TINTS = {
  [IRIS]  = { 0x2ee6ff, 0x9a5cff, 0xff2244 }, [IRIS2] = { 0x0a5cff, 0x4a1a9a, 0x7a0016 },
  [RAIL]  = { 0x2ee6ff, 0xc23bff, 0xff2244 }, [CORE2] = { 0xff2bd6, 0xff2b9a, 0xff3b1f },
  [CORE3] = { 0xff9aec, 0xff8ac0, 0xffb070 }, [CORE1] = { 0x8a0e70, 0x8a0e50, 0x8a1a08 },
}
local lastTint = -1
local function retint(t)
  local q = math.floor(t * 24 + 0.5)          -- only re-send the palette when it visibly changes
  if q == lastTint then return end
  lastTint = q
  for i, stops in pairs(TINTS) do setPal(i, tint(stops, q / 24)) end
end

-- strip buffer (palette indices) + background (the rail)
local px = {}
local RY = math.floor(PH / 2)
local function bgAt(x, y)
  if y == RY or ((y == RY - 1 or y == RY + 1) and x % 10 == 0) then return RAIL end
  return BG
end
for y = 0, PH - 1 do for x = 0, STRIP - 1 do px[y * STRIP + x + 1] = bgAt(x, y) end end

-- precomputed geometry around the eye centre: distance, angle, hex distance
local R = math.floor(PH * 0.47)
local HALF = math.ceil(R * 1.3) + math.ceil(R * 0.25) + 3
local SW = HALF * 2 + 1
local rT, aT, hT = {}, {}, {}
local cosH, sinH = {}, {}
for k = 0, 5 do cosH[k] = math.cos(k * math.pi / 3 + 0.26); sinH[k] = math.sin(k * math.pi / 3 + 0.26) end
for dy = -HALF, HALF do
  for dx = -HALF, HALF do
    local i = (dy + HALF) * SW + dx + HALF + 1
    rT[i] = math.sqrt(dx * dx + dy * dy)
    aT[i] = math.atan2(dy, dx)
    local h = 0
    for k = 0, 5 do local v = dx * cosH[k] + dy * sinH[k]; if v > h then h = v end end
    hT[i] = h
  end
end
local PI, floor, abs = math.pi, math.floor, math.abs
local R88, R78, R56, R62 = R * 0.88, R * 0.78, R * 0.56, R * 0.62
local GLINT = math.max(1, R * 0.06)

-- colour of one pixel of the eye, or nil for background
local E = {}   -- current eye parameters
local function eyeColor(dx, dy)
  local i = (dy + HALF) * SW + dx + HALF + 1
  local r = rT[i]
  if E.lockR > 0 and abs(r - E.lockR) < 0.9 and ((aT[i] / (PI / 2) + 0.125) % 1) < 0.7 then return HI end
  if r > R then return nil end
  local ady = abs(dy)
  if ady > E.shut then return abs(ady - E.shut) < 1.2 and MET2 or BLADE end
  if r > R88 then return abs((aT[i] / (PI / 6)) % 1 - 0.5) < 0.1 and MET2 or MET end
  if r > R78 then return GAPC end
  local j = i - E.oy * SW - E.ox
  local q = rT[j]
  if q > R56 then
    if E.beat and q < R62 then return RAIL end
    return (floor((aT[j] + PI) / (PI / 4) + E.spin) % 2 == 1) and IRIS or IRIS2
  end
  local a = E.ap
  if hT[j] > a then return (((aT[j] + q * 0.06) / (PI / 3)) % 1) < 0.1 and BLADE2 or BLADE end
  local g = floor(a * 0.5)
  if rT[j + g * SW + g] < GLINT then return HI end
  local t = q / math.max(a, 1)
  if t < 0.16 then return HI elseif t < 0.32 then return CORE4 elseif t < 0.5 then return CORE3
  elseif t < 0.7 then return CORE2 elseif t < 0.86 then return CORE1 end
  return CORE0
end

-- strip x (pixels) for a position along the strip in blocks
local function blocksToPx(wb)
  local i = floor(wb / SEG); local l = wb - i * SEG
  return i * (PW + GAP) + math.min(l, MW) * BPX + math.max(0, l - MW) * GAP
end

-- send the cells covering strip columns [x0, x1] (absolute, may wrap) to the screens
local function flushCols(x0, x1)
  for s = 0, 3 do
    local mStart = s * (PW + GAP)
    for _, off in ipairs({ 0, STRIP, -STRIP }) do
      local a, b = math.max(x0 + off, mStart), math.min(x1 + off, mStart + PW - 1)
      if a <= b then
        local c0, c1 = floor((a - mStart) / 2), floor((b - mStart) / 2)
        local m = mons[s + 1]
        for cy = 0, CH - 1 do
          local tch, tfg, tbg = {}, {}, {}
          local r0 = cy * 3 * STRIP + mStart + 1
          for cx = c0, c1 do
            local base = r0 + cx * 2
            local p1, p2 = px[base], px[base + 1]
            local p3, p4 = px[base + STRIP], px[base + STRIP + 1]
            local p5, p6 = px[base + 2 * STRIP], px[base + 2 * STRIP + 1]
            local bgc, fg, n = p6, p6, 0
            -- most common non-background colour becomes the foreground
            local best, cnt = 0, nil
            for _, v in ipairs({ p1, p2, p3, p4, p5 }) do
              if v ~= bgc then
                cnt = cnt or {}
                cnt[v] = (cnt[v] or 0) + 1
                if cnt[v] > best then best, fg = cnt[v], v end
              end
            end
            if p1 ~= bgc then n = n + 1 end
            if p2 ~= bgc then n = n + 2 end
            if p3 ~= bgc then n = n + 4 end
            if p4 ~= bgc then n = n + 8 end
            if p5 ~= bgc then n = n + 16 end
            local k = cx - c0 + 1
            tch[k] = string.char(128 + n); tfg[k] = HC[fg]; tbg[k] = HC[bgc]
          end
          m.setCursorPos(c0 + 1, cy + 1)
          m.blit(table.concat(tch), table.concat(tfg), table.concat(tbg))
        end
      end
    end
  end
end

local prev = nil   -- {x0, x1} last drawn columns
local function drawEye()
  local cx = floor(blocksToPx(E.w) + 0.5)
  local cy = floor(PH / 2 - E.ay * PH * 0.05 + 0.5)
  local reach = (E.lockR > 0) and math.ceil(R * 1.3) + 1 or R + 1
  local nx0, nx1 = cx - reach, cx + reach
  local x0, x1 = nx0, nx1
  if prev then
    -- redraw the old area too (wipes the eye where it was); pick the short way round the strip
    local p0, p1 = prev[1], prev[2]
    local shift = 0
    if p0 - nx0 > STRIP / 2 then shift = -STRIP elseif nx0 - p0 > STRIP / 2 then shift = STRIP end
    p0, p1 = p0 + shift, p1 + shift
    if p0 <= nx1 + 4 and p1 >= nx0 - 4 then x0, x1 = math.min(p0, nx0), math.max(p1, nx1)
    else
      for x = p0, p1 do local xx = x % STRIP; for y = 0, PH - 1 do px[y * STRIP + xx + 1] = bgAt(xx, y) end end
      flushCols(p0, p1)
    end
  end
  x0, x1 = x0 - (x0 % 2), x1 + (1 - x1 % 2)    -- whole cells
  for x = x0, x1 do
    local xx = x % STRIP
    local dx = x - cx
    for y = 0, PH - 1 do
      local c
      local dy = y - cy
      if dx >= -reach and dx <= reach and dy >= -HALF and dy <= HALF then c = eyeColor(dx, dy) end
      px[y * STRIP + xx + 1] = c or bgAt(xx, y)
    end
  end
  flushCols(x0, x1)
  prev = { nx0, nx1 }
end

------------------------------- state -----------------------------------------
local S = {
  t = 0, target = nil, d = 999, locked = false, lockAt = -10, angryUntil = -10,
  interest = 0, w = 3.5, ax = 0, ay = 0, jx = 0, jy = 0, sacAt = 0, blinkAt = 3, blinkUntil = 0,
  open = 0.5, ap = 0.35, spin = 0, flash = false, lockRing = -1,
  levels = {}, lastLevelAt = -10, level = 0, avg = 0.2, lastBeat = -1, beatUntil = -10,
}
local function now() return os.clock() end
local function state()
  if S.t < S.angryUntil then return "angry" end
  if not S.target or S.d > WAKE then return "sleep" end
  return S.locked and "locked" or "tracking"
end

local FACEV = {   -- normal and viewer-right for north, west, south, east
  { 0, -1, -1, 0 }, { -1, 0, 0, 1 }, { 0, 1, 1, 0 }, { 1, 0, 0, -1 },
}
local function logic()
  S.t = now()
  -- music
  local ms = os.epoch("utc")
  local lv = 0
  for i = #S.levels, 1, -1 do
    local L = S.levels[i]
    local k = floor((ms - L.t0) / L.dt) + 1
    if k > #L.v then table.remove(S.levels, i) elseif k >= 1 then lv = L.v[k] end
  end
  S.level = lv
  local music = S.t - S.lastLevelAt < 2.5
  S.avg = S.avg * 0.9 + lv * 0.1
  if music and lv > S.avg * 1.45 and lv > 0.35 and S.t - S.lastBeat > 0.3 then S.lastBeat = S.t; S.beatUntil = S.t + 0.15 end

  if S.target then
    if not S.locked and S.d <= LOCK then S.locked = true; S.lockAt = S.t end
    if S.locked and S.d > UNLOCK then S.locked = false end
  else S.locked = false end
  local st = state()
  local near = S.target and S.d <= SHOW

  local want = st == "sleep" and 0 or ((S.locked or st == "angry") and 1 or math.max(0, math.min(1, (WAKE - S.d) / (WAKE - LOCK))))
  S.interest = S.interest + (want - S.interest) * 0.25
  local I = S.interest

  -- where should it be on the strip?
  local targetW = S.w
  local LOOP = SEG * 4
  if S.target then
    local fx, fz = S.target.x - CX, S.target.z - CZ
    local len = math.sqrt(fx * fx + fz * fz)
    if len > 0.5 then
      fx, fz = fx / len, fz / len
      local bi, bd = 1, -2
      for i, F in ipairs(FACEV) do local d = fx * F[1] + fz * F[2]; if d > bd then bd, bi = d, i end end
      local F = FACEV[bi]
      local th = math.atan2(fx * F[3] + fz * F[4], fx * F[1] + fz * F[2])
      local L = math.max(-4.5, math.min(4.5, 4.5 * math.tan(th)))
      targetW = (bi - 1) * SEG + L + MW / 2
    end
  end
  if st == "tracking" and S.t > S.sacAt then
    local amp = (1 - I) * 0.5
    S.jx = (math.random() * 2 - 1) * amp; S.jy = (math.random() * 2 - 1) * amp * 0.8
    S.sacAt = S.t + 0.35 + math.random() * (0.4 + I * 0.8)
  end
  if st ~= "tracking" then S.jx, S.jy = 0, 0 end
  if st == "sleep" then targetW = S.w + 0.16 else targetW = targetW + S.jx * 1.8 end
  local dw = ((targetW - S.w) % LOOP + LOOP * 1.5) % LOOP - LOOP / 2
  local follow = (st == "sleep" or st == "locked") and 1 or (st == "angry" and 0.8 or 0.12 + 0.55 * I)
  S.w = ((S.w + dw * follow) % LOOP + LOOP) % LOOP
  local lead = st == "locked" and 0 or math.max(-1, math.min(1, dw * 0.45 + S.jx))
  S.ax = S.ax + (lead - S.ax) * 0.5
  local ay = -0.3
  if S.target and st ~= "sleep" then
    local ey = S.target.y + 1.62 - CY
    local hz = math.sqrt((S.target.x - CX) ^ 2 + (S.target.z - CZ) ^ 2)
    ay = math.max(-1, math.min(1, math.atan2(ey, hz) / (PI / 2) * 1.8 + S.jy))
  end
  S.ay = S.ay + (ay - S.ay) * (st == "locked" and 0.9 or 0.4)
  -- blinks (only while calm), aperture, lock-on effects
  if S.t > S.blinkAt then
    S.blinkUntil = (st == "tracking" and I < 0.6) and S.t + 0.18 or 0
    S.blinkAt = S.t + 3 + math.random() * 5
  end
  local wantOpen = st == "sleep" and 0.42 or (S.t < S.blinkUntil and 0.04 or 1)
  S.open = S.open + (wantOpen - S.open) * 0.6
  local since = S.t - S.lockAt
  local wantAp
  if st == "angry" then wantAp = 0.14
  elseif st == "sleep" then wantAp = 0.3
  elseif st == "locked" then wantAp = 0.2 + 0.04 * math.sin(S.t * 6) + ((near and music) and 0.12 * lv or 0)
  else wantAp = 0.95 - 0.6 * I end
  S.ap = S.ap + (wantAp - S.ap) * ((st == "locked" and since < 0.5) and 0.9 or 0.35)
  S.lockRing = (st == "locked" and since < 0.6) and since / 0.6 or -1
  S.flash = st == "locked" and since < 0.25
  S.spin = S.spin + (st == "sleep" and 0.02 or 0.05 + I * 0.25)
  S.beat = music and near and S.t < S.beatUntil

  -- crown lamps on the relay: radar spin, solid when locked, flash on the beat
  if relay then
    local out = { front = false, right = false, back = false, left = false }
    local seq = { "front", "right", "back", "left" }
    if st == "locked" or st == "angry" then
      local on = st == "locked" or (floor(S.t * 8) % 2 == 0)
      for k in pairs(out) do out[k] = on end
    else
      local period = st == "sleep" and 0.6 or (0.5 - 0.42 * I)
      out[seq[floor(S.t / period) % 4 + 1]] = true
    end
    if S.beat then for k in pairs(out) do out[k] = true end end
    out.top = (S.t % 2) < 0.35           -- beacon blink
    S.relayOut = S.relayOut or {}
    for side, v in pairs(out) do
      if S.relayOut[side] ~= v then pcall(relay.setOutput, side, v); S.relayOut[side] = v end
    end
  end
end

local function render()
  local st = state()
  retint(st == "angry" and 1 or S.interest)
  E.w = S.w + (st == "angry" and math.sin(S.t * 55) * 0.09 or 0)
  E.ay, E.spin, E.beat = S.ay, S.spin, S.beat
  E.ox = floor(S.ax * R * 0.22 + 0.5); E.oy = floor(-S.ay * R * 0.22 + 0.5)
  E.ap = R * 0.52 * S.ap
  E.shut = R * math.max(0, math.min(1, S.open))
  E.lockR = S.lockRing >= 0 and R * (1.25 - S.lockRing * 0.75) or -1
  E.flash = S.flash
  drawEye()
end

------------------------------- loops -----------------------------------------
local function senseLoop()
  while true do
    local best, bd
    for _, p in ipairs(players(WAKE * 1.5)) do
      local dx, dy, dz = p.x - CX, (p.y + 1.62 - CY) * VERTICAL_WEIGHT, p.z - CZ
      local d = math.sqrt(dx * dx + dy * dy + dz * dz)
      if not bd or d < bd then best, bd = p, d end
    end
    S.target, S.d = best, bd or 999
    sleep(0.2)
  end
end
local function logicLoop() while true do logic(); sleep(0.1) end end
local function renderLoop() while true do render(); sleep(1 / FPS) end end
local function eventLoop()
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "monitor_touch" then
      for i, f in ipairs(ORDER) do
        if cfg.faces[f] == a then S.angryUntil = now() + 3.5; S.w = (i - 1) * SEG + MW / 2 end
      end
    elseif e == "rednet_message" and c == PROTOCOL and type(b) == "table" and b.kind == "levels" and type(b.v) == "table" then
      S.levels[#S.levels + 1] = { t0 = b.t0, dt = b.dt or 100, v = b.v }
      S.lastLevelAt = now()
      while #S.levels > 6 do table.remove(S.levels, 1) end
    end
  end
end

-- first full paint
for s = 1, 4 do mons[s].setBackgroundColour(colors.black); mons[s].clear() end
flushCols(0, STRIP - 1)
term.clear(); term.setCursorPos(1, 1)
print("The Watcher is awake.")
print(("Screens %dx%d at scale %s, %d fps"):format(CW, CH, tostring(TEXT_SCALE), FPS))
print(relay and "Crown relay: ok" or "Crown relay: not found (lamps off)")
print(ender and "Ender Modem: ok (listening for the radio)" or "Ender Modem: missing (no music)")
print("Tap a screen to make it angry. Hold Ctrl+T to stop.")

local ok, err = pcall(parallel.waitForAny, senseLoop, logicLoop, renderLoop, eventLoop)

for _, m in ipairs(mons) do
  for i = 0, 15 do m.setPaletteColour(2 ^ i, term.nativePaletteColour(2 ^ i)) end
  m.setBackgroundColour(colors.black); m.clear()
end
if relay then for _, side in ipairs({ "front", "right", "back", "left", "top" }) do pcall(relay.setOutput, side, false) end end
if not ok and err ~= "Terminated" then printError(err) end
print("The Watcher sleeps.")
