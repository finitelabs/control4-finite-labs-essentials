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
local F = require("mux_fixtures")

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

T.section("sensor_multiplexer: a linked switch under way when the license stops sends no preset")
H.load("sensor_multiplexer", H.INVALID, { ["Input Names"] = "Home,Sleep" })
-- Idle at Home's 20/24 and 23 °C: the temperature goes first, so the preset waits on a timer.
local thermostat = F.thermostat({
  presets = { { name = "Home", heat = 20, cool = 24 }, { name = "Sleep", heat = 19, cool = 22 } },
  mode = "Cool",
  preset = "Home",
  temperature = 23,
})
-- The harness answers GetDeviceVariable from its own table; the link reads the thermostat's.
local getDeviceVariable = C4.GetDeviceVariable
function C4:GetDeviceVariable(id, variableId)
  local variable = (self:GetDeviceVariables(id) or {})[tostring(variableId)]
  return variable and variable.value
end
require("lib.persist"):set("InputValues", { Home = { temp = 23 }, Sleep = { temp = 21 } })
Properties["Linked Thermostat"] = tostring(thermostat.proxyId)
OnPropertyChanged("Linked Thermostat")
ExecuteCommand("Select Input", { Input = "Sleep" })
local sentBeforeStop = thermostat.sent[#thermostat.sent]
T.eq("the temperature went first", sentBeforeStop.command, "TEMPERATURE")
H.reads(30)
T.eq("the license has stopped", Properties["Driver Status"], "No active license")
for _ = 1, 10 do
  ShimFireTimers()
end
local presets = 0
for _, sent in ipairs(thermostat.sent) do
  if sent.command == "SET_PRESET" then
    presets = presets + 1
  end
end
T.eq("no preset reaches the thermostat", presets, 0)
thermostat:restore()
C4.GetDeviceVariable = getDeviceVariable

T.finish()
