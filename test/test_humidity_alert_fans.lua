-- The Humidity Alert's fans: an alert turns on the fans the Control Method selects and turns off only the ones it
-- turned on, a fan switched off during an alert ends it, and a fan something else ran is taken over at most once.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_humidity_alert_fans.lua

local LIGHT_A, LIGHT_B, FAN = 400, 401, 500

require("c4_shim")
ShimSetDevices({
  [1] = { deviceName = "Bathroom", driverFileName = "roomdevice.c4i" },
  [LIGHT_A] = { deviceName = "Shower Fan", driverFileName = "light_v2.c4i", roomId = "1", roomName = "Bathroom" },
  [LIGHT_B] = { deviceName = "Tub Fan", driverFileName = "light_v2.c4i", roomId = "1", roomName = "Bathroom" },
  [FAN] = { deviceName = "Ceiling Fan", driverFileName = "fan.c4i", roomId = "1", roomName = "Bathroom" },
})

local T = require("testlib")
local H = require("license_harness")
local bindings = require("lib.bindings")

-- The driver reads the time from os.time; the test moves it.
local clock = 1800000000
os.time = function()
  return clock
end

local attribs = {}
function C4:SetPropertyAttribs(name, value)
  attribs[name] = value
end

-- ParseDeviceIdPropertyList reads each selector's type and items from the driver's own device data.
local shimGetDeviceData = C4.GetDeviceData
function C4:GetDeviceData(deviceId, key)
  if key == "properties" then
    return "<property><name>Light Switches</name><type>DEVICE_SELECTOR</type>"
      .. "<items><item>light.c4i</item><item>light_v2.c4i</item><item>outlet_light.c4i</item></items></property>"
      .. "<property><name>Fan Controller</name><type>DEVICE_SELECTOR</type>"
      .. "<items><item>fan.c4i</item></items></property>"
  end
  return shimGetDeviceData(self, deviceId, key)
end

local LIGHTS = { ["Control Method"] = "Light Switch", ["Light Switches"] = "400,401" }
local RELAY = { ["Control Method"] = "Relay" }
local CONTROLLER = { ["Control Method"] = "Fan Speed Controller", ["Fan Controller"] = "500" }

local function humidityInput()
  return bindings:getDynamicBinding("Input", "humidity").bindingId
end

local function contact()
  return bindings:getDynamicBinding("Output", "contact").bindingId
end

--- The Relay connection's id, nil while it does not exist.
local function relay()
  local binding = bindings:getDynamicBinding("Output", "fan_relay")
  return binding and binding.bindingId or nil
end

--- What `fn` tells the contact, the relay and the devices, and which events it fires, joined by "; ".
local function did(fn)
  local effects = H.run(fn)
  local names = { [tostring(contact())] = "contact" }
  if relay() then
    names[tostring(relay())] = "relay"
  end
  local out = {}
  for line in (effects .. "; "):gmatch("(.-); ") do
    local id, command = line:match("^proxy (%d+) (.+)$")
    if id and names[id] then
      out[#out + 1] = names[id] .. " " .. command
    elseif line:sub(1, 6) == "event " or line:sub(1, 7) == "device " then
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

local function report(rh)
  return did(function()
    ReceivedFromProxy(humidityInput(), "VALUE_CHANGED", { VALUE = tostring(rh) })
    minutes(1)
  end)
end

local function command(name, params)
  return did(function()
    ExecuteCommand(name, params or {})
  end)
end

local function setProperty(name, value)
  return did(function()
    UpdateProperty(name, value, true)
  end)
end

--- A light or fan controller shows a state: its variable changes and the driver hears of it.
local function shows(deviceId, on)
  return did(function()
    H.deviceVars[deviceId] = { [1000] = on and "1" or "0" }
    OnWatchedVariableChanged(deviceId, 1000, on and "1" or "0")
  end)
end

--- The relay reports a state.
local function relayTells(notification)
  return did(function()
    ReceivedFromProxy(relay(), notification, {})
  end)
end

local function start(overrides, answer)
  return did(function()
    ShimPersistLand()
    H.load("humidity_alert", answer or H.LICENSED, overrides)
    H.reads(1)
  end)
end

--- A fresh driver in a resting room at 45 percent, with every fan off.
local function fresh(overrides)
  H.deviceVars = { [LIGHT_A] = { [1000] = "0" }, [LIGHT_B] = { [1000] = "0" }, [FAN] = { [1000] = "0" } }
  start()
  ExecuteCommand("Reset_Driver", { ["Are You Sure?"] = "Yes" })
  start(overrides)
  for _ = 1, 4 do
    report(45)
  end
end

T.section("humidity_alert fans: the Control Method decides which connection and selector exist")
fresh()
T.eq("None has no Relay connection", relay(), nil)
T.eq("and hides both selectors", { attribs["Light Switches"], attribs["Fan Controller"] }, { 1, 1 })
setProperty("Control Method", "Relay")
T.eq("Relay makes the connection", relay() ~= nil, true)
T.eq("and hides both selectors", { attribs["Light Switches"], attribs["Fan Controller"] }, { 1, 1 })
setProperty("Control Method", "Light Switch")
T.eq("Light Switch removes it", relay(), nil)
T.eq("and shows its selector only", { attribs["Light Switches"], attribs["Fan Controller"] }, { 0, 1 })
setProperty("Control Method", "Fan Speed Controller")
T.eq("Fan Speed Controller shows its selector only", { attribs["Light Switches"], attribs["Fan Controller"] }, { 1, 0 })
setProperty("Light Switches", "400,401")
setProperty("Control Method", "None")
T.eq("a hidden selector keeps its value", Properties["Light Switches"], "400,401")

T.section("humidity_alert fans: light switches go on with the alert and off with it")
fresh(LIGHTS)
T.eq("a start of the driver commands nothing", start(LIGHTS), "contact STATE_OPENED")
for _ = 1, 4 do
  report(45)
end
T.eq("a shower", report(75), "contact CLOSED; device 400 ON; device 401 ON; event Alert Started")
T.eq("the switches turning on is the driver's own doing", shows(LIGHT_A, true) .. shows(LIGHT_B, true), "")
T.eq("Clear Alert", command("Clear Alert"), "contact OPENED; device 400 OFF; device 401 OFF; event Alert Cleared")
T.eq("the switches turning off is too", shows(LIGHT_A, false) .. shows(LIGHT_B, false), "")

T.section("humidity_alert fans: a fan that already runs is not the alert's, and is left running")
fresh(LIGHTS)
shows(LIGHT_B, true)
T.eq("a shower turns on only the fan that is off", report(75), "contact CLOSED; device 400 ON; event Alert Started")
shows(LIGHT_A, true)
T.eq("the end turns off only that one", command("Clear Alert"), "contact OPENED; device 400 OFF; event Alert Cleared")

T.section("humidity_alert fans: a fan the alert turned on, switched off, ends the alert")
fresh(LIGHTS)
report(75)
shows(LIGHT_A, true)
shows(LIGHT_B, true)
minutes(20)
T.eq(
  "twenty minutes in, something turns one off: the alert ends and its other fan goes off",
  shows(LIGHT_A, false),
  "contact OPENED; device 401 OFF; event Alert Cleared"
)
T.eq("Alert", Properties["Alert"], "Clear")
shows(LIGHT_B, false)
T.eq("the room still wet does not start it again", report(76), "")

T.section("humidity_alert fans: a fan something else ran is turned back on once if it stops during an alert")
fresh(LIGHTS)
shows(LIGHT_B, true)
report(75)
shows(LIGHT_A, true)
T.eq("it stops mid-alert: the alert takes it over", shows(LIGHT_B, false), "device 401 ON")
T.eq("which is the driver's own doing", shows(LIGHT_B, true), "")
T.eq(
  "switched off again, it ends the alert like any fan of its own",
  shows(LIGHT_B, false),
  "contact OPENED; device 400 OFF; event Alert Cleared"
)

T.section("humidity_alert fans: an off sent as one alert ended that lands after the next began is put right")
fresh(LIGHTS)
command("Start Alert", { Minutes = "30" })
shows(LIGHT_A, true)
shows(LIGHT_B, true)
command("Clear Alert")
T.eq(
  "a new alert before the fans have stopped sends nothing",
  command("Start Alert", { Minutes = "30" }),
  "contact CLOSED; event Alert Started"
)
T.eq("the late off does not end it: the fan is turned on again", shows(LIGHT_A, false), "device 400 ON")
shows(LIGHT_A, true)
T.eq("and is the alert's own from there", shows(LIGHT_A, false), "contact OPENED; event Alert Cleared")

T.section("humidity_alert fans: with no alert the driver never commands a fan")
fresh(LIGHTS)
T.eq("something turns a fan on", shows(LIGHT_A, true), "")
minutes(20)
T.eq("and off", shows(LIGHT_A, false), "")

T.section("humidity_alert fans: a fan that stops lets outdoor air back, so the next small climb is not a shower")
fresh(LIGHTS)
shows(LIGHT_A, true)
minutes(5)
shows(LIGHT_A, false)
T.eq("a climb of 8 points after it stops", report(53), "")
fresh(LIGHTS)
T.eq(
  "the same climb with no fan having run",
  report(53),
  "contact CLOSED; device 400 ON; device 401 ON; event Alert Started"
)

T.section("humidity_alert fans: a restart keeps the alert's fans its own")
fresh(LIGHTS)
report(75)
shows(LIGHT_A, true)
shows(LIGHT_B, true)
T.eq("a restart commands nothing", start(LIGHTS), "contact STATE_CLOSED")
T.eq(
  "the end still turns them off",
  command("Clear Alert"),
  "contact OPENED; device 400 OFF; device 401 OFF; event Alert Cleared"
)

T.section("humidity_alert fans: a fan taken over is still the alert's after a restart")
fresh(LIGHTS)
shows(LIGHT_B, true)
report(75)
shows(LIGHT_A, true)
T.eq("it stops mid-alert: the alert takes it over", shows(LIGHT_B, false), "device 401 ON")
shows(LIGHT_B, true)
start(LIGHTS)
T.eq(
  "the alert's end turns off both",
  command("Clear Alert"),
  "contact OPENED; device 400 OFF; device 401 OFF; event Alert Cleared"
)

T.section("humidity_alert fans: a fan dropped from the selection while the driver was down is still turned off")
fresh(LIGHTS)
report(75)
shows(LIGHT_A, true)
shows(LIGHT_B, true)
T.eq(
  "a restart that finds Light Switches holding only one of them",
  start({ ["Control Method"] = "Light Switch", ["Light Switches"] = "400" }),
  "device 401 OFF; contact STATE_CLOSED"
)
T.eq(
  "the end turns off the one still selected",
  command("Clear Alert"),
  "contact OPENED; device 400 OFF; event Alert Cleared"
)
fresh(LIGHTS)
report(75)
shows(LIGHT_A, true)
shows(LIGHT_B, true)
T.eq(
  "a restart that finds Control Method None",
  start({ ["Control Method"] = "None", ["Light Switches"] = "400,401" }),
  "device 400 OFF; device 401 OFF; contact STATE_CLOSED"
)
T.eq("the end sends only the contact", command("Clear Alert"), "contact OPENED; event Alert Cleared")
fresh(RELAY)
report(75)
relayTells("CLOSED")
local relayId = tostring(relay())
local restart = H.run(function()
  ShimPersistLand()
  H.load("humidity_alert", H.LICENSED, { ["Control Method"] = "None" })
  H.reads(1)
end)
T.eq(
  "a restart that finds Control Method None opens the relay first",
  restart:find("proxy " .. relayId .. " OPEN", 1, true) ~= nil,
  true
)
T.eq("and then removes its connection", relay(), nil)
T.eq("the end sends only the contact", command("Clear Alert"), "contact OPENED; event Alert Cleared")

T.section(
  "humidity_alert fans: a fan dropped from the selection mid-alert is turned off, and its off does not end the alert"
)
for _, method in ipairs({ "None", "Light Switch" }) do
  fresh(RELAY)
  report(75)
  relayTells("CLOSED")
  local id = relay()
  -- A relay that answers its OPEN at once, as a relay on the same controller does.
  local send = SendToProxy
  SendToProxy = function(bindingId, name, params, ...)
    send(bindingId, name, params, ...)
    if bindingId == id and name == "OPEN" then
      ReceivedFromProxy(id, "OPENED", {})
    end
  end
  local changed = H.run(function()
    UpdateProperty("Control Method", method, true)
  end)
  SendToProxy = send
  T.eq("Relay to " .. method .. ": the relay is opened", changed:find("proxy " .. id .. " OPEN", 1, true) ~= nil, true)
  T.eq("and the alert carries on", Properties["Alert"], "Active (Rise)")
end

T.section("humidity_alert fans: an alert that ended while the controller was down turns its fans off at the first tick")
fresh(LIGHTS)
command("Start Alert", { Minutes = "5" })
shows(LIGHT_A, true)
shows(LIGHT_B, true)
ShimPersistLand()
clock = clock + 2 * 60 * 60
start(LIGHTS)
T.eq(
  "the first tick",
  did(function()
    minutes(1)
  end),
  "contact OPENED; device 400 OFF; device 401 OFF; event Alert Cleared"
)

T.section("humidity_alert fans: every other end turns the alert's fans off")
fresh(LIGHTS)
command("Start Alert", { Minutes = "30" })
T.eq(
  "Detection disabled",
  setProperty("Detection", "Disabled"),
  "contact OPENED; device 400 OFF; device 401 OFF; event Alert Cleared"
)
fresh(LIGHTS)
command("Start Alert", { Minutes = "30" })
T.eq(
  "the humidity input unbound",
  did(function()
    OnBindingChanged(humidityInput(), "HUMIDITY_VALUE", false, 600, 1)
  end),
  "contact OPENED; device 400 OFF; device 401 OFF; event Alert Cleared"
)
fresh(LIGHTS)
command("Start Alert", { Minutes = "30" })
T.eq(
  "Reset Driver",
  did(function()
    ExecuteCommand("Reset_Driver", { ["Are You Sure?"] = "Yes" })
  end),
  "contact OPENED; device 400 OFF; device 401 OFF; event Alert Cleared; contact STATE_OPENED"
)
T.eq("which returns the Control Method to None", Properties["Control Method"], "None")
fresh(LIGHTS)
start(LIGHTS, H.INVALID)
command("Start Alert", { Minutes = "60" })
T.eq(
  "a license lapse, with no events",
  did(function()
    H.reads(30)
  end),
  "contact OPENED; device 400 OFF; device 401 OFF"
)

T.section("humidity_alert fans: a switch taken out of the selection during an alert is turned off")
fresh(LIGHTS)
command("Start Alert", { Minutes = "30" })
shows(LIGHT_A, true)
shows(LIGHT_B, true)
T.eq("removed", setProperty("Light Switches", "400"), "device 401 OFF")
T.eq(
  "the end turns off the one that stayed",
  command("Clear Alert"),
  "contact OPENED; device 400 OFF; event Alert Cleared"
)

T.section("humidity_alert fans: a relay closes with the alert and opens with it")
fresh(RELAY)
T.eq("a shower", report(75), "contact CLOSED; relay CLOSE; event Alert Started")
T.eq("the relay closing is the driver's own doing", relayTells("CLOSED"), "")
T.eq("Clear Alert", command("Clear Alert"), "contact OPENED; relay OPEN; event Alert Cleared")
T.eq("the relay opening is too", relayTells("OPENED"), "")

T.section("humidity_alert fans: a relay opened during an alert ends it; a relay telling where it stands does not")
fresh(RELAY)
report(75)
relayTells("CLOSED")
T.eq("the relay says it is still closed", relayTells("STATE_CLOSED"), "")
T.eq("something opens it", relayTells("OPENED"), "contact OPENED; event Alert Cleared")
fresh(RELAY)
report(75)
relayTells("CLOSED")
T.eq("a relay telling that it stands open is not a change", relayTells("STATE_OPENED"), "")
T.eq("Alert", Properties["Alert"], "Active (Rise)")

T.section("humidity_alert fans: a relay something else closed is closed again once if it opens during an alert")
fresh(RELAY)
relayTells("CLOSED")
T.eq("a shower finds it closed and sends nothing", report(75), "contact CLOSED; event Alert Started")
T.eq("it opens mid-alert", relayTells("OPENED"), "relay CLOSE")
relayTells("CLOSED")
T.eq("opened again, it ends the alert", relayTells("OPENED"), "contact OPENED; event Alert Cleared")
T.eq("with no alert, a relay something else closed is left alone", relayTells("CLOSED") .. relayTells("OPENED"), "")

T.section("humidity_alert fans: a fan speed controller goes on with the alert and off with it")
fresh(CONTROLLER)
T.eq("a shower", report(75), "contact CLOSED; device 500 ON; event Alert Started")
shows(FAN, true)
T.eq("Clear Alert", command("Clear Alert"), "contact OPENED; device 500 OFF; event Alert Cleared")
shows(FAN, false)
command("Start Alert", { Minutes = "30" })
shows(FAN, true)
T.eq("switched off during an alert, it ends it", shows(FAN, false), "contact OPENED; event Alert Cleared")

if H.gate and H.gate._timer then
  H.gate._timer:Cancel()
end
T.finish()
