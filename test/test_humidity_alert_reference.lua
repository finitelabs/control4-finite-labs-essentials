-- The Humidity Alert's reference sensor: two inputs that exist only while Reference Sensor is Enabled, whose readings
-- correct how the room's own are judged and never start or end an alert themselves.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_humidity_alert_reference.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")
local bindings = require("lib.bindings")

-- The driver reads the time from os.time; the test moves it.
local realTime = os.time
local clock = 1800000000
os.time = function()
  return clock
end

function C4:SetPropertyAttribs(_name, _value) end

--- An input's connection id, nil while it does not exist.
local function input(key)
  local binding = bindings:getDynamicBinding("Input", key)
  return binding and binding.bindingId or nil
end

local function contact()
  return bindings:getDynamicBinding("Output", "contact").bindingId
end

--- The ids of the connections every configuration has.
local function coreIds()
  return { input("humidity"), input("temperature"), contact() }
end

--- What `fn` tells the contact and which events it fires, joined by "; ".
local function did(fn)
  local effects = H.run(fn)
  local prefix = "proxy " .. contact() .. " "
  local out = {}
  for line in (effects .. "; "):gmatch("(.-); ") do
    if line:sub(1, #prefix) == prefix then
      out[#out + 1] = line:sub(#prefix + 1)
    elseif line:sub(1, 6) == "event " then
      out[#out + 1] = line
    end
  end
  return table.concat(out, "; ")
end

--- Let `n` minutes pass, with the driver's timers firing each minute.
local function minutes(n)
  for _ = 1, n do
    clock = clock + 60
    ShimFireTimers()
  end
end

--- A room humidity report, then a minute.
local function report(rh)
  return did(function()
    ReceivedFromProxy(input("humidity"), "VALUE_CHANGED", { VALUE = tostring(rh) })
    minutes(1)
  end)
end

--- A reference humidity report, with its temperature just before it when one is given, then a minute.
local function reference(rh, celsius)
  return did(function()
    if celsius then
      ReceivedFromProxy(input("reference_temperature"), "VALUE_CHANGED", { CELSIUS = tostring(celsius) })
    end
    ReceivedFromProxy(input("reference_humidity"), "VALUE_CHANGED", { VALUE = tostring(rh) })
    minutes(1)
  end)
end

local function setProperty(name, value)
  return did(function()
    UpdateProperty(name, value, true)
  end)
end

local function start(overrides)
  return H.run(function()
    ShimPersistLand()
    H.load("humidity_alert", H.LICENSED, overrides)
    H.reads(1)
  end)
end

--- A fresh driver in a resting room at 45 percent.
local function fresh(overrides)
  start()
  ExecuteCommand("Reset_Driver", { ["Are You Sure?"] = "Yes" })
  local effects = start(overrides)
  for _ = 1, 4 do
    report(45)
  end
  return effects
end

local ENABLED = { ["Reference Sensor"] = "Enabled" }

T.section("humidity_alert reference: the inputs exist only while Reference Sensor is Enabled")
fresh()
local core = coreIds()
T.eq("Disabled has no reference inputs", { input("reference_humidity"), input("reference_temperature") }, {})
T.eq("and says so", Properties["Reference"], "Not used")
setProperty("Reference Sensor", "Enabled")
T.eq(
  "Enabled makes both",
  { input("reference_humidity") ~= nil, input("reference_temperature") ~= nil },
  { true, true }
)
T.eq("the other connections keep their ids", coreIds(), core)
T.eq("nothing heard yet", Properties["Reference"], "Waiting for a reading")
setProperty("Reference Sensor", "Disabled")
T.eq("Disabled removes both", { input("reference_humidity"), input("reference_temperature") }, {})
T.eq("the other connections keep their ids", coreIds(), core)
setProperty("Control Method", "Relay")
setProperty("Reference Sensor", "Enabled")
T.eq("beside a fan relay, the other connections keep their ids", coreIds(), core)
setProperty("Control Method", "None")
T.eq("and the reference inputs outlive the relay", input("reference_humidity") ~= nil, true)

T.section("humidity_alert reference: a bind of a reference input asks the sensor for its value at once")
fresh(ENABLED)
for _, key in ipairs({ "reference_humidity", "reference_temperature" }) do
  local id = input(key)
  local asked = H.run(function()
    OnBindingChanged(id, "", true, 503, 1)
  end)
  T.eq(key .. " bound", asked:find("proxy " .. id .. " GET_VALUE", 1, true) ~= nil, true)
  local unasked = H.run(function()
    OnBindingChanged(id, "", false, 503, 1)
  end)
  T.eq(key .. " unbound asks nothing", unasked:find("GET_VALUE", 1, true), nil)
end

T.section("humidity_alert reference: its reports correct the room's and start nothing")
fresh(ENABLED)
T.eq("a reference report", reference(47, 21), "")
T.eq("is in use", Properties["Reference"], "In use: 47 %")
T.eq("and is no reading of the room", Properties["Humidity"], "45 %")
T.eq("a reference jump starts nothing", reference(80, 21), "")
reference(47, 21)
did(function()
  ReceivedFromProxy(input("reference_temperature"), "VALUE_CHANGED", { CELSIUS = "30" })
  minutes(1)
end)
T.eq("a reference temperature alone makes no sample", Properties["Reference"], "In use: 47 %")

local setTimer = SetTimer
local armed = 0
function SetTimer(name, ...)
  if name == "PairReference" then
    armed = armed + 1
  end
  return setTimer(name, ...)
end
for i = 1, 40 do
  ReceivedFromProxy(input("reference_humidity"), "VALUE_CHANGED", { VALUE = tostring(47 + i / 10) })
end
T.eq("40 reports in a row arm the pairing wait once", armed, 1)
minutes(1)
T.eq("and the newest of them is in use", Properties["Reference"], "In use: 51 %")
SetTimer = setTimer

T.section("humidity_alert reference: a rise the house shares is not the room's")
fresh(ENABLED)
reference(47)
reference(55)
T.eq("the room up 8 with the house up 8", report(53), "")
did(function()
  OnBindingChanged(input("reference_humidity"), "HUMIDITY_VALUE", false, 700, 1)
end)
T.eq("an unbound reference is forgotten", Properties["Reference"], "Waiting for a reading")
T.eq("and the same rise then starts an alert", report(61), "CLOSED; event Alert Started")
ExecuteCommand("Clear_Alert", {})

fresh(ENABLED)
reference(47)
T.eq("a shower with the house steady starts at once", report(70), "CLOSED; event Alert Started")
ExecuteCommand("Clear_Alert", {})

T.section("humidity_alert reference: a fixed level needs the room wetter than the house")
fresh({ ["Reference Sensor"] = "Enabled", ["Detection Mode"] = "Threshold" })
reference(80)
T.eq("above the level with the house as humid", report(85), "")
reference(60)
T.eq("above the level with the house drier", report(85), "CLOSED; event Alert Started")
ExecuteCommand("Clear_Alert", {})

T.section("humidity_alert reference: a silent reference is not used")
fresh({ ["Reference Sensor"] = "Enabled", ["Sensor Timeout"] = "1" })
reference(47)
for _ = 1, 70 do
  report(45)
end
T.eq("after the Sensor Timeout", Properties["Reference"], "Silent, not in use")
reference(48)
T.eq("until it reports again", Properties["Reference"], "In use: 48 %")

T.section("humidity_alert reference: starts and resets")
fresh(ENABLED)
reference(47)
local effects = start(ENABLED)
T.eq("after a restart it waits to hear the reference again", Properties["Reference"], "Waiting for a reading")
T.contains("and asks for its humidity", effects, "proxy " .. input("reference_humidity") .. " GET_VALUE")
T.contains("and its temperature", effects, "proxy " .. input("reference_temperature") .. " GET_VALUE")
ExecuteCommand("Reset_Driver", { ["Are You Sure?"] = "Yes" })
T.eq("Reset Driver returns Reference Sensor to Disabled", Properties["Reference Sensor"], "Disabled")
T.eq("and removes its inputs", { input("reference_humidity"), input("reference_temperature") }, {})
T.eq("and says so", Properties["Reference"], "Not used")

os.time = realTime
if H.gate and H.gate._timer then
  H.gate._timer:Cancel()
end
T.finish()
