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
local LIBRARY = 30
local CLIENT = 100002
local AMP = 100

ShimSetDevices({
  [COMPUTER] = { deviceName = "Computer", driverFileName = "uibutton.c4i", roomId = ROOM },
  [AIRPLAY] = { deviceName = "AirPlay, Office", driverFileName = "airplay.c4i", roomId = ROOM },
  [LIBRARY] = {
    deviceName = "My Music",
    driverFileName = "media_service.c4i",
    protocol = { { driverFileName = "MyMusic.c4z" } },
  },
  [CLIENT] = { deviceName = "Digital Media", driverFileName = "digital_audio_client.c4i" },
})

--- The room's sources, as the room answers GET_WATCH_DEVICES and GET_LISTEN_DEVICES.
local sourceLists = {
  GET_WATCH_DEVICES = "<sources><source><id>9</id><type>VIDEO_SELECTION</type></source></sources>",
  GET_LISTEN_DEVICES = "<sources>"
    .. "<source><id>4294966298</id><type>SPECIAL_AUDIO</type></source>"
    .. "<source><id>9</id><type>AUDIO_SELECTION</type></source>"
    .. "<source><id>20</id><type>AUDIO_SELECTION</type></source>"
    .. "<source><id>30</id><type>DIGITAL_AUDIO_SERVER</type></source>"
    .. "<source><id>100002</id><type>DIGITAL_AUDIO_CLIENT</type></source>"
    .. "</sources>",
}

--- Each Source list as the driver last filled it: { list = "a,b", value = "a" }.
local lists = {}
function C4:UpdatePropertyList(name, list, value)
  lists[name] = { list = list, value = value }
end

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
    if id == ROOM and sourceLists[cmd] then
      return sourceLists[cmd]
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

-- An earlier build's Source slot, which the first load moves into Group 1.
local PICKS = { ["Source 1"] = "Computer (9)", ["Source 1 Volume"] = "60" }

T.section("source_volume: a room on an unpicked source is left alone")
setRoom(AIRPLAY, 35)
recordLevels()
T.eq("the first load", start(PICKS), "")
T.eq("Room Status", Properties["Room Status"], "Not holding: AirPlay, Office is not picked")
T.eq("Fixed Volume Active", Variables["Fixed Volume Active"], "0")
T.eq("Saved Volume", tonumber(Variables["Saved Volume"]), -1)

local REFRESH = " --  Refresh List"

T.section("source_volume: each group's list checks its sources among the room's watch and listen sources, by name")
T.eq("Group 1", lists["Group 1 Sources"].list, "(Select)," .. REFRESH .. ",[  ] AirPlay Office (20),[X] Computer (9)")
T.eq("Group 1's value", lists["Group 1 Sources"].value, "(Select)")
T.eq("Group 1 Volume", Properties["Group 1 Volume"], "60")
T.eq("Group 2", lists["Group 2 Sources"].list, "(Select)," .. REFRESH .. ",[  ] AirPlay Office (20),[  ] Computer (9)")
T.eq("the old Source 1 is cleared", Properties["Source 1"], "(Select)")

T.section("source_volume: each group shows once the one before it has a source, and the old slots never")
T.eq("Group 1", attribs["Group 1 Sources"], 0)
T.eq("Group 2", attribs["Group 2 Sources"], 0)
T.eq("Group 2 Volume", attribs["Group 2 Volume"], 0)
T.eq("Group 3", attribs["Group 3 Sources"], 1)
T.eq("Group 8 Volume", attribs["Group 8 Volume"], 1)
T.eq("Source 1", attribs["Source 1"], 1)
T.eq("Source 8 Volume", attribs["Source 8 Volume"], 1)

T.section("source_volume: the picked source sets its level, and AirPlay gets its level back")
T.eq("the computer", room(COMPUTER, 35), "set 60; event Fixed Volume Set")
T.eq("Room Status", Properties["Room Status"], "Holding 60 for Computer, will restore 35")
T.eq("Fixed Volume Active", Variables["Fixed Volume Active"], "1")
T.eq("Saved Volume", tonumber(Variables["Saved Volume"]), 35)
T.truthy("the conditional", TC.FIXED_VOLUME_ACTIVE("FIXED_VOLUME_ACTIVE", { VALUE = "Active", LOGIC = "EQUAL" }))
T.eq("the level arrives", room(COMPUTER, 60), "")
T.eq("AirPlay", room(AIRPLAY, 60), "set 35; event Volume Restored")
T.eq("the level arrives", room(AIRPLAY, 35), "")
T.eq("Fixed Volume Active", Variables["Fixed Volume Active"], "0")
T.eq("Saved Volume", tonumber(Variables["Saved Volume"]), -1)
T.falsy("the conditional", TC.FIXED_VOLUME_ACTIVE("FIXED_VOLUME_ACTIVE", { VALUE = "Active", LOGIC = "EQUAL" }))

T.section("source_volume: a restart under the picked source sends nothing and still restores")
room(COMPUTER, 35)
room(COMPUTER, 60)
setRoom(COMPUTER, 60)
ShimRestartDirector()
local restartWrites = H.run(function()
  -- Director keeps the group's volume; the stored groups keep the source, so nothing moves again.
  T.eq("the restart", start({ ["Group 1 Volume"] = "60" }), "")
end)
T.falsy("the restart never writes -1 over Saved Volume", restartWrites:find("=-1", 1, true))
T.eq("Fixed Volume Active", Variables["Fixed Volume Active"], "1")
T.eq("Saved Volume", tonumber(Variables["Saved Volume"]), 35)
T.eq("Room Status", Properties["Room Status"], "Holding 60 for Computer, will restore 35")
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
T.eq("Room Status", Properties["Room Status"], "Not holding: AirPlay, Office is not picked")

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
T.eq("Saved Volume", tonumber(Variables["Saved Volume"]), -1)
ExecuteCommand("Enable Volume Control", {})

T.section("source_volume: a checked source no room lists any more stays checked, so it can be unchecked")
sourceLists.GET_WATCH_DEVICES = "<sources></sources>"
sourceLists.GET_LISTEN_DEVICES = "<sources><source><id>20</id><type>AUDIO_SELECTION</type></source></sources>"
room(AIRPLAY, 35)
room(COMPUTER, 35)
room(AIRPLAY, 35)
T.eq("Group 1", lists["Group 1 Sources"].list, "(Select)," .. REFRESH .. ",[  ] AirPlay Office (20),[X] Computer (9)")
T.eq("Group 2", lists["Group 2 Sources"].list, "(Select)," .. REFRESH .. ",[  ] AirPlay Office (20),[  ] Computer (9)")

T.section("source_volume: a room turned off under the picked source shows the level it keeps")
room(COMPUTER, 35)
room(COMPUTER, 60)
T.eq("off", room(0, -1, { [1015] = "0" }), "")
T.eq("Room Status", Properties["Room Status"], "Room is off, will restore 35")
T.eq("Saved Volume", tonumber(Variables["Saved Volume"]), 35)
T.eq("AirPlay", room(AIRPLAY, 60), "set 35; event Volume Restored")
room(AIRPLAY, 35)

T.section("source_volume: a room that is off")
T.eq("off", room(0, -1), "")
T.eq("Room Status", Properties["Room Status"], "Room is off")

T.finish()
