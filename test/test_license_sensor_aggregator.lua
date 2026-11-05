-- The Sensor Aggregator's DriverCentral license gate, with the real cloud client (license_harness.lua).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_sensor_aggregator.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

local function input()
  for _, binding in pairs(require("lib.bindings"):getDynamicBindings("TempIn")) do
    return binding.bindingId
  end
end
local function output()
  return require("lib.bindings"):getDynamicBinding("Output", "temperature").bindingId
end

local reading = 20
H.standardChecks(
  "sensor_aggregator",
  { ["Temperature Inputs"] = "2" },
  {
    {
      "an input reading",
      function()
        reading = reading + 1
        ReceivedFromProxy(input(), "VALUE_CHANGED", { CELSIUS = tostring(reading) })
      end,
    },
    {
      "an output GET_VALUE",
      function()
        ReceivedFromProxy(output(), "GET_VALUE", {})
      end,
    },
  },
  "Active",
  function(sent)
    T.check("the output takes the aggregate again", sent:find("VALUE_CHANGED", 1, true) ~= nil, sent)
  end,
  function()
    ReceivedFromProxy(input(), "VALUE_CHANGED", { CELSIUS = "20" })
  end
)

T.finish()
