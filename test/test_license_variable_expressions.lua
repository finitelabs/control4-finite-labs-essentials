-- Variable Expressions' DriverCentral license gate, with the real cloud client (license_harness.lua).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_variable_expressions.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

local function data(t)
  return { DATA = C4:Base64Encode(JSON:encode(t)) }
end

H.standardChecks(
  "variable_expressions",
  {},
  {
    {
      "Calculate Expression",
      function()
        ExecuteCommand("Calculate Expression", { Expression = "Sum" })
      end,
    },
    {
      "the web tab's Run",
      function()
        UIRequest("_RUN_EXPRESSION", data({ name = "Sum" }))
      end,
    },
  },
  "Ready",
  nil,
  function()
    UIRequest("_SAVE_EXPRESSION", data({ name = "Sum", mode = "equation", template = "1+1", auto = false }))
  end
)

T.finish()
