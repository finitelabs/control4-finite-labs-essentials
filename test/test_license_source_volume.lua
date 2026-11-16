-- The Source Volume's DriverCentral license gate, with the real cloud client (license_harness.lua).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_source_volume.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

local ROOM = 19

function C4:RoomGetId()
  return ROOM
end

local clock = 1800000000
os.time = function()
  return clock
end

local function setRoom(source, volume)
  H.deviceVars[ROOM] = {
    [1000] = tostring(source),
    [1010] = "1",
    [1011] = tostring(volume),
    [1015] = "100",
    [1016] = "1",
    [1020] = "0",
  }
end

local function settle()
  OnWatchedVariableChanged(ROOM, 1000, H.deviceVars[ROOM][1000])
  clock = clock + 2
  ShimFireTimers()
end

setRoom(20, 35)

H.standardChecks(
  "source_volume",
  { ["Source 1"] = "Computer (9)", ["Source 1 Volume"] = "60" },
  {
    {
      "the room switching to the picked source and back",
      function()
        setRoom(9, 35)
        settle()
        setRoom(9, 60)
        settle()
        setRoom(20, 60)
        settle()
      end,
    },
  },
  "Ready",
  nil,
  function()
    setRoom(20, 35)
  end
)

T.finish()
