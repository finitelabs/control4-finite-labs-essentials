-- The Source Volume driver's volume groups: the old Source slots moved into groups, each group's checkbox list of
-- every room's sources as Room > Name (the room's own first), checking and unchecking, any
-- number of sources at one level, and a room that joins another room's session.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_source_volume_rooms.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

local KITCHEN = 19
local LIVING = 41
local OFFICE = 42
local COMPUTER = 9
local BRIDGE_LIVING = 50
local BRIDGE_OFFICE = 51
local TURNTABLE = 52
local FIRST_SPEAKER = 60
local SPEAKERS = 10

local devices = {
  [KITCHEN] = { deviceName = "Kitchen", driverFileName = "roomdevice.c4i" },
  [LIVING] = { deviceName = "Living Room", driverFileName = "roomdevice.c4i" },
  [OFFICE] = { deviceName = "Office", driverFileName = "roomdevice.c4i" },
  [COMPUTER] = { deviceName = "Computer", driverFileName = "uibutton.c4i", roomId = KITCHEN, roomName = "Kitchen" },
  [BRIDGE_LIVING] = {
    deviceName = "Share Bridge",
    driverFileName = "airplay.c4i",
    roomId = LIVING,
    roomName = "Living Room",
  },
  [BRIDGE_OFFICE] = {
    deviceName = "Share Bridge",
    driverFileName = "airplay.c4i",
    roomId = OFFICE,
    roomName = "Office",
  },
  [TURNTABLE] = { deviceName = "Turntable", driverFileName = "receiver.c4i", roomId = OFFICE, roomName = "Office" },
}
for i = 0, SPEAKERS - 1 do
  devices[FIRST_SPEAKER + i] =
    { deviceName = "Speaker " .. (i + 1), driverFileName = "speaker.c4i", roomId = LIVING, roomName = "Living Room" }
end
ShimSetDevices(devices)
H.rooms = { [KITCHEN] = "Kitchen", [LIVING] = "Living Room", [OFFICE] = "Office" }

--- A listen list holding these source ids.
local function listen(ids)
  local out = { "<sources>" }
  for _, id in ipairs(ids) do
    out[#out + 1] = string.format("<source><id>%d</id><type>AUDIO_SELECTION</type></source>", id)
  end
  out[#out + 1] = "</sources>"
  return table.concat(out)
end

--- Each room's answer to GET_LISTEN_DEVICES. No room has watch sources.
local listenLists = {
  [KITCHEN] = listen({ COMPUTER }),
  [LIVING] = listen({ BRIDGE_LIVING, COMPUTER }),
  [OFFICE] = listen({ BRIDGE_OFFICE }),
}

local lists = {}
function C4:UpdatePropertyList(name, list, value)
  lists[name] = { list = list, value = value }
  Properties[name] = value
end

local clock = 1800000000
os.time = function()
  return clock
end

function C4:RoomGetId()
  return KITCHEN
end

local attribs = {}
function C4:SetPropertyAttribs(name, value)
  attribs[name] = value
end

local real = C4.SendToDevice
function C4:SendToDevice(id, cmd, params)
  if id == KITCHEN and cmd == "SET_VOLUME_LEVEL" then
    H.effects[#H.effects + 1] = "set " .. tostring(params.LEVEL)
    return
  end
  if cmd == "GET_WATCH_DEVICES" then
    return "<sources></sources>"
  end
  if cmd == "GET_LISTEN_DEVICES" then
    return listenLists[id] or "<sources></sources>"
  end
  return real(self, id, cmd, params)
end

local function setRoom(source, volume)
  H.deviceVars[KITCHEN] = {
    [1000] = tostring(source),
    [1010] = source == 0 and "0" or "1",
    [1011] = tostring(volume),
    [1015] = "100",
    [1016] = "1",
    [1020] = "0",
  }
end

local function wait(seconds)
  clock = clock + seconds
  ShimFireTimers()
end

--- The levels sent and the events fired by `fn`, joined by "; ".
local function told(fn)
  local out = {}
  for line in (H.run(fn) .. "; "):gmatch("(.-); ") do
    if line:sub(1, 4) == "set " or line:sub(1, 6) == "event " then
      out[#out + 1] = line
    end
  end
  return table.concat(out, "; ")
end

local function room(source, volume)
  return told(function()
    setRoom(source, volume)
    OnWatchedVariableChanged(KITCHEN, 1000, tostring(source))
    wait(2)
  end)
end

--- Pick an option in a group's list, as Composer does.
local function pick(group, option)
  local name = "Group " .. group .. " Sources"
  Properties[name] = option
  OnPropertyChanged(name)
  wait(2)
end

local REFRESH = " --  Refresh List"
local HEAD = "(Select)," .. REFRESH .. ","

setRoom(0, 35)
ShimPersistLand()
H.run(function()
  H.load("source_volume", H.LICENSED, {
    ["Source 1"] = "Kitchen > Computer (9)",
    ["Source 1 Volume"] = "60",
    ["Source 2"] = "Share Bridge (50)",
    ["Source 2 Volume"] = "40",
    ["Source 3"] = "Share Bridge (51)",
    ["Source 3 Volume"] = "60",
    ["Source 4"] = "Kitchen > Computer (9)",
    ["Source 4 Volume"] = "30",
  })
  H.reads(1)
  wait(2)
end)

T.section("source_volume: the old Source slots move into one group per level, in slot order")
T.eq("Group 1 Volume", Properties["Group 1 Volume"], "60")
T.eq(
  "Group 1",
  lists["Group 1 Sources"].list,
  HEAD .. "[X] Kitchen > Computer (9),[  ] Living Room > Share Bridge (50),[X] Office > Share Bridge (51)"
)
T.eq("Group 2 Volume", Properties["Group 2 Volume"], "40")
T.eq(
  "Group 2",
  lists["Group 2 Sources"].list,
  HEAD .. "[  ] Kitchen > Computer (9),[X] Living Room > Share Bridge (50),[  ] Office > Share Bridge (51)"
)
T.eq("Group 3 is shown, empty", attribs["Group 3 Sources"], 0)
T.eq("Group 4 is hidden", attribs["Group 4 Sources"], 1)
T.eq("a source in two slots keeps its first level", Properties["Group 3 Volume"], "50")
T.eq("the slots are cleared", Properties["Source 4"] .. " " .. Properties["Source 4 Volume"], "(Select) 50")
T.eq("the slots are hidden", attribs["Source 1"], 1)

T.section("source_volume: a room that joins another room's session sets that source's group volume")
room(TURNTABLE, 35)
T.eq("the kitchen joins the living room's Share Bridge", room(BRIDGE_LIVING, 35), "set 40; event Fixed Volume Set")
T.eq("Room Status", Properties["Room Status"], "Holding 40 for Share Bridge, will restore 35")
room(BRIDGE_LIVING, 40)
T.eq("the office's Share Bridge, in Group 1", room(BRIDGE_OFFICE, 40), "set 60; event Fixed Volume Set")
room(BRIDGE_OFFICE, 60)
T.eq("off", room(0, -1), "")

T.section("source_volume: a restart moves nothing again")
ShimRestartDirector()
ShimPersistLand()
H.run(function()
  H.load("source_volume", H.LICENSED, {
    ["Source 1"] = "Turntable (52)",
    ["Group 1 Volume"] = "60",
    ["Group 2 Volume"] = "40",
  })
  H.reads(1)
  wait(2)
end)
T.eq(
  "Group 1",
  lists["Group 1 Sources"].list,
  HEAD .. "[X] Kitchen > Computer (9),[  ] Living Room > Share Bridge (50),[X] Office > Share Bridge (51)"
)

T.section("source_volume: picking a source checks it, and picking it again unchecks it")
pick(1, "[  ] Living Room > Share Bridge (50)")
T.eq("Group 1's value goes back", lists["Group 1 Sources"].value, "(Select)")
T.eq(
  "checked in Group 1",
  lists["Group 1 Sources"].list,
  HEAD .. "[X] Kitchen > Computer (9),[X] Living Room > Share Bridge (50),[X] Office > Share Bridge (51)"
)
T.eq(
  "and out of Group 2",
  lists["Group 2 Sources"].list,
  HEAD .. "[  ] Kitchen > Computer (9),[  ] Living Room > Share Bridge (50),[  ] Office > Share Bridge (51)"
)
T.eq("Group 3 hides behind the empty Group 2", attribs["Group 3 Sources"], 1)
T.eq("now at Group 1's level", room(BRIDGE_LIVING, 35), "set 60; event Fixed Volume Set")
room(BRIDGE_LIVING, 60)
T.eq(
  "unchecking the source that plays puts the level back",
  told(function()
    pick(1, "[X] Living Room > Share Bridge (50)")
  end),
  "set 35; event Volume Restored"
)
room(BRIDGE_LIVING, 35)
T.eq("Room Status", Properties["Room Status"], "Not holding: Share Bridge is not picked")

T.section("source_volume: one group holds any number of sources at one level")
local speakers = {}
for i = 0, SPEAKERS - 1 do
  speakers[#speakers + 1] = FIRST_SPEAKER + i
end
listenLists[LIVING] = listen({ BRIDGE_LIVING, COMPUTER, unpack(speakers) })
pick(2, REFRESH)
for i = 1, SPEAKERS do
  pick(2, "[  ] Living Room > Speaker " .. i .. " (" .. (FIRST_SPEAKER + i - 1) .. ")")
end
T.eq("Group 2 checks all ten", select(2, lists["Group 2 Sources"].list:gsub("%[X%]", "")), SPEAKERS)
room(BRIDGE_LIVING, 35)
T.eq(
  "the tenth speaker plays at Group 2's level",
  room(FIRST_SPEAKER + SPEAKERS - 1, 35),
  "set 40; event Fixed Volume Set"
)
room(FIRST_SPEAKER + SPEAKERS - 1, 40)
T.eq("and so does the first", room(FIRST_SPEAKER, 40), "event Fixed Volume Set")
T.eq("Room Status", Properties["Room Status"], "Holding 40 for Speaker 1, will restore 35")

T.section("source_volume: Refresh List shows a source added to another room")
listenLists[OFFICE] = listen({ BRIDGE_OFFICE, TURNTABLE })
pick(3, REFRESH)
T.eq("Group 3's value goes back", lists["Group 3 Sources"].value, "(Select)")
T.truthy("the turntable", lists["Group 3 Sources"].list:find("[  ] Office > Turntable (52)", 1, true))

T.finish()
