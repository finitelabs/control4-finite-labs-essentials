-- The Source Volume driver's Source lists across rooms: every room's sources, the room's own first, a shared name
-- told apart by its room, and a room that joins another room's session.
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

ShimSetDevices({
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
})
H.rooms = { [KITCHEN] = "Kitchen", [LIVING] = "Living Room", [OFFICE] = "Office" }

--- A listen list holding these source ids.
local function listen(...)
  local out = { "<sources>" }
  for _, id in ipairs({ ... }) do
    out[#out + 1] = string.format("<source><id>%d</id><type>AUDIO_SELECTION</type></source>", id)
  end
  out[#out + 1] = "</sources>"
  return table.concat(out)
end

--- Each room's answer to GET_LISTEN_DEVICES. No room has watch sources.
local listenLists = {
  [KITCHEN] = listen(COMPUTER),
  [LIVING] = listen(BRIDGE_LIVING, COMPUTER),
  [OFFICE] = listen(BRIDGE_OFFICE),
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

function C4:SetPropertyAttribs() end

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

setRoom(COMPUTER, 35)
ShimPersistLand()
H.run(function()
  H.load("source_volume", H.LICENSED, { ["Source 1"] = "Computer (9)", ["Source 1 Volume"] = "60" })
  H.reads(1)
  wait(2)
end)

T.section("source_volume: each Source list holds every room's sources, the room's own first")
T.eq(
  "Source 1",
  lists["Source 1"].list,
  "(Select),Computer (9),Share Bridge (Living Room) (50),Share Bridge (Office) (51)"
)
T.eq("Source 1's pick", lists["Source 1"].value, "Computer (9)")
T.eq("Source 2", lists["Source 2"].list, lists["Source 1"].list)

T.section("source_volume: a room that joins another room's session sets the level picked for that source")
Properties["Source 2"] = "Share Bridge (Living Room) (50)"
Properties["Source 2 Volume"] = "40"
OnPropertyChanged("Source 2")
OnPropertyChanged("Source 2 Volume")
wait(2)
T.eq("the kitchen joins the living room's Share Bridge", room(BRIDGE_LIVING, 35), "set 40; event Fixed Volume Set")
T.eq("Room Status", Properties["Room Status"], "Holding 40 for Share Bridge, will restore 35")
room(BRIDGE_LIVING, 40)

T.section("source_volume: a source added to another room shows once the lists are read again")
listenLists[OFFICE] = listen(BRIDGE_OFFICE, TURNTABLE)
wait(5 * 60)
T.eq(
  "Source 3",
  lists["Source 3"].list,
  "(Select),Computer (9),Share Bridge (Living Room) (50),Share Bridge (Office) (51),Turntable (52)"
)

T.section("source_volume: a pick keeps its source when its name gains or loses the room")
listenLists[OFFICE] = listen(TURNTABLE)
wait(5 * 60)
T.eq("Source 2's pick", lists["Source 2"].value, "Share Bridge (50)")
T.eq("Source 2's list", lists["Source 2"].list, "(Select),Computer (9),Share Bridge (50),Turntable (52)")
T.eq("the kitchen still holds 40 for it", room(BRIDGE_LIVING, 40), "")
T.eq("Room Status", Properties["Room Status"], "Holding 40 for Share Bridge, will restore 35")

T.finish()
