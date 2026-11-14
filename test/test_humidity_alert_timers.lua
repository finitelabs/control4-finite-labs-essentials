-- The Humidity Alert's Timer control method: an alert sets the selected Control4 timers to On, which runs with no
-- countdown, and to Off when it ends. A timer counting down when an alert starts is set to On and is the alert's,
-- since its countdown would turn the device off mid-alert.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_humidity_alert_timers.lua

-- Each timer is a driver with a proxy; the selector holds the proxy, and commands and variables go to the driver.
local SHOWER, SHOWER_PROXY, TUB, TUB_PROXY = 809, 810, 813, 814

require("c4_shim")
ShimSetDevices({
  [1] = { deviceName = "Bathroom", driverFileName = "roomdevice.c4i" },
  [SHOWER] = {
    deviceName = "Extract Fan",
    driverFileName = "timer_extractfan.c4z",
    roomId = "1",
    roomName = "Bathroom",
  },
  [SHOWER_PROXY] = {
    deviceName = "Shower Fan",
    driverFileName = "uibutton.c4i",
    roomId = "1",
    roomName = "Bathroom",
    protocol = { [SHOWER] = { driverFileName = "timer_extractfan.c4z" } },
  },
  [TUB] = { deviceName = "Extract Fan", driverFileName = "timer_extractfan.c4z", roomId = "1", roomName = "Bathroom" },
  [TUB_PROXY] = {
    deviceName = "Tub Fan",
    driverFileName = "uibutton.c4i",
    roomId = "1",
    roomName = "Bathroom",
    protocol = { [TUB] = { driverFileName = "timer_extractfan.c4z" } },
  },
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
      .. "<items><item>light_v2.c4i</item></items></property>"
      .. "<property><name>Fan Controller</name><type>DEVICE_SELECTOR</type>"
      .. "<items><item>fan.c4i</item></items></property>"
      .. "<property><name>Timers</name><type>DEVICE_SELECTOR</type>"
      .. "<items><item>timer_extractfan.c4z</item><item>timer_relay.c4z</item></items></property>"
  end
  return shimGetDeviceData(self, deviceId, key)
end

local TIMERS = { ["Control Method"] = "Timer", ["Timers"] = "810,814" }

local function humidityInput()
  return bindings:getDynamicBinding("Input", "humidity").bindingId
end

local function contact()
  return bindings:getDynamicBinding("Output", "contact").bindingId
end

--- What `fn` tells the contact and the devices, and which events it fires, joined by "; ".
local function did(fn)
  local effects = H.run(fn)
  local out = {}
  for line in (effects .. "; "):gmatch("(.-); ") do
    local id, command = line:match("^proxy (%d+) (.+)$")
    if id and id == tostring(contact()) then
      out[#out + 1] = "contact " .. command
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

--- A timer's variables: the minutes it was set to (-1 for On), the minutes left, and 1 while it runs.
local function timerVars(runtime, countdown, running)
  return { [1001] = tostring(runtime), [1002] = tostring(countdown), [1003] = running and "1" or "0" }
end

--- A timer's variables change, one at a time in the order the timer driver writes them, and then settle.
local function timerShows(deviceId, runtime, countdown, running)
  return did(function()
    local vars = timerVars(runtime, countdown, running)
    H.deviceVars[deviceId] = H.deviceVars[deviceId] or {}
    for _, var in ipairs({ 1001, 1002, 1003 }) do
      H.deviceVars[deviceId][var] = vars[var]
      OnWatchedVariableChanged(deviceId, var, vars[var])
    end
    ShimFireTimers()
  end)
end

local function permanent(deviceId)
  return timerShows(deviceId, -1, 0, true)
end

local function off(deviceId)
  return timerShows(deviceId, -1, 0, false)
end

local function start(overrides, answer)
  return did(function()
    ShimPersistLand()
    H.load("humidity_alert", answer or H.LICENSED, overrides)
    H.reads(1)
  end)
end

--- A fresh driver in a resting room at 45 percent, with both timers off.
local function fresh(overrides)
  H.deviceVars = { [SHOWER] = timerVars(0, 0, false), [TUB] = timerVars(0, 0, false) }
  start()
  ExecuteCommand("Reset_Driver", { ["Are You Sure?"] = "Yes" })
  start(overrides)
  for _ = 1, 4 do
    report(45)
  end
end

T.section("humidity_alert timers: Timer shows only the Timers selector")
fresh()
T.eq("None hides it", attribs["Timers"], 1)
setProperty("Control Method", "Timer")
T.eq(
  "Timer shows it and hides the others",
  { attribs["Timers"], attribs["Light Switches"], attribs["Fan Controller"] },
  { 0, 1, 1 }
)
setProperty("Control Method", "Light Switch")
T.eq("another method hides it", attribs["Timers"], 1)

T.section("humidity_alert timers: an alert sets each timer's driver to On, and to Off when it ends")
fresh(TIMERS)
T.eq("a start of the driver commands nothing", start(TIMERS), "contact STATE_OPENED")
for _ = 1, 4 do
  report(45)
end
T.eq(
  "a shower",
  report(75),
  "contact CLOSED; device 809 SetCountdown On; device 813 SetCountdown On; event Alert Started"
)
T.eq("the timers running on is the driver's own doing", permanent(SHOWER) .. permanent(TUB), "")
minutes(30)
T.eq("with no countdown, nothing turns them off", Properties["Alert"], "Active (Rise)")
T.eq(
  "Clear Alert",
  command("Clear Alert"),
  "contact OPENED; device 809 SetCountdown Off; device 813 SetCountdown Off; event Alert Cleared"
)
T.eq("the timers stopping is too", off(SHOWER) .. off(TUB), "")

T.section("humidity_alert timers: a selector holding a timer's driver rather than its proxy works the same")
fresh({ ["Control Method"] = "Timer", ["Timers"] = "809" })
T.eq("a shower", report(75), "contact CLOSED; device 809 SetCountdown On; event Alert Started")

T.section("humidity_alert timers: a timer counting down when an alert starts is set to On and is the alert's")
fresh(TIMERS)
timerShows(SHOWER, 15, 15, true)
T.eq(
  "a shower sets both to On",
  report(75),
  "contact CLOSED; device 809 SetCountdown On; device 813 SetCountdown On; event Alert Started"
)
T.eq("the countdown giving way to On is not a stop", permanent(SHOWER) .. permanent(TUB), "")
T.eq(
  "the end turns both off",
  command("Clear Alert"),
  "contact OPENED; device 809 SetCountdown Off; device 813 SetCountdown Off; event Alert Cleared"
)

T.section("humidity_alert timers: a timer already set to On is not the alert's, and is left running")
fresh(TIMERS)
permanent(TUB)
T.eq("a shower sets only the other", report(75), "contact CLOSED; device 809 SetCountdown On; event Alert Started")
permanent(SHOWER)
T.eq(
  "the end turns off only that one",
  command("Clear Alert"),
  "contact OPENED; device 809 SetCountdown Off; event Alert Cleared"
)

T.section("humidity_alert timers: a timer the alert set to On, switched off, ends the alert")
fresh(TIMERS)
report(75)
permanent(SHOWER)
permanent(TUB)
T.eq(
  "the wall switch turns one off, and its timer stops",
  off(SHOWER),
  "contact OPENED; device 813 SetCountdown Off; event Alert Cleared"
)

T.section("humidity_alert timers: a countdown at 0 has ended, though the timer still shows itself running")
fresh(TIMERS)
permanent(TUB)
report(75)
permanent(SHOWER)
T.eq("someone switches it from On to a countdown: not a stop", timerShows(TUB, 15, 15, true), "")
T.eq(
  "its countdown runs out mid-alert: the alert sets it to On",
  timerShows(TUB, 15, 0, true),
  "device 813 SetCountdown On"
)
permanent(TUB)
T.eq(
  "and it is the alert's from there",
  command("Clear Alert"),
  "contact OPENED; device 809 SetCountdown Off; device 813 SetCountdown Off; event Alert Cleared"
)

T.section("humidity_alert timers: a restart keeps the alert's timers its own")
fresh(TIMERS)
report(75)
permanent(SHOWER)
permanent(TUB)
T.eq("a restart commands nothing", start(TIMERS), "contact STATE_CLOSED")
T.eq(
  "the end still sets them to Off",
  command("Clear Alert"),
  "contact OPENED; device 809 SetCountdown Off; device 813 SetCountdown Off; event Alert Cleared"
)

T.section("humidity_alert timers: a timer dropped from the selection is set to Off")
fresh(TIMERS)
report(75)
permanent(SHOWER)
permanent(TUB)
T.eq("mid-alert", setProperty("Timers", "810"), "device 813 SetCountdown Off")
T.eq("and its stopping does not end the alert", off(TUB), "")
T.eq("Alert", Properties["Alert"], "Active (Rise)")
fresh(TIMERS)
report(75)
permanent(SHOWER)
permanent(TUB)
T.eq(
  "while the driver was down",
  start({ ["Control Method"] = "None", ["Timers"] = "810,814" }),
  "device 809 SetCountdown Off; device 813 SetCountdown Off; contact STATE_CLOSED"
)

if H.gate and H.gate._timer then
  H.gate._timer:Cancel()
end
T.finish()
