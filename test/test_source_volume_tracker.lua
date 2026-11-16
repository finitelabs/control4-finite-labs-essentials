-- The Source Volume tracker against room sessions: when a picked source's
-- level is sent, when the level from before is put back, and when nothing is
-- touched.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_source_volume_tracker.lua
--
-- Each step is a settled room snapshot. Changes read "set 60", "fixed 9@60",
-- "restored 35", "unsettable 9" and "missed 60".

local T = require("testlib")
local Tracker = require("source_volume.tracker")

local COMPUTER = 9
local GAME = 10
local AIRPLAY = 20
local AUDIO_AMP = 100
local VIDEO_AMP = 200

local function settings(overrides)
  local s = { enabled = true, sources = { [COMPUTER] = 60, [GAME] = 40 } }
  for k, v in pairs(overrides or {}) do
    s[k] = v
  end
  return s
end

local function room(source, volume, overrides)
  local r = {
    source = source,
    power = source ~= 0,
    volume = volume,
    volumeDevice = AUDIO_AMP,
    discrete = true,
    useDefaults = false,
  }
  for k, v in pairs(overrides or {}) do
    r[k] = v
  end
  return r
end

local function describe(change)
  if change.type == Tracker.Change.FIXED then
    return string.format("fixed %d@%d", change.source, change.level)
  elseif change.type == Tracker.Change.UNSETTABLE then
    return "unsettable " .. tostring(change.source)
  end
  return change.type .. " " .. tostring(change.level)
end

--- A session: feeds each snapshot at its second and joins every change ("" for none).
--- Each step is { at, room } or { at, room, settings }.
local function session(steps, state, base)
  state = state or Tracker.new()
  local out = {}
  for _, step in ipairs(steps) do
    for _, change in ipairs(Tracker.update(state, step[3] or base or settings(), step[2], step[1])) do
      out[#out + 1] = describe(change)
    end
  end
  return table.concat(out, "; "), state
end

T.section("the office: the computer holds 60, AirPlay gets its level back")
T.eq("AirPlay at 35, the computer, then AirPlay again", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 60) },
  { 100, room(AIRPLAY, 60) },
  { 101, room(AIRPLAY, 35) },
})), "set 60; fixed 9@60; set 35; restored 35")

local _, s = session({ { 0, room(AIRPLAY, 35) }, { 10, room(COMPUTER, 35) }, { 11, room(COMPUTER, 60) } })
T.truthy("active while the computer plays", Tracker.isActive(s))
T.eq("35 is the level to restore", Tracker.savedLevel(s, room(COMPUTER, 60)), 35)
session({ { 100, room(AIRPLAY, 60) }, { 101, room(AIRPLAY, 35) } }, s)
T.falsy("inactive after AirPlay", Tracker.isActive(s))
T.eq("nothing left to restore", Tracker.savedLevel(s, room(AIRPLAY, 35)), -1)

T.section("sources not picked are never touched")
T.eq("AirPlay to a TV and back, with volume moves", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(AIRPLAY, 50) },
  { 20, room(30, 50) },
  { 30, room(30, 22) },
  { 40, room(AIRPLAY, 22) },
})), "")

T.section("picked to picked keeps the first level to restore")
T.eq("AirPlay 35, the computer 60, the game 40, then AirPlay", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 60) },
  { 50, room(GAME, 60) },
  { 51, room(GAME, 40) },
  { 90, room(AIRPLAY, 40) },
  { 91, room(AIRPLAY, 35) },
})), "set 60; fixed 9@60; set 40; fixed 10@40; set 35; restored 35")

T.section("a level already right is not sent again")
T.eq(
  "the room was at 60 before the computer",
  (session({ { 0, room(AIRPLAY, 60) }, { 10, room(COMPUTER, 60) }, { 90, room(AIRPLAY, 60) } })),
  "fixed 9@60; restored 60"
)

T.section("a slider move during the picked source still restores the level from before")
T.eq("moved to 70 under the computer", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 60) },
  { 30, room(COMPUTER, 70) },
  { 90, room(AIRPLAY, 70) },
})), "set 60; fixed 9@60; set 35; restored 35")
T.eq("the move is not undone while the computer plays", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 60) },
  { 30, room(COMPUTER, 70) },
  { 40, room(COMPUTER, 72) },
})), "set 60; fixed 9@60")

T.section("a level set by something else at the switch wins")
T.eq("a default volume lands on AirPlay as it starts", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 60) },
  { 90, room(AIRPLAY, 25) },
})), "set 60; fixed 9@60")
local _, after = session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 60) },
  { 90, room(AIRPLAY, 25) },
})
T.eq("and nothing is left to restore", Tracker.savedLevel(after, room(AIRPLAY, 25)), -1)
T.eq(
  "the next visit saves the new level",
  (session({ { 100, room(COMPUTER, 25) }, { 101, room(COMPUTER, 60) }, { 200, room(AIRPLAY, 60) } }, after)),
  "set 60; fixed 9@60; set 25; restored 25"
)

T.section("the room turned off under the picked source")
T.eq("off, then on with AirPlay: the level from before comes back", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 60) },
  { 100, room(0, -1) },
  { 5000, room(AIRPLAY, 60) },
})), "set 60; fixed 9@60; set 35; restored 35")
T.eq("off, then on with AirPlay in a room with default volumes: left to Control4", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 60) },
  { 100, room(0, -1, { useDefaults = true }) },
  { 5000, room(AIRPLAY, 30, { useDefaults = true }) },
})), "set 60; fixed 9@60")
T.eq("off, then on with the computer again: still 60, still 35 to restore", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 60) },
  { 100, room(0, -1) },
  { 5000, room(COMPUTER, 60) },
  { 6000, room(AIRPLAY, 60) },
})), "set 60; fixed 9@60; fixed 9@60; set 35; restored 35")
local _, offState = session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 60) },
  { 100, room(0, -1, { volumeDevice = 0 }) },
})
T.eq(
  "off with no volume device: 35 is still the level to restore",
  Tracker.savedLevel(offState, room(0, -1, { volumeDevice = 0 })),
  35
)

T.section("the room turned on straight to the picked source")
T.eq("the level from the last unpicked source is saved", (session({
  { 0, room(AIRPLAY, 35) },
  { 50, room(0, -1) },
  { 5000, room(COMPUTER, 35) },
  { 5001, room(COMPUTER, 60) },
  { 6000, room(AIRPLAY, 60) },
})), "set 60; fixed 9@60; set 35; restored 35")
T.eq(
  "with no level ever seen, nothing is saved, and AirPlay is left alone",
  (session({ { 0, room(0, -1) }, { 10, room(COMPUTER, 45) }, { 11, room(COMPUTER, 60) }, { 90, room(AIRPLAY, 60) } })),
  "set 60; fixed 9@60"
)
T.eq(
  "the driver started while the computer played: its level is the level the room had",
  (session({ { 10, room(COMPUTER, 45) }, { 11, room(COMPUTER, 60) }, { 90, room(AIRPLAY, 60) } })),
  "set 60; fixed 9@60; set 45; restored 45"
)

T.section("rooms with separate audio and video volume devices")
local function video(source, volume)
  return room(source, volume, { volumeDevice = VIDEO_AMP })
end
T.eq(
  "AirPlay on the audio amp, the computer on the video amp, back to AirPlay: the audio amp was never changed",
  (
    session({
      { 0, room(AIRPLAY, 35) },
      { 5, video(30, 50) },
      { 10, video(COMPUTER, 50) },
      { 11, video(COMPUTER, 60) },
      { 90, room(AIRPLAY, 35) },
    })
  ),
  "set 60; fixed 9@60"
)
T.eq("and the video amp gets its 50 back the next time a TV source uses it", (session({
  { 0, room(AIRPLAY, 35) },
  { 5, video(30, 50) },
  { 10, video(COMPUTER, 50) },
  { 11, video(COMPUTER, 60) },
  { 90, room(AIRPLAY, 35) },
  { 200, video(30, 60) },
})), "set 60; fixed 9@60; set 50; restored 50")
local _, twoAmps = session({
  { 0, room(AIRPLAY, 35) },
  { 5, video(30, 50) },
  { 10, video(COMPUTER, 50) },
  { 11, video(COMPUTER, 60) },
  { 90, room(GAME, 35) },
  { 91, room(GAME, 40) },
  { 100, room(0, -1, { volumeDevice = 0 }) },
})
local _, audioBack = session({
  { 0, room(AIRPLAY, 35) },
  { 5, video(30, 50) },
  { 10, video(COMPUTER, 50) },
  { 11, video(COMPUTER, 60) },
  { 90, room(AIRPLAY, 35) },
})
T.eq(
  "AirPlay back on the audio amp: the video amp's 50 is not its level to restore",
  Tracker.savedLevel(audioBack, room(AIRPLAY, 35)),
  -1
)
T.eq(
  "off with no volume device and a level saved on each amp: neither is named",
  Tracker.savedLevel(twoAmps, room(0, -1, { volumeDevice = 0 })),
  -1
)

T.section("a room whose volume can't be set to a level")
T.eq("says so once, sends nothing, restores nothing", (session({
  { 0, room(AIRPLAY, 35, { discrete = false }) },
  { 10, room(COMPUTER, 35, { discrete = false }) },
  { 20, room(COMPUTER, 36, { discrete = false }) },
  { 90, room(AIRPLAY, 36, { discrete = false }) },
})), "unsettable 9")

T.section("a level that doesn't arrive")
T.eq("sent once more after 3 seconds, then reported", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 12, room(COMPUTER, 35) },
  { 13, room(COMPUTER, 35) },
  { 16, room(COMPUTER, 35) },
})), "set 60; fixed 9@60; set 60; missed 60")
T.eq("arriving late is fine", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 13, room(COMPUTER, 35) },
  { 14, room(COMPUTER, 60) },
})), "set 60; fixed 9@60; set 60")
T.eq("a slow amp doesn't count as a slider move", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 48) },
  { 12, room(COMPUTER, 60) },
  { 90, room(AIRPLAY, 60) },
})), "set 60; fixed 9@60; set 35; restored 35")
T.eq("switching back before the level arrives: nothing is resent under AirPlay", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(AIRPLAY, 35) },
  { 14, room(AIRPLAY, 35) },
  { 18, room(AIRPLAY, 35) },
})), "set 60; fixed 9@60")
T.eq("switching back before the level arrives: a late 60 still restores", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(AIRPLAY, 35) },
  { 12, room(AIRPLAY, 60) },
})), "set 60; fixed 9@60; set 35; restored 35")

T.section("a restart in the middle")
local _, stored = session({ { 0, room(AIRPLAY, 35) }, { 10, room(COMPUTER, 35) }, { 11, room(COMPUTER, 60) } })
local copy = {}
for k, v in pairs(stored) do
  copy[k] = v
end
T.eq(
  "still on the computer after the restart: nothing sent, AirPlay restores later",
  (session({ { 500, room(COMPUTER, 60) }, { 600, room(AIRPLAY, 60) } }, copy)),
  "set 35; restored 35"
)
local _, stored2 = session({ { 0, room(AIRPLAY, 35) }, { 10, room(COMPUTER, 35) }, { 11, room(COMPUTER, 60) } })
T.eq(
  "on AirPlay by the time the driver is back: restores",
  (session({ { 500, room(AIRPLAY, 60) } }, stored2)),
  "set 35; restored 35"
)

T.section("settings")
T.eq("a source removed from the picks while it plays: its level goes back", (session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 60) },
  { 50, room(COMPUTER, 60), settings({ sources = { [GAME] = 40 } }) },
})), "set 60; fixed 9@60; set 35; restored 35")
local _, disabled = session({
  { 0, room(AIRPLAY, 35) },
  { 10, room(COMPUTER, 35) },
  { 11, room(COMPUTER, 60) },
  { 50, room(COMPUTER, 60), settings({ enabled = false }) },
})
T.falsy("disabled forgets the picked source", Tracker.isActive(disabled))
T.eq("and the saved level", Tracker.savedLevel(disabled, room(COMPUTER, 60)), -1)
T.eq(
  "disabled sends nothing",
  (session({ { 0, room(AIRPLAY, 35) }, { 10, room(COMPUTER, 35) } }, nil, settings({ enabled = false }))),
  ""
)
T.eq("an unknown volume is never saved", (session({
  { 0, room(AIRPLAY, -1) },
  { 10, room(COMPUTER, -1) },
  { 11, room(COMPUTER, 60) },
  { 90, room(AIRPLAY, 60) },
})), "set 60; fixed 9@60")

T.finish()
