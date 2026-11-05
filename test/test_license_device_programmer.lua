-- The Device Programmer's DriverCentral license gate, with the real cloud client (license_harness.lua).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_device_programmer.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

local ROOM, HIDE = 1, 400
ShimSetDevices({
  [ROOM] = { deviceName = "Office", driverFileName = "roomdevice.c4i" },
  [HIDE] = { deviceName = "Desk Lamp", driverFileName = "light_v2.c4i", roomId = "1", roomName = "Office" },
})
H.rooms = { [ROOM] = "Office" }

local function binding(namespace, name)
  return require("lib.bindings"):getDynamicBinding(namespace, name).bindingId
end

local reading = 70
H.standardChecks(
  "device_programmer",
  { ["Temperature Names"] = "Kitchen", ["Relay Names"] = "Pump" },
  {
    {
      "Set Temperature",
      function()
        reading = reading + 1
        ExecuteCommand("Set Temperature", { Name = "Kitchen", Value = tostring(reading), Scale = "Fahrenheit" })
      end,
    },
    {
      "Toggle Relay",
      function()
        ExecuteCommand("Toggle Relay", { Name = "Pump" })
      end,
    },
    {
      "a relay TOGGLE",
      function()
        ReceivedFromProxy(binding("Relay", "Pump"), "TOGGLE", {})
      end,
    },
    {
      "a temperature GET_VALUE",
      function()
        ReceivedFromProxy(binding("Temperature", "Kitchen"), "GET_VALUE", {})
      end,
    },
    {
      "Hide Devices",
      function()
        Properties["Hide Devices"] = tostring(HIDE)
        OnPropertyChanged("Hide Devices")
      end,
    },
  },
  "Ready",
  function(sent)
    T.check("the outputs take their values again", sent:find("VALUE_CHANGED", 1, true) ~= nil, sent)
    T.check(
      "with no programming event",
      sent:find(" CLOSED", 1, true) == nil and sent:find(" OPENED", 1, true) == nil,
      sent
    )
  end
)

T.finish()
