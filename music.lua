-- music: plays a playlist on every connected speaker
local dfpwm = require("cc.audio.dfpwm")

local playlist = {
  "https://raw.githubusercontent.com/mentozombie/Music-MC/main/50%20Cent%20Many%20Men%20(Dirty)%20HD.dfpwm",
}
local VOLUME = 3     -- 0.1 to 3 (higher = reaches farther)
local LOOP = true

local speakers = { peripheral.find("speaker") }
if #speakers == 0 then error("No speakers found - right-click the modems!") end
print("Found " .. #speakers .. " speakers")

local function play(url)
  print("Playing: " .. url)
  local h, err = http.get(url, nil, true)
  if not h then print("Failed: " .. tostring(err)) return end
  local decoder = dfpwm.make_decoder()
  while true do
    local chunk = h.read(16 * 1024)
    if not chunk then break end
    local buf = decoder(chunk)
    local jobs = {}
    for _, s in ipairs(speakers) do
      jobs[#jobs + 1] = function()
        while not s.playAudio(buf, VOLUME) do os.pullEvent("speaker_audio_empty") end
      end
    end
    parallel.waitForAll(table.unpack(jobs))
  end
  h.close()
end

repeat
  for _, url in ipairs(playlist) do play(url) end
until not LOOP
