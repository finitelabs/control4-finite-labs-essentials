-- Tests that Sensor Multiplexer's Selection Changed event puts NAME in its
-- description. Director replaces NAME with the device's name, and Composer Pro
-- titles a script with the description, so without it the title does not say
-- which multiplexer the event is from.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_event_names.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

T.section("Sensor Multiplexer's Selection Changed names the device")
ShimResetEvents()
-- Director seeds Properties from driver.xml; the shim starts with none.
Properties["Active Input Name"] = ""
dofile(root .. "/drivers/sensor_multiplexer/driver.lua")
OPC.Input_Names("Away,Home")
local declared = {}
for _, event in pairs(ShimEvents()) do
  declared[event.name] = event.description
end
T.eq("declared", declared, { ["Selection Changed"] = "Fires when the active input selection of NAME changes" })

T.finish()
