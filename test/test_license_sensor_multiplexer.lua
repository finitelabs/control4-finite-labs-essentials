-- The Sensor Multiplexer's DriverCentral license gate, with the real cloud client (license_harness.lua).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_sensor_multiplexer.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

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

T.finish()
