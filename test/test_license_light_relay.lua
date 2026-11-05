-- The Light Relay's DriverCentral license gate, with the real cloud client (license_harness.lua).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_light_relay.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

local LIGHT, ROOM = 400, 1
ShimSetDevices({
  [ROOM] = { deviceName = "Office", driverFileName = "roomdevice.c4i" },
  [LIGHT] = { deviceName = "Desk Lamp", driverFileName = "light_v2.c4i", roomId = "1", roomName = "Office" },
})
H.rooms = { [ROOM] = "Office" }
H.deviceVars[LIGHT] = { [1000] = "0" } -- off, so a relay CLOSE turns it on every time

local function relay()
  return require("lib.bindings"):getDynamicBinding("Convert Lights To Relays", LIGHT).bindingId
end

H.standardChecks(
  "light_relay",
  { ["Convert Lights To Relays"] = tostring(LIGHT) },
  {
    {
      "a relay CLOSE",
      function()
        ReceivedFromProxy(relay(), "CLOSE", {})
      end,
    },
    {
      "a relay TOGGLE",
      function()
        ReceivedFromProxy(relay(), "TOGGLE", {})
      end,
    },
    {
      "the light turning on",
      function()
        OnWatchedVariableChanged(LIGHT, 1000, "0")
        OnWatchedVariableChanged(LIGHT, 1000, "1")
      end,
    },
    {
      "Hide Lights In All Rooms",
      function()
        ExecuteCommand("LUA_ACTION", { ACTION = "Hide Lights In All Rooms" })
      end,
    },
  },
  "Ready",
  function(sent)
    T.eq("the relay takes the light's state with no programming event", sent, "proxy " .. relay() .. " STATE_OPENED")
  end
)

T.finish()
