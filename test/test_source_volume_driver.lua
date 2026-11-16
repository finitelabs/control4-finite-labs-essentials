-- The Source Volume driver in its room: the levels it sends, the events it fires, Room Status and its variables,
-- across a restart.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_source_volume_driver.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

local ROOM = 19
local COMPUTER = 9
local AIRPLAY = 20
local AMP = 100

-- The driver reads the time from os.time; the test moves it.
local clock = 1800000000
os.time = function()
  return clock
end

function C4:RoomGetId()
  return ROOM
end

local attribs = {}
function C4:SetPropertyAttribs(name, value)
  attribs[name] = value
end

--- The room's variables, as Director holds them.
local function setRoom(source, volume, overrides)
  local vars = {
    [1000] = tostring(source),
    [1010] = source == 0 and "0" or "1",
    [1011] = tostring(volume),
    [1015] = tostring(AMP),
    [1016] = "1",
    [1020] = "0",
  }
  for k, v in pairs(overrides or {}) do
    vars[k] = v
  end
  H.deviceVars[ROOM] = vars
end

--- Every level the driver sends lands in the effects as "set N".
local function recordLevels()
  local real = C4.SendToDevice
  function C4:SendToDevice(id, cmd, params)
    if id == ROOM and cmd == "SET_VOLUME_LEVEL" then
      H.effects[#H.effects + 1] = "set " .. tostring(params.LEVEL)
      return
    end
    return real(self, id, cmd, params)
  end
end

--- The levels sent and the events fired by `fn`, joined by "; " ("" for nothing).
local function told(fn)
  local out = {}
  for line in (H.run(fn) .. "; "):gmatch("(.-); ") do
    if line:sub(1, 4) == "set " or line:sub(1, 6) == "event " then
      out[#out + 1] = line
    end
  end
  return table.concat(out, "; ")
end

--- Let `seconds` pass, with the driver's timers firing.
local function wait(seconds)
  clock = clock + seconds
  ShimFireTimers()
end

--- The room changes, tells the driver, and settles.
local function room(source, volume, overrides)
  return told(function()
    setRoom(source, volume, overrides)
    OnWatchedVariableChanged(ROOM, 1000, tostring(source))
    wait(2)
  end)
end

local function start(overrides)
  ShimPersistLand()
  local effects = told(function()
    H.load("source_volume", H.LICENSED, overrides)
    H.reads(1)
    wait(2)
  end)
  return effects
end

local PICKS = { ["Source 1"] = tostring(COMPUTER), ["Source 1 Volume"] = "60" }

T.section("source_volume: a room on an unpicked source is left alone")
setRoom(AIRPLAY, 35)
recordLevels()
T.eq("the first load", start(PICKS), "")
T.eq("Room Status", Properties["Room Status"], "Not holding: device 20 is not picked")
T.eq("FIXED_VOLUME_ACTIVE", Variables["FIXED_VOLUME_ACTIVE"], "0")
T.eq("SAVED_VOLUME", tonumber(Variables["SAVED_VOLUME"]), -1)

T.section("source_volume: each Source slot shows once the one before it is filled")
T.eq("Source 1", attribs["Source 1"], 0)
T.eq("Source 2", attribs["Source 2"], 0)
T.eq("Source 2 Volume", attribs["Source 2 Volume"], 0)
T.eq("Source 3", attribs["Source 3"], 1)
T.eq("Source 8 Volume", attribs["Source 8 Volume"], 1)

T.section("source_volume: the picked source sets its level, and AirPlay gets its level back")
T.eq("the computer", room(COMPUTER, 35), "set 60; event Fixed Volume Set")
T.eq("Room Status", Properties["Room Status"], "Holding 60 for device 9, will restore 35")
T.eq("FIXED_VOLUME_ACTIVE", Variables["FIXED_VOLUME_ACTIVE"], "1")
T.eq("SAVED_VOLUME", tonumber(Variables["SAVED_VOLUME"]), 35)
T.truthy("the conditional", TC.FIXED_VOLUME_ACTIVE("FIXED_VOLUME_ACTIVE", { VALUE = "Active", LOGIC = "EQUAL" }))
T.eq("the level arrives", room(COMPUTER, 60), "")
T.eq("AirPlay", room(AIRPLAY, 60), "set 35; event Volume Restored")
T.eq("the level arrives", room(AIRPLAY, 35), "")
T.eq("FIXED_VOLUME_ACTIVE", Variables["FIXED_VOLUME_ACTIVE"], "0")
T.eq("SAVED_VOLUME", tonumber(Variables["SAVED_VOLUME"]), -1)
T.falsy("the conditional", TC.FIXED_VOLUME_ACTIVE("FIXED_VOLUME_ACTIVE", { VALUE = "Active", LOGIC = "EQUAL" }))

T.section("source_volume: a restart under the picked source sends nothing and still restores")
room(COMPUTER, 35)
room(COMPUTER, 60)
setRoom(COMPUTER, 60)
T.eq("the restart", start(PICKS), "")
T.eq("Room Status", Properties["Room Status"], "Holding 60 for device 9, will restore 35")
T.eq("AirPlay", room(AIRPLAY, 60), "set 35; event Volume Restored")
room(AIRPLAY, 35)

T.section("source_volume: a level that doesn't arrive is sent once more, then reported")
T.eq("the computer", room(COMPUTER, 35), "set 60; event Fixed Volume Set")
T.eq(
  "3 seconds on",
  told(function()
    wait(3)
  end),
  "set 60"
)
T.eq(
  "3 more",
  told(function()
    wait(3)
  end),
  ""
)
T.eq("Room Status", Properties["Room Status"], "Volume 60 was sent but didn't arrive")
T.eq("AirPlay: the room never left 35, so nothing is sent", room(AIRPLAY, 35), "event Volume Restored")
T.eq("Room Status", Properties["Room Status"], "Not holding: device 20 is not picked")

T.section("source_volume: a room whose volume can't be set to a level")
T.eq("the computer", room(COMPUTER, 35, { [1016] = "0" }), "")
T.eq("Room Status", Properties["Room Status"], "This room's volume can't be set to a level")
room(AIRPLAY, 35)

T.section("source_volume: Disable Volume Control changes nothing")
ExecuteCommand("Disable Volume Control", {})
T.eq("Volume Control", Properties["Volume Control"], "Disabled")
T.eq("the computer", room(COMPUTER, 35), "")
T.eq("Room Status", Properties["Room Status"], "Disabled")
T.eq(
  "Enable Volume Control sets the level",
  told(function()
    ExecuteCommand("Enable Volume Control", {})
    wait(2)
  end),
  "set 60; event Fixed Volume Set"
)
T.eq(
  "a disable while it holds forgets the level from before",
  told(function()
    ExecuteCommand("Disable Volume Control", {})
  end),
  ""
)
T.eq("SAVED_VOLUME", tonumber(Variables["SAVED_VOLUME"]), -1)
ExecuteCommand("Enable Volume Control", {})

T.section("source_volume: a room that is off")
T.eq("off", room(0, -1), "")
T.eq("Room Status", Properties["Room Status"], "Room is off")

T.finish()
