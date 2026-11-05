-- The Sensor Multiplexer's DriverCentral license gate, with the real cloud client (license_harness.lua).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_sensor_multiplexer.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")
local cloud = require("dc_cloud")

local function upstairsTemperature()
  for key, binding in pairs(require("lib.bindings"):getDynamicBindings("In:Upstairs")) do
    if tostring(key):lower():find("temp") then
      return binding.bindingId
    end
  end
end

local reading = 20
H.standardChecks(
  "sensor_multiplexer",
  { ["Input Names"] = "Upstairs,Downstairs" },
  {
    {
      "a reading from the selected input",
      function()
        reading = reading + 1
        ReceivedFromProxy(upstairsTemperature(), "VALUE_CHANGED", { CELSIUS = tostring(reading) })
      end,
    },
    {
      "Cycle Input",
      function()
        ExecuteCommand("Cycle Input", {})
        ExecuteCommand("Select Input", { Input = "Upstairs" })
      end,
    },
  },
  "Ready",
  function(sent)
    T.check("the output takes the selected input again", sent:find("VALUE_CHANGED", 1, true) ~= nil, sent)
  end,
  function()
    ExecuteCommand("Select Input", { Input = "Upstairs" })
    ReceivedFromProxy(upstairsTemperature(), "VALUE_CHANGED", { CELSIUS = "20" })
  end
)

T.section("sensor_multiplexer: an input list edited while stopped still selects a valid input after a purchase")
H.load("sensor_multiplexer", H.INVALID, { ["Input Names"] = "Upstairs,Downstairs" })
ExecuteCommand("Select Input", { Input = "Upstairs" })
H.reads(30)
local edit = H.run(function()
  Properties["Input Names"] = "Downstairs,Attic"
  OnPropertyChanged("Input Names")
end)
T.eq("the edit while stopped sends nothing", edit, "")
cloud.say(H.LICENSED)
T.eq("the purchase leaves a listed input selected", Properties["Active Input Name"], "Downstairs")

T.finish()
