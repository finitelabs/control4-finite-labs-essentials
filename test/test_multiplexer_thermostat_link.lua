-- Tests for Sensor Multiplexer's thermostat link: matching inputs to the thermostat's
-- presets, the order a switch sends its two changes in, and following the thermostat.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_multiplexer_thermostat_link.lua

local T = require("testlib")
local F = require("mux_fixtures")

require("lib.utils")

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

ShimPersistLater(false)
-- Director seeds Properties from driver.xml; the shim starts with none.
for name, value in pairs({
  ["Input Names"] = "Away,Home,Sleep",
  ["Enable Temperature"] = "Yes",
  ["Enable Humidity"] = "No",
  ["Enable Contact"] = "No",
  ["Linked Thermostat"] = "",
  ["Thermostat Link Status"] = "",
  ["Active Input Name"] = "",
  ["Output Temperature C"] = "",
  ["Output Temperature F"] = "",
  ["Output Humidity"] = "",
  ["Output Contact"] = "",
}) do
  Properties[name] = value
end

-- Cooling to Home's 20/24 at 23 °C, idle. The thermostat spells Sleep in lowercase and has no Away.
local thermostat = F.thermostat({
  presets = { { name = "Home", heat = 20, cool = 24 }, { name = "sleep", heat = 19, cool = 22 } },
  mode = "Cool",
  preset = "Home",
  temperature = 23,
})

dofile(root .. "/drivers/sensor_multiplexer/driver.lua")
local persist = require("lib.persist")
local bindings = require("lib.bindings")

persist:set("InputValues", { Home = { temp = 23 }, Sleep = { temp = 21 }, Away = { temp = 25 } })
OPC.Input_Names(Properties["Input Names"])
Properties["Linked Thermostat"] = tostring(thermostat.proxyId)
OPC.Linked_Thermostat(Properties["Linked Thermostat"])

--- Run a switch to completion: each poll of the thermostat is a timer.
local function settle()
  for _ = 1, 10 do
    ShimFireTimers()
  end
end

local function commands()
  local out = {}
  for _, sent in ipairs(thermostat.sent) do
    out[#out + 1] = sent.command .. " " .. tostring(sent.name or sent.value)
  end
  thermostat.sent = {}
  return out
end

--------------------------------------------------------------------------------
T.section("Linking")
--------------------------------------------------------------------------------
T.eq("the active input follows the thermostat's preset", Properties["Active Input Name"], "Home")
T.eq(
  "status asks for the connection first",
  Properties["Thermostat Link Status"],
  "Connect Output Temperature to this thermostat's Temperature input"
)

local output = assert(bindings:getDynamicBinding("Output", "temperature"))
C4:Bind(C4:GetDeviceID(), output.bindingId, thermostat.protocolId, 4, "TEMPERATURE_VALUE")
OPC.Input_Names(Properties["Input Names"])
T.eq(
  "status names the input with no preset",
  Properties["Thermostat Link Status"],
  "Thermostat has no preset named: Away"
)

--------------------------------------------------------------------------------
T.section("Inputs match presets ignoring case")
--------------------------------------------------------------------------------
commands()
EC.Select_Input({ Input = "Sleep" })
settle()
-- 21 °C against Home's 20/24 keeps the thermostat idle, so the temperature goes first.
T.eq("sends the thermostat's own spelling", commands(), { "TEMPERATURE 21", "SET_PRESET sleep" })
T.eq("selects the input", Properties["Active Input Name"], "Sleep")
T.falsy("finishes the switch", Timer.LinkedThermostat)

--------------------------------------------------------------------------------
T.section("An input with no preset switches without waiting")
--------------------------------------------------------------------------------
EC.Select_Input({ Input = "Away" })
T.eq("sends only the temperature", commands(), { "TEMPERATURE 25" })
T.eq("selects the input at once", Properties["Active Input Name"], "Away")
T.falsy("leaves nothing waiting", Timer.LinkedThermostat)

--------------------------------------------------------------------------------
T.section("A change that would start the equipment goes second")
--------------------------------------------------------------------------------
-- 23 °C against sleep's 19/22 would start cooling, so Home's setpoints go first.
EC.Select_Input({ Input = "Home" })
settle()
T.eq("sends the preset before the temperature", commands(), { "SET_PRESET Home", "TEMPERATURE 23" })
T.eq("selects the input", Properties["Active Input Name"], "Home")

--------------------------------------------------------------------------------
T.section("Presets changed at the thermostat")
--------------------------------------------------------------------------------
thermostat:set("HEAT_SETPOINT_C", 19)
thermostat:set("COOL_SETPOINT_C", 22)
T.eq("a learned preset is followed by its setpoints", Properties["Active Input Name"], "Sleep")
thermostat:set("PRESET", "sleep")
thermostat:set("HEAT_SETPOINT_C", 20)
thermostat:set("COOL_SETPOINT_C", 24)
thermostat:set("PRESET", "Home")
T.eq("a reported preset is followed by its name", Properties["Active Input Name"], "Home")

--------------------------------------------------------------------------------
T.section("Status once every input has a preset")
--------------------------------------------------------------------------------
thermostat:addPreset("Away", 16, 27)
OPC.Input_Names(Properties["Input Names"])
T.eq(
  "lists presets not yet seen applied",
  Properties["Thermostat Link Status"],
  "Linked. Not yet seen on the thermostat: Away"
)
EC.Select_Input({ Input = "Away" })
settle()
T.eq("is Linked once all have been seen", Properties["Thermostat Link Status"], "Linked")

--------------------------------------------------------------------------------
T.section("Auto: an order that lands on the final call is clean")
--------------------------------------------------------------------------------
-- Away's 16/27 at 18 °C is idle, and Home's 28 °C ends up cooling against 20/24. Home's setpoints
-- first would call for heat at 18 °C on the way; the temperature first goes straight to cooling.
thermostat:set("HVAC_MODE", "Auto")
persist:set("InputValues", { Home = { temp = 28 }, Sleep = { temp = 21 }, Away = { temp = 18 } })
thermostat:set("TEMPERATURE_C", 18)
commands()
EC.Select_Input({ Input = "Home" })
settle()
T.eq("sends the temperature first", commands(), { "TEMPERATURE 28", "SET_PRESET Home" })

-- Back to Away while cooling: 18 °C against Home's 20/24 would call for heat, but Away's 16/27
-- at 28 °C keeps cooling until the temperature lands, so the preset goes first.
thermostat:set("HVAC_STATE", "Cooling")
EC.Select_Input({ Input = "Away" })
settle()
T.eq("sends the preset first", commands(), { "SET_PRESET Away", "TEMPERATURE 18" })

thermostat:restore()
T.finish()
