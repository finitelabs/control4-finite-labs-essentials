-- The Humidity Alert's DriverCentral license gate, with the real cloud client (license_harness.lua).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_humidity_alert.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

H.standardChecks(
  "humidity_alert",
  nil,
  {
    {
      "a Start Alert command",
      function()
        ExecuteCommand("Start Alert", { Minutes = "5" })
      end,
    },
    {
      "a Clear Alert command",
      function()
        ExecuteCommand("Clear Alert", {})
      end,
    },
  },
  "Ready",
  function(sent)
    T.check("the inputs are asked for their readings again", sent:find("GET_VALUE", 1, true) ~= nil, sent)
  end
)

T.finish()
