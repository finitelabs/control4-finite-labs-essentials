-- The Humidity Alert's contact, events and variables: a start fires Closed and an end fires Opened exactly once,
-- whatever ends the alert, and a start of the driver or a bind tells the state silently.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_humidity_alert_contact.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")
local bindings = require("lib.bindings")

-- The driver reads the time from os.time; the test moves it.
local clock = 1800000000
local realTime = os.time
os.time = function()
  return clock
end

--- The driver's variables as "name=id", in id order: Control4 programming binds to the id.
local function variableIds()
  local out = {}
  for name, value in pairs(require("lib.values"):getValues()) do
    out[#out + 1] = { name = name, id = value.id }
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  for i, entry in ipairs(out) do
    out[i] = entry.name .. "=" .. tostring(entry.id)
  end
  return table.concat(out, ", ")
end

local attribs = {}
function C4:SetPropertyAttribs(name, value)
  attribs[name] = value
end

local function humidityInput()
  return bindings:getDynamicBinding("Input", "humidity").bindingId
end

local function temperatureInput()
  return bindings:getDynamicBinding("Input", "temperature").bindingId
end

local function output()
  return bindings:getDynamicBinding("Output", "contact").bindingId
end

--- What `fn` tells the contact output and which events it fires, joined by "; " ("" for nothing).
local function told(fn)
  local effects = H.run(fn)
  local prefix = "proxy " .. output() .. " "
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

--- A humidity report, with a temperature report just before it when one is given, then a minute.
local function report(rh, celsius)
  return told(function()
    if celsius then
      ReceivedFromProxy(temperatureInput(), "VALUE_CHANGED", { CELSIUS = tostring(celsius) })
    end
    ReceivedFromProxy(humidityInput(), "VALUE_CHANGED", { VALUE = tostring(rh) })
    minutes(1)
  end)
end

local function command(name, params)
  return told(function()
    ExecuteCommand(name, params or {})
  end)
end

local function setProperty(name, value)
  return told(function()
    UpdateProperty(name, value, true)
  end)
end

local function start(overrides, answer)
  return told(function()
    ShimPersistLand()
    H.load("humidity_alert", answer or H.LICENSED, overrides)
    H.reads(1)
  end)
end

--- A resting room, so the next jump is measured from 45 percent.
local function rest()
  for _ = 1, 4 do
    report(45, 22)
  end
end

T.section("humidity_alert: a start tells the contact its state silently and creates the variables in order")
T.eq("the first load", start(), "STATE_OPENED")
T.eq("the variables", variableIds(), "Alert Active=1001, Alert Reason=1002, Humidity Rise=1003")
T.eq("Alert", Properties["Alert"], "Clear")

T.section("humidity_alert: the first reading only sets the baseline")
setProperty("Detection Mode", "Rise or Threshold")
T.eq("a first reading above the threshold", report(90, 22), "")
setProperty("Detection Mode", "Rise")
start()

T.section("humidity_alert: a shower fires Closed once, and its recovery fires Opened once")
rest()
T.eq("a jump", report(75, 23), "CLOSED; event Alert Started")
T.eq("Alert", Properties["Alert"], "Active (Rise)")
T.eq("Alert Active", Variables["Alert Active"], "1")
T.eq("Alert Reason", Variables["Alert Reason"], "Rise")
T.eq("Humidity Rise", tonumber(Variables["Humidity Rise"]), 30)
T.eq("Start Humidity", Properties["Start Humidity"], "45 %")
T.eq("still rising", report(95, 25), "")
T.eq("Peak Humidity", Properties["Peak Humidity"], "95 %")
T.eq("the room recovers, and the run-on starts", report(50, 22), "")
local cleared = told(function()
  minutes(11)
end)
T.eq("the run-on ends", cleared, "OPENED; event Alert Cleared")
T.eq("Alert Active", Variables["Alert Active"], "0")
T.eq("Alert Reason", Variables["Alert Reason"], "")
T.eq("Humidity Rise", tonumber(Variables["Humidity Rise"]), 0)
T.eq("Peak Humidity", Properties["Peak Humidity"], "")

T.section("humidity_alert: an alert that reaches its maximum says so")
start({ ["Maximum Alert Time"] = "5" })
rest()
T.eq("a jump", report(90, 24), "CLOSED; event Alert Started")
local timedOut = told(function()
  for _ = 1, 6 do
    report(90, 24)
  end
end)
T.eq("the maximum", timedOut, "OPENED; event Alert Cleared; event Alert Timed Out")

T.section("humidity_alert: commands")
start()
T.eq("Start Alert", command("Start Alert", { Minutes = "5" }), "CLOSED; event Alert Started")
T.eq("Alert", Properties["Alert"], "Active (Manual)")
T.eq("Start Alert again", command("Start Alert", { Minutes = "5" }), "")
T.eq("Clear Alert", command("Clear Alert"), "OPENED; event Alert Cleared")
T.eq("Clear Alert again", command("Clear Alert"), "")
command("Start Alert", { Minutes = "5" })
local expired = told(function()
  minutes(6)
end)
T.eq("a manual alert ends at its time, and is not a time-out", expired, "OPENED; event Alert Cleared")

T.section("humidity_alert: Detection disabled ends an alert and starts none")
command("Start Alert", { Minutes = "30" })
T.eq("Disable Detection", command("Disable Detection"), "OPENED; event Alert Cleared")
T.eq("Detection", Properties["Detection"], "Disabled")
T.eq("Alert", Properties["Alert"], "Clear (detection disabled)")
rest()
T.eq("a jump while disabled", report(80, 23), "")
T.eq("Enable Detection", command("Enable Detection"), "")
T.eq("Detection", Properties["Detection"], "Enabled")

T.section("humidity_alert: the humidity input unbound ends an alert with its programming")
start()
command("Start Alert", { Minutes = "30" })
local unbound = told(function()
  OnBindingChanged(humidityInput(), "HUMIDITY_VALUE", false, 500, 1)
end)
T.eq("unbound", unbound, "OPENED; event Alert Cleared")

T.section("humidity_alert: a bind of the contact tells the state silently")
command("Start Alert", { Minutes = "30" })
local bound = told(function()
  OnBindingChanged(output(), "CONTACT_SENSOR", true, 501, 1)
end)
T.eq("bound during an alert", bound, "STATE_CLOSED")
local unboundOutput = told(function()
  OnBindingChanged(output(), "CONTACT_SENSOR", false, 501, 1)
end)
T.eq("unbound", unboundOutput, "")

T.section("humidity_alert: a restart during an alert tells it silently, and its end still fires")
T.eq("a restart", start(), "STATE_CLOSED")
T.eq("Alert Active", Variables["Alert Active"], "1")
T.eq("Clear Alert", command("Clear Alert"), "OPENED; event Alert Cleared")

T.section("humidity_alert: an alert that ended while the controller was down is ended at the first tick")
command("Start Alert", { Minutes = "5" })
ShimPersistLand()
clock = clock + 2 * 60 * 60
T.eq("a restart two hours later", start(), "STATE_CLOSED")
local firstTick = told(function()
  minutes(1)
end)
T.eq("the first tick", firstTick, "OPENED; event Alert Cleared")

T.section("humidity_alert: the property replay at a start decides nothing")
command("Start Alert", { Minutes = "30" })
T.eq("a restart with Detection disabled", start({ ["Detection"] = "Disabled" }), "STATE_CLOSED")
local afterReplay = told(function()
  minutes(1)
end)
T.eq("the first tick ends it with its programming", afterReplay, "OPENED; event Alert Cleared")

T.section("humidity_alert: a license lapse ends an alert with Opened and no events")
start(nil, H.INVALID)
T.eq("Start Alert while the gate still runs", command("Start Alert", { Minutes = "60" }), "CLOSED; event Alert Started")
local lapsed = told(function()
  H.reads(30)
end)
T.eq("the gate stops the driver", lapsed, "OPENED")
T.eq("Driver Status", Properties["Driver Status"], "No active license")

T.section("humidity_alert: Reset Driver ends an alert first and creates the variables again in order")
start()
command("Start Alert", { Minutes = "30" })
local reset = told(function()
  ExecuteCommand("Reset_Driver", { ["Are You Sure?"] = "Yes" })
end)
T.eq("reset", reset, "OPENED; event Alert Cleared; STATE_OPENED")
T.eq("the variables", variableIds(), "Alert Active=1001, Alert Reason=1002, Humidity Rise=1003")
T.eq("Alert", Properties["Alert"], "Clear")

T.section("humidity_alert: a mode hides the settings it does not use")
start()
setProperty("Detection Mode", "Threshold")
T.eq("Rise Amount", attribs["Rise Amount"], 1)
T.eq("Recovery", attribs["Recovery"], 1)
T.eq("Alert Above", attribs["Alert Above"], 0)
setProperty("Detection Mode", "Rise")
T.eq("Rise Amount", attribs["Rise Amount"], 0)
T.eq("Clear Below", attribs["Clear Below"], 1)
T.eq("a hidden setting keeps its value", Properties["Clear Below"], "70")

T.section("humidity_alert: a sample is a humidity report with the newest temperature")
start()
report(45, 22)
told(function()
  ReceivedFromProxy(temperatureInput(), "VALUE_CHANGED", { CELSIUS = "30" })
  minutes(1)
end)
T.eq("a temperature report alone makes no sample", Properties["Temperature"], "22 °C / 71.6 °F")
told(function()
  ReceivedFromProxy(humidityInput(), "VALUE_CHANGED", { VALUE = "46" })
  ReceivedFromProxy(temperatureInput(), "VALUE_CHANGED", { CELSIUS = "23" })
  minutes(1)
end)
T.eq("a temperature just after its humidity joins it", Properties["Temperature"], "23 °C / 73.4 °F")
T.eq("Humidity", Properties["Humidity"], "46 %")
T.contains("Dew Point", Properties["Dew Point"], "°C / ")

T.section("humidity_alert: a silent sensor fires its event once, and the conditionals follow")
start({ ["Sensor Timeout"] = "1" })
report(45, 22)
local silent = told(function()
  minutes(70)
end)
T.eq("an hour of silence", silent, "event Humidity Sensor Stale")
T.truthy("stale is", TestCondition("HUMIDITY_SENSOR_STALE", { VALUE = "Stale", LOGIC = "EQUAL" }))
T.falsy("stale is not", TestCondition("HUMIDITY_SENSOR_STALE", { VALUE = "Stale", LOGIC = "NOT_EQUAL" }))
T.eq("Alert", Properties["Alert"], "Clear (humidity sensor stale)")
report(45, 22)
T.falsy("a report restores it", TestCondition("HUMIDITY_SENSOR_STALE", { VALUE = "Stale", LOGIC = "EQUAL" }))
T.falsy("no alert", TestCondition("ALERT_ACTIVE", { VALUE = "Active", LOGIC = "EQUAL" }))
command("Start Alert", { Minutes = "5" })
T.truthy("an alert", TestCondition("ALERT_ACTIVE", { VALUE = "Active", LOGIC = "EQUAL" }))
T.truthy("not clear", TestCondition("ALERT_ACTIVE", { VALUE = "Clear", LOGIC = "NOT_EQUAL" }))
command("Clear Alert")

os.time = realTime
if H.gate and H.gate._timer then
  H.gate._timer:Cancel()
end
T.finish()
