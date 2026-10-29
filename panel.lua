-- Tower Radio v1: music panel for a 3x2 Advanced Monitor + speakers on a wired network.
-- Songs come straight from your GitHub repo: "Artist - Song.dfpwm" (+ optional "Artist - Song.art").
-- Run:  panel        Stop: hold Ctrl+T

---------------------------------- settings ----------------------------------
local REPO        = "mentozombie/Music-MC"  -- GitHub user/repo holding the songs
local BRANCH      = "main"
local RANGE       = 3      -- how far the speakers reach, 0.1 to 3 (3 is about 48 blocks)
local START_VOL   = 8      -- starting volume, 0 to 10
local AUTOPLAY    = true   -- start the first song when the program starts
local SAVER_AFTER = 60     -- seconds stopped before the screensaver comes on
local MONITOR     = nil    -- e.g. "monitor_0"; nil uses the first monitor found
-------------------------------------------------------------------------------

local dfpwm = require("cc.audio.dfpwm")
local BPS, CHUNK = 6000, 6000   -- DFPWM is 6000 bytes per second; we send 1 second at a time

local mon = MONITOR and peripheral.wrap(MONITOR) or peripheral.find("monitor")
if not mon then error("No monitor found. Right-click the monitor's modem so it turns red.", 0) end
if not mon.isColour() then error("This needs an Advanced (gold) monitor.", 0) end
local monName = peripheral.getName(mon)
local speakers = { peripheral.find("speaker") }
if #speakers == 0 then error("No speakers found. Right-click the speaker modems so they turn red.", 0) end
mon.setTextScale(0.5)
local W, H = mon.getSize()
if W < 57 or H < 24 then
  error(("The monitor is %dx%d characters. The panel needs a 3 wide x 2 tall Advanced Monitor."):format(W, H), 0)
end

-- colors: 7 UI slots in tower gold, the other 9 belong to the album art
local K = { bg = "f", panel = "7", dim = "8", text = "0", gold = "5", hot = "1", stop = "e" }
local GOLD = { f = 0x100c05, ["7"] = 0x36290f, ["8"] = 0xa8936a, ["0"] = 0xfff3d6,
               ["5"] = 0xffb300, ["1"] = 0xff7a1a, e = 0xd9452b }
local ART_SLOT = { ["2"] = true, ["3"] = true, ["4"] = true, ["6"] = true, ["9"] = true,
                   a = true, b = true, c = true, d = true }
local function colorOf(ch) return 2 ^ tonumber(ch, 16) end

local S = {
  tracks = {}, idx = 1, pos = 0, playing = false, vol = START_VOL, shuffle = false, rep = "ALL",
  scroll = 0, hist = {}, levels = {}, saver = false, stoppedAt = os.clock(), syncing = false,
  note = nil, cmd = nil, flash = nil, fadeIn = 0, artShown = nil,
}
local LW, RX = 23, 25
local RW, IX = W - RX + 1, RX + 17
local IW = W - IX + 1
local VIS = math.floor((H - 6) / 2)

local function note(t, c) S.note = { t = t, c = c, untilT = os.clock() + 5 } end
-- the byte position you can actually hear: counted by time since the speakers started,
-- never ahead of what has been sent to them
local function heard()
  if S.playing and S.playStart then
    return math.max(S.playFrom, math.min(S.pos, S.playFrom + (os.clock() - S.playStart) * BPS))
  end
  return S.pos
end
local function timeNow() return heard() / BPS end
local function ensureVisible()
  if S.idx - 1 < S.scroll then S.scroll = S.idx - 1 end
  if S.idx - 1 >= S.scroll + VIS then S.scroll = S.idx - VIS end
end
local function pickNext(auto)
  local n = #S.tracks
  if n == 0 then return nil end
  if auto and S.rep == "ONE" then return S.idx end
  if S.shuffle and n > 1 then
    local i
    repeat i = math.random(n) until i ~= S.idx
    return i
  end
  local i = S.idx + 1
  if i > n then
    if auto and S.rep == "OFF" then return nil end
    i = 1
  end
  return i
end

------------------------------- GitHub sync -------------------------------
local function httpText(url)
  local h = http.get(url, { ["User-Agent"] = "TowerRadio" })
  if not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function parseArt(txt)
  local lines = {}
  for line in txt:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
  if not lines[1] or not lines[1]:match("^ART1") then return nil end
  local art = { pal = {}, rows = {} }
  for i = 2, #lines do
    local k, hex = lines[i]:match("^(%x) #(%x%x%x%x%x%x)%s*$")
    if k then
      if ART_SLOT[k] then art.pal[k] = tonumber(hex, 16) end
    else
      local t, f, b = lines[i]:match("^(%w+) (%x+) (%x+)%s*$")
      if t and #t == 16 and #f == 16 and #b == 16 then
        local chars = {}
        for j = 1, 16 do chars[j] = string.char(128 + (tonumber(t:sub(j, j), 32) or 0)) end
        art.rows[#art.rows + 1] = { t = table.concat(chars), f = f, b = b }
      end
    end
  end
  if #art.rows ~= 10 then return nil end
  return art
end

local function splitName(file)
  local a, t = file:match("^(.-) %- (.+)$")
  if a then return a, t end
  return "Unknown artist", file
end

local function sync()
  S.syncing = true
  os.queueEvent("radio_redraw")
  local body = httpText(("https://api.github.com/repos/%s/contents/?ref=%s"):format(REPO, BRANCH))
  local list = body and textutils.unserialiseJSON(body)
  if type(list) ~= "table" or list.message then
    S.syncing = false
    note("NO SYNC ", K.stop)
    return false
  end
  local arts, tracks = {}, {}
  for _, f in ipairs(list) do
    local base = f.type == "file" and f.name:match("^(.*)%.art$")
    if base then arts[base] = f.download_url end
  end
  for _, f in ipairs(list) do
    local base = f.type == "file" and f.name:match("^(.*)%.dfpwm$")
    if base and f.download_url and (f.size or 0) > 0 then
      local artist, title = splitName(base)
      local tr = { file = base, artist = artist, title = title, size = f.size,
                   dur = f.size / BPS, url = f.download_url }
      if arts[base] then
        local txt = httpText(arts[base])
        tr.art = txt and parseArt(txt)
      end
      tracks[#tracks + 1] = tr
    end
  end
  local cur = S.tracks[S.idx] and S.tracks[S.idx].file
  S.tracks, S.idx, S.artShown = tracks, 1, nil
  for i, tr in ipairs(tracks) do if tr.file == cur then S.idx = i end end
  S.syncing = false
  return true
end

---------------------------------- audio ----------------------------------
local function send(cmd) S.cmd = cmd; os.queueEvent("radio_cmd") end

-- volume, fade in (1 s) and fade out (last 1.5 s), plus loudness for the visualizer
local function shape(buf, pos, size)
  local vol, fi, remS = S.vol / 10, S.fadeIn, (size - pos) * 8
  local sum, cnt, lv = 0, 0, S.levels
  for k = 1, #buf do
    local g = vol
    local a = (fi + k) / 48000
    if a < 1 then g = g * a end
    local b = (remS - k) / 72000
    if b < 1 then g = g * math.max(0, b) end
    local v = math.floor(buf[k] * g + 0.5)
    if v > 127 then v = 127 elseif v < -128 then v = -128 end
    buf[k] = v
    sum, cnt = sum + math.abs(v), cnt + 1
    if cnt == 4800 then lv[#lv + 1] = math.min(1, sum / cnt / 128 * 3.2); sum, cnt = 0, 0 end
  end
  if cnt > 0 then lv[#lv + 1] = math.min(1, sum / cnt / 128 * 3.2) end
  while #lv > 40 do table.remove(lv, 1) end
  S.fadeIn = fi + #buf
end

local function audio()
  local h, dec, track, pos = nil, nil, nil, 0
  local function closeH() if h then h.close(); h = nil end end
  local function hush() for _, s in ipairs(speakers) do s.stop() end end
  while true do
    local cmd = S.cmd
    if cmd then
      S.cmd = nil
      local delay = 0
      if cmd.auto then
        delay = math.max(0, (S.pos - heard()) / BPS)   -- old song still finishing in the speakers
      else
        closeH(); hush(); S.levels = {}
      end
      if cmd.kind == "play" and S.tracks[cmd.idx] then
        track = S.tracks[cmd.idx]
        S.idx = cmd.idx
        ensureVisible()
        pos = math.max(0, math.min(cmd.offset or 0, track.size - 1))
        S.pos, S.playing, S.stoppedAt, S.fadeIn = pos, true, nil, 0
        S.playFrom, S.playStart, S.startDelay = pos, nil, delay
        local res = http.get({ url = track.url, headers = { Range = "bytes=" .. pos .. "-" }, binary = true })
        if S.cmd then
          if res then res.close() end          -- something else was pressed while loading
        elseif not res then
          S.playing, S.stoppedAt = false, os.clock()
          note("LOAD ERR", K.stop)
        else
          h, dec = res, dfpwm.make_decoder()
        end
      elseif cmd.kind == "pause" then
        pos = math.floor(heard())               -- resume from what you actually heard
        S.playing, S.pos = false, pos
      elseif cmd.kind == "stop" then
        S.playing, pos, S.pos, S.stoppedAt = false, 0, 0, os.clock()
      end
    elseif S.playing and h then
      local chunk = h.read(CHUNK)
      if not chunk then
        closeH()
        local ni = pickNext(true)
        if ni then
          S.cmd = { kind = "play", idx = ni, offset = 0, auto = true }
        else
          S.playing, pos, S.pos, S.idx, S.stoppedAt = false, 0, 0, 1, os.clock()
          ensureVisible()
        end
      else
        local buf = dec(chunk)
        shape(buf, pos, track.size)
        local pending = {}
        for i, s in ipairs(speakers) do pending[i] = s end
        while next(pending) and not S.cmd do
          for i, s in pairs(pending) do
            if s.playAudio(buf, RANGE) then
              pending[i] = nil
              if not S.playStart then S.playStart = os.clock() + (S.startDelay or 0) end
            end
          end
          if next(pending) then os.pullEvent() end
        end
        if not S.cmd then pos = pos + #chunk; S.pos = pos end
      end
    else
      os.pullEvent("radio_cmd")
    end
  end
end

---------------------------------- drawing ----------------------------------
local bc, bf, bb, hits = {}, {}, {}, {}
for y = 1, H do bc[y], bf[y], bb[y] = {}, {}, {} end

local function clear(bg)
  for y = 1, H do
    local c, f, b = bc[y], bf[y], bb[y]
    for x = 1, W do c[x], f[x], b[x] = " ", "0", bg end
  end
  hits = {}
end
local function set(x, y, ch, fg, bg)
  if x < 1 or y < 1 or x > W or y > H then return end
  bc[y][x], bf[y][x], bb[y][x] = ch, fg, bg
end
local function fill(x, y, w, h, bg)
  for j = 0, h - 1 do for i = 0, w - 1 do set(x + i, y + j, " ", "0", bg) end end
end
local function text(x, y, s, fg, bg)
  for i = 1, #s do set(x + i - 1, y, s:sub(i, i), fg, bg) end
end
local function center(y, s, fg, bg) text(math.floor((W - #s) / 2) + 1, y, s, fg, bg) end
local function flush()
  for y = 1, H do
    mon.setCursorPos(1, y)
    mon.blit(table.concat(bc[y]), table.concat(bf[y]), table.concat(bb[y]))
  end
end

local function fmt(s)
  s = math.max(0, math.floor(s))
  return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end
local function trunc(s, w)
  if #s <= w then return s end
  if w <= 1 then return s:sub(1, w) end
  return s:sub(1, w - 1) .. "."
end
local function wrap(s, w)
  local out, line = {}, ""
  for word in s:gmatch("%S+") do
    local cand = line == "" and word or (line .. " " .. word)
    if #cand <= w then line = cand
    else
      if line ~= "" then out[#out + 1] = line end
      line = #word > w and word:sub(1, w) or word
    end
  end
  if line ~= "" then out[#out + 1] = line end
  return out
end
local function button(x, y, w, h, label, fg, bg, action, meta)
  if S.flash and S.flash.a == action and os.clock() < S.flash.t then fg, bg = K.bg, K.text end
  fill(x, y, w, h, bg)
  text(x + math.floor((w - #label) / 2), y + math.floor(h / 2), label, fg, bg)
  hits[#hits + 1] = { x = x, y = y, w = w, h = h, a = action, m = meta }
end

-- 2x3 mini-pixels -> CC drawing characters (128 + bits; bottom-right pixel is the background)
local function blitPixels(x0, y0, w, h, px, pw)
  for cy = 0, h - 1 do
    for cx = 0, w - 1 do
      local r, c = cy * 3, cx * 2
      local p = { px[r * pw + c + 1], px[r * pw + c + 2], px[(r + 1) * pw + c + 1],
                  px[(r + 1) * pw + c + 2], px[(r + 2) * pw + c + 1], px[(r + 2) * pw + c + 2] }
      local bg = p[6]
      local cnt, fg, best, n = {}, bg, 0, 0
      for i = 1, 5 do
        if p[i] ~= bg then
          n = n + 2 ^ (i - 1)
          cnt[p[i]] = (cnt[p[i]] or 0) + 1
          if cnt[p[i]] > best then best, fg = cnt[p[i]], p[i] end
        end
      end
      set(x0 + cx, y0 + cy, string.char(128 + n), fg, bg)
    end
  end
end

local function strHash(s)
  local h = 7
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 4294967296 end
  return h
end
local pxCache = {}
local function placeholderPx(tr)
  if pxCache[tr.file] then return pxCache[tr.file] end
  local seed = strHash(tr.file)
  local f1, f2 = 3 + seed % 5, 2 + math.floor(seed / 16) % 4
  local ang = (seed % 360) * math.pi / 180
  local ca, sa = math.cos(ang), math.sin(ang)
  local px = {}
  for yy = 0, 29 do
    for xx = 0, 31 do
      local u, v = xx / 32 - 0.5, (yy / 30 - 0.5) * 0.94
      local r = math.sqrt(u * u + v * v)
      local val = (math.sin(r * f1 * 9 + math.sin((u * ca + v * sa) * f2 * 6) * 1.8) + 1) / 2
      px[yy * 32 + xx + 1] = val < 0.28 and K.bg or val < 0.55 and K.panel or val < 0.84 and K.gold or K.hot
    end
  end
  pxCache[tr.file] = px
  return px
end

local function header()
  fill(1, 1, W, 1, K.panel)
  text(1, 1, " \14 TOWER RADIO", K.gold, K.panel)
  button(W - 16, 1, 6, 1, "SYNC", K.bg, K.dim, "sync")
  local st, c, dot = nil, K.text, false
  if S.syncing then st, c = "SYNCING ", K.hot
  elseif S.note and os.clock() < S.note.untilT then st, c = S.note.t, S.note.c
  elseif S.playing then st, dot = " ON AIR ", true
  else st, c = (S.pos > 0 and "PAUSED " or "STOPPED "), K.dim end
  text(W - #st + 1, 1, st, c, K.panel)
  if dot then text(W - #st, 1, "\7", K.stop, K.panel) end
end

local function playlist()
  local n = #S.tracks
  fill(1, 2, LW, H - 1, K.panel)
  text(2, 3, "PLAYLIST", K.dim, K.panel)
  local cnt = n .. (n == 1 and " song" or " songs")
  text(LW - #cnt, 3, cnt, K.dim, K.panel)
  S.scroll = math.max(0, math.min(S.scroll, math.max(0, n - VIS)))
  for k = 0, VIS - 1 do
    local i = S.scroll + k + 1
    if i > n then break end
    local y, tr, cur = 5 + k * 2, S.tracks[i], i == S.idx
    local b = cur and K.gold or K.panel
    fill(1, y, LW, 2, b)
    local mark = cur and (S.playing and " \16" or "\149\149") or ("%2d"):format(i)
    text(2, y, mark, cur and K.bg or K.dim, b)
    text(5, y, trunc(tr.title, LW - 5), cur and K.bg or K.text, b)
    text(5, y + 1, trunc(tr.artist, LW - 5), cur and K.panel or K.dim, b)
    hits[#hits + 1] = { x = 1, y = y, w = LW, h = 2, a = "play", m = i }
  end
  if n > VIS then
    button(2, H, 3, 1, "\30", K.text, K.bg, "up")
    button(6, H, 3, 1, "\31", K.text, K.bg, "down")
    text(10, H, ("%d-%d of %d"):format(S.scroll + 1, math.min(n, S.scroll + VIS), n), K.dim, K.panel)
  end
end

local function drawArt(tr, x, y)
  if tr.art then
    for j, r in ipairs(tr.art.rows) do
      for i = 1, 16 do set(x + i - 1, y + j - 1, r.t:sub(i, i), r.f:sub(i, i), r.b:sub(i, i)) end
    end
  else
    blitPixels(x, y, 16, 10, placeholderPx(tr), 32)
  end
end

local function nowPlaying(tr)
  text(IX, 3, "NOW PLAYING", K.dim, K.bg)
  local y = 5
  for i, l in ipairs(wrap(tr.artist, IW)) do
    if i > 2 then break end
    text(IX, y, l, K.gold, K.bg); y = y + 1
  end
  for i, l in ipairs(wrap(tr.title, IW)) do
    if i > 3 then break end
    text(IX, y, l, K.text, K.bg); y = y + 1
  end
  if y <= 10 then text(IX, 10, ("Song %d of %d"):format(S.idx, #S.tracks), K.dim, K.bg) end
  button(IX, 12, 6, 1, "SHUF", S.shuffle and K.bg or K.dim, S.shuffle and K.gold or K.panel, "shuffle")
  local on = S.rep ~= "OFF"
  button(IX + 7, 12, 9, 1, "RPT " .. S.rep, on and K.bg or K.dim, on and K.gold or K.panel, "repeat")
end

local function progress(tr, x, y, w)
  local d, t = tr.dur, timeNow()
  local t1, t2 = fmt(t), fmt(d)
  text(x, y, t1, K.text, K.bg)
  text(x + w - #t2, y, t2, K.dim, K.bg)
  local bx, bw = x + #t1 + 1, w - #t1 - #t2 - 2
  local f = math.min(bw - 1, math.floor(bw * t / d))
  for i = 0, bw - 1 do
    set(bx + i, y, "\140", i < f and K.gold or (i == f and K.text or K.panel), K.bg)
  end
  hits[#hits + 1] = { x = bx, y = y, w = bw, h = 1, a = "seek", m = { bx = bx, bw = bw } }
end

local function buttonRow(y, h, x, w)
  local defs = {
    { "prev", "\17\17", K.text, K.panel },
    { "toggle", S.playing and "\149\149" or "\16", K.bg, K.gold },
    { "next", "\16\16", K.text, K.panel },
    { "stop", "\143", K.text, K.stop },
  }
  local gap, bw = 2, 6
  local cx = x + math.floor((w - (#defs * bw + gap * (#defs - 1))) / 2)
  for _, d in ipairs(defs) do
    button(cx, y, bw, h, d[2], d[3], d[4], d[1])
    cx = cx + bw + gap
  end
end

local function volume(x, y, w)
  local cx = x + math.floor((w - 27) / 2)
  text(cx, y, "VOL", K.dim, K.bg); cx = cx + 4
  button(cx, y, 3, 1, "-", K.text, K.panel, "voldown"); cx = cx + 4
  for i = 0, 9 do
    set(cx + i, y, " ", K.text, i < S.vol and (i >= 8 and K.hot or K.gold) or K.panel)
  end
  cx = cx + 11
  button(cx, y, 3, 1, "+", K.text, K.panel, "volup"); cx = cx + 4
  text(cx, y, (S.vol * 10) .. "%", K.dim, K.bg)
end

local function levels(x, y, w, h)
  local pw, ph, px = w * 2, h * 3, {}
  for i = 1, pw * ph do px[i] = K.bg end
  local nH = #S.hist
  for c = 0, pw - 1 do
    local v = S.hist[nH - pw + c + 1] or 0
    local bh = math.floor(v * ph + 0.5)
    for k = 0, bh - 1 do
      px[(ph - 1 - k) * pw + c + 1] = ((k + 1) / ph > 0.75) and K.hot or K.gold
    end
  end
  blitPixels(x, y, w, h, px, pw)
end

local DIG = {
  ["0"] = { "111", "101", "101", "101", "111" }, ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "111", "001", "111", "100", "111" }, ["3"] = { "111", "001", "111", "001", "111" },
  ["4"] = { "101", "101", "111", "001", "001" }, ["5"] = { "111", "100", "111", "001", "111" },
  ["6"] = { "111", "100", "111", "101", "111" }, ["7"] = { "111", "001", "010", "010", "010" },
  ["8"] = { "111", "101", "111", "101", "111" }, ["9"] = { "111", "101", "111", "001", "111" },
}
local function drawSaver()
  local hrs = os.time() % 24
  local hh = math.floor(hrs)
  local mm = math.floor((hrs - hh) * 60)
  local ampm = hh >= 12 and "PM" or "AM"
  local h12 = hh % 12
  if h12 == 0 then h12 = 12 end
  local str = ("%d:%02d"):format(h12, mm)
  local width = -2
  for c in str:gmatch(".") do width = width + (c == ":" and 2 or 6) + 2 end
  local x, y0 = math.floor((W - width - 3) / 2) + 1, 4
  local blink = math.floor(os.clock() * 2) % 2 == 0
  for c in str:gmatch(".") do
    if c == ":" then
      if blink then fill(x, y0 + 2, 2, 2, K.hot); fill(x, y0 + 6, 2, 2, K.hot) end
      x = x + 4
    else
      for r = 1, 5 do
        local bits = DIG[c][r]
        for k = 1, 3 do
          if bits:sub(k, k) == "1" then fill(x + (k - 1) * 2, y0 + (r - 1) * 2, 2, 2, K.gold) end
        end
      end
      x = x + 8
    end
  end
  text(x - 1, y0 + 8, ampm, K.dim, K.bg)
  center(16, "DAY " .. os.day(), K.text, K.bg)
  center(18, "Tap anywhere to play", K.dim, K.bg)
  local pw, ph, px, t = W * 2, 12, {}, os.clock()
  for i = 1, pw * ph do px[i] = K.bg end
  for c = 0, pw - 1 do
    local yv = math.floor(ph * 0.45 + math.sin(c * 0.16 + t * 1.4) * ph * 0.22
                          + math.sin(c * 0.05 - t * 0.6) * ph * 0.12 + 0.5)
    for r = math.max(0, yv), ph - 1 do px[r * pw + c + 1] = (r == yv) and K.gold or K.panel end
  end
  blitPixels(1, H - 3, W, 4, px, pw)
  hits[#hits + 1] = { x = 1, y = 1, w = W, h = H, a = "wake" }
end

local function applyArtPalette()
  local tr = S.tracks[S.idx]
  local key = (not S.saver and tr and tr.art) and tr.file or "none"
  if key == S.artShown then return end
  S.artShown = key
  if key ~= "none" then
    for k, rgb in pairs(tr.art.pal) do mon.setPaletteColour(colorOf(k), rgb) end
  end
end

local function draw()
  applyArtPalette()
  clear(K.bg)
  if #S.tracks == 0 then
    header()
    center(10, "No songs found", K.text, K.bg)
    center(12, "Upload .dfpwm files to " .. REPO, K.dim, K.bg)
    center(14, "then tap SYNC", K.dim, K.bg)
  elseif S.saver then
    drawSaver()
  else
    local tr = S.tracks[S.idx]
    header(); playlist(); drawArt(tr, RX, 3); nowPlaying(tr)
    progress(tr, RX, 14, RW); buttonRow(16, 3, RX, RW); volume(RX, 20, RW); levels(RX, 22, RW, 3)
  end
  flush()
end

------------------------------- touch + clock -------------------------------
local function playIdx(i, offset)
  if not i then return end
  S.idx, S.pos, S.saver, S.playing = i, offset or 0, false, true
  ensureVisible()
  send({ kind = "play", idx = i, offset = offset or 0 })
end

local function act(a, m, x)
  if a == "sync" then os.queueEvent("radio_sync"); return end
  local n, tr = #S.tracks, S.tracks[S.idx]
  if n == 0 then return end
  if a == "toggle" then
    if S.playing then send({ kind = "pause" }) else playIdx(S.idx, S.pos) end
  elseif a == "next" then playIdx(pickNext(false))
  elseif a == "prev" then
    if timeNow() > 3 then playIdx(S.idx, 0) else playIdx((S.idx - 2) % n + 1, 0) end
  elseif a == "stop" then send({ kind = "stop" })
  elseif a == "volup" then S.vol = math.min(10, S.vol + 1)
  elseif a == "voldown" then S.vol = math.max(0, S.vol - 1)
  elseif a == "shuffle" then S.shuffle = not S.shuffle
  elseif a == "repeat" then S.rep = (S.rep == "ALL" and "ONE") or (S.rep == "ONE" and "OFF") or "ALL"
  elseif a == "up" then S.scroll = math.max(0, S.scroll - 1)
  elseif a == "down" then S.scroll = S.scroll + 1
  elseif a == "play" then playIdx(m, 0)
  elseif a == "seek" then
    local f = math.max(0, math.min(1, (x - m.bx) / math.max(1, m.bw - 1)))
    playIdx(S.idx, math.floor(f * tr.size))
  elseif a == "wake" then playIdx(S.idx, S.pos)
  end
end

local function touch(x, y)
  for i = #hits, 1, -1 do
    local z = hits[i]
    if x >= z.x and x < z.x + z.w and y >= z.y and y < z.y + z.h then
      S.flash = { a = z.a, t = os.clock() + 0.2 }
      act(z.a, z.m, x)
      return
    end
  end
end

local function tick()
  for _ = 1, 2 do
    local v = 0
    if S.playing then
      if #S.levels > 5 then v = table.remove(S.levels, 1) elseif #S.levels > 0 then v = S.levels[1] end
    end
    S.hist[#S.hist + 1] = v
  end
  while #S.hist > W * 2 do table.remove(S.hist, 1) end
  if not S.playing and S.pos == 0 and S.stoppedAt and os.clock() - S.stoppedAt > SAVER_AFTER then
    S.saver = true
  end
end

local function ui()
  draw()
  local tmr = os.startTimer(0.2)
  while true do
    local e, p1, p2, p3 = os.pullEvent()
    if e == "timer" and p1 == tmr then
      tick(); draw(); tmr = os.startTimer(0.2)
    elseif e == "monitor_touch" and p1 == monName then
      touch(p2, p3); draw()
    elseif e == "radio_redraw" then
      draw()
    end
  end
end

local function syncer()
  while true do
    os.pullEvent("radio_sync")
    sync()
    ensureVisible()
    os.queueEvent("radio_redraw")
  end
end

----------------------------------- start -----------------------------------
for ch, rgb in pairs(GOLD) do mon.setPaletteColour(colorOf(ch), rgb) end
term.clear(); term.setCursorPos(1, 1)
print("Tower Radio")
print("Loading songs from github.com/" .. REPO .. " ...")
if not sync() then print("Couldn't reach GitHub. Check REPO above and that HTTP is enabled.") end
print(("%d songs, %d speakers, screen %s"):format(#S.tracks, #speakers, monName))
print("Hold Ctrl+T to stop.")
if AUTOPLAY and #S.tracks > 0 then playIdx(1, 0) end

local ok, err = pcall(parallel.waitForAny, audio, ui, syncer)

for _, s in ipairs(speakers) do s.stop() end
for i = 0, 15 do
  local c = 2 ^ i
  mon.setPaletteColour(c, term.nativePaletteColour(c))
end
mon.setBackgroundColour(colors.black)
mon.clear()
if not ok and err ~= "Terminated" then printError(err) end
print("Tower Radio stopped.")
