--- Humidity Alert Driver
--#ifndef DRIVERCENTRAL
DRIVER_GITHUB_REPO = "finitelabs/control4-finite-labs-essentials"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local persist = require("lib.persist")
local constants = require("constants")
local Detector = require("humidity.detector")
local Psychro = require("humidity.psychro")
local updateSettings = require("lib.update-settings")
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

--- Whether the driver may act: a DriverCentral build stops while it has no license, and an OSS build never does.
--- @return boolean
local function licensed()
  local ok = true
  --#ifdef DRIVERCENTRAL
  ok = drivercentral:licensed()
  --#endif
  return ok
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Namespaces for dynamic bindings
local NS_INPUT = "Input"
local NS_OUTPUT = "Output"

--- Binding keys
local INPUT_HUMIDITY = "humidity"
local INPUT_TEMPERATURE = "temperature"
local OUTPUT_CONTACT = "contact"

--- Persist key for the detector's state and what the driver keeps beside it
local PERSIST_STATE = "AlertState"

--- Static event names (driver.xml ids 1 to 4)
local EVENT_STARTED = "Alert Started"
local EVENT_CLEARED = "Alert Cleared"
local EVENT_TIMED_OUT = "Alert Timed Out"
local EVENT_STALE = "Humidity Sensor Stale"

--- Variable names, in the order they are created
local VAR_ACTIVE = "Alert Active"
local VAR_REASON = "Alert Reason"
local VAR_RISE = "Humidity Rise"

--- A humidity report waits this long for its sensor's temperature report.
--- @type number
local PAIR_WAIT = 3 * ONE_SECOND

--- While nothing changes, the stored state is written at most this often, in seconds.
--- @type number
local SAVE_INTERVAL = 5 * 60

--- Properties each detection mode does not use.
--- @type table<string, string[]>
local UNUSED_BY_MODE = {
  [Detector.Mode.RISE] = { "Alert Above", "Clear Below" },
  [Detector.Mode.THRESHOLD] = { "Rise Amount", "Recovery" },
  [Detector.Mode.RISE_OR_THRESHOLD] = {},
}

--- Properties any detection mode may hide.
--- @type string[]
local MODE_PROPERTIES = { "Rise Amount", "Recovery", "Alert Above", "Clear Below" }

--- The settings Reset Driver returns to their defaults.
--- @type table<string, string>
local SETTING_DEFAULTS = {
  ["Detection"] = "Enabled",
  ["Detection Mode"] = Detector.Mode.RISE,
  ["Rise Amount"] = "6",
  ["Recovery"] = "50",
  ["Alert Above"] = "80",
  ["Clear Below"] = "70",
  ["Run-On Time"] = "10",
  ["Maximum Alert Time"] = "60",
  ["Sensor Timeout"] = "24",
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

--- @class AlertRecord
--- @field state HumidityState The detector's state, stored without its history.
--- @field rawPeak number|nil The highest humidity the sensor reported in this alert.

--- The detector's state.
--- @type HumidityState
local state = Detector.newState()

--- The highest humidity the sensor reported in the current alert.
--- @type number|nil
local rawPeak = nil

--- The newest temperature report, in degrees Celsius, and when it came.
--- @type number|nil
local lastCelsius = nil
--- @type number|nil
local lastCelsiusTime = nil

--- A humidity report waiting to be paired with a temperature.
--- @type number|nil
local pendingHumidity = nil

--- The state last told to the contact output (nil until one is told).
--- @type boolean|nil
local lastContactState = nil

--- When the state was last written, in seconds.
--- @type number
local lastSaved = 0

--------------------------------------------------------------------------------
-- Settings and Storage
--------------------------------------------------------------------------------

--- The time, in seconds.
--- @return number now
local function now()
  return os.time()
end

--- The detector's settings as the properties give them.
--- @return HumiditySettings settings
local function settings()
  return {
    enabled = Properties["Detection"] ~= "Disabled",
    mode = Properties["Detection Mode"] or Detector.Mode.RISE,
    riseAmount = tonumber(Properties["Rise Amount"]) or 6,
    recoveryPercent = tonumber(Properties["Recovery"]) or 50,
    alertAbove = tonumber(Properties["Alert Above"]) or 80,
    clearBelow = tonumber(Properties["Clear Below"]) or 70,
    runOnSeconds = (tonumber(Properties["Run-On Time"]) or 10) * 60,
    maxAlertSeconds = (tonumber(Properties["Maximum Alert Time"]) or 60) * 60,
    sensorTimeoutSeconds = (tonumber(Properties["Sensor Timeout"]) or 24) * 60 * 60,
  }
end

--- Write the state. The history is working memory and is learned again after a start.
local function saveState()
  local stored = {}
  for key, value in pairs(state) do
    if key ~= "history" then
      stored[key] = value
    end
  end
  persist:set(PERSIST_STATE, { state = stored, rawPeak = rawPeak })
  lastSaved = now()
end

--------------------------------------------------------------------------------
-- Outputs
--------------------------------------------------------------------------------

--- Tell the contact output the alert's state, when it does not show it yet.
--- @param asState? boolean Tell it without a programming event, as at a start or a bind.
local function tellContact(asState)
  local binding = bindings:getDynamicBinding(NS_OUTPUT, OUTPUT_CONTACT)
  if binding == nil or state.active == lastContactState then
    return
  end
  lastContactState = state.active
  local command
  if gInitialized and not asState then
    command = state.active and "CLOSED" or "OPENED"
  else
    command = state.active and "STATE_CLOSED" or "STATE_OPENED"
  end
  SendToProxy(binding.bindingId, command, {}, "NOTIFY")
end

--- Format a humidity for a status property.
--- @param rh number|nil
--- @return string text
local function humidityText(rh)
  return rh ~= nil and (tostring(round(rh, 1)) .. " %") or ""
end

--- Format a temperature for a status property, in both scales.
--- @param celsius number|nil
--- @return string text
local function temperatureText(celsius)
  if celsius == nil then
    return ""
  end
  return tostring(round(celsius, 1)) .. " °C / " .. tostring(c2f(celsius)) .. " °F"
end

--- Show the alert and the last readings in the status properties and variables.
local function showStatus()
  local alert = "Clear"
  if state.active then
    alert = "Active (" .. state.reason .. ")"
  elseif Properties["Detection"] == "Disabled" then
    alert = "Clear (detection disabled)"
  elseif state.stale then
    alert = "Clear (humidity sensor stale)"
  end
  UpdateProperty("Alert", alert, true)
  UpdateProperty("Humidity", humidityText(state.lastRh), true)
  UpdateProperty("Temperature", temperatureText(state.lastC), true)
  local dewPoint = nil
  if state.lastRh ~= nil and state.lastC ~= nil then
    dewPoint = Psychro.dewPoint(state.lastRh, state.lastC)
  end
  UpdateProperty("Dew Point", temperatureText(dewPoint), true)
  UpdateProperty("Start Humidity", humidityText(state.active and state.startLevel or nil), true)
  UpdateProperty("Peak Humidity", humidityText(state.active and rawPeak or nil), true)

  local rise = 0
  if state.active and state.startLevel ~= nil and state.lastRh ~= nil then
    rise = math.max(0, round(state.lastRh - state.startLevel, 1))
  end
  values:update(VAR_ACTIVE, state.active, "BOOL")
  values:update(VAR_REASON, state.reason, "STRING")
  values:update(VAR_RISE, rise, "NUMBER")
end

--- Act on what the detector changed: the contact, the events, the status and the stored state.
--- @param changes HumidityChange[] What a detector call changed, in order.
--- @param quiet? boolean Fire no events: the driver itself is stopping.
local function apply(changes, quiet)
  for _, change in ipairs(changes) do
    if change.type == Detector.Change.STARTED then
      rawPeak = state.lastRh
      tellContact()
      C4:FireEvent(EVENT_STARTED)
    elseif change.type == Detector.Change.CLEARED then
      rawPeak = nil
      tellContact()
      if not quiet then
        C4:FireEvent(EVENT_CLEARED)
      end
    elseif change.type == Detector.Change.TIMED_OUT then
      if not quiet then
        C4:FireEvent(EVENT_TIMED_OUT)
      end
    elseif change.type == Detector.Change.STALE then
      C4:FireEvent(EVENT_STALE)
    end
  end
  showStatus()
  if #changes > 0 or now() - lastSaved >= SAVE_INTERVAL then
    saveState()
  end
end

--- Let time pass in the detector, and act on what that changes.
local function evaluate()
  if not gInitialized or not licensed() then
    return
  end
  apply(Detector.tick(state, settings(), now()))
end

--- End the alert now, whatever started it.
--- @param quiet? boolean Fire no events: the driver itself is stopping.
local function endAlert(quiet)
  apply(Detector.clear(state, settings(), now()), quiet)
end

--------------------------------------------------------------------------------
-- Readings
--------------------------------------------------------------------------------

--- The newest temperature, unless it is older than the sensor may stay silent.
--- @return number|nil celsius
local function freshCelsius()
  if lastCelsius == nil or lastCelsiusTime == nil then
    return nil
  end
  local timeout = settings().sensorTimeoutSeconds
  if timeout > 0 and now() - lastCelsiusTime > timeout then
    return nil
  end
  return lastCelsius
end

--- Hand the waiting humidity report to the detector, with the newest temperature.
local function takeSample()
  local rh = pendingHumidity
  pendingHumidity = nil
  if rh == nil or not licensed() then
    return
  end
  local changes = Detector.sample(state, settings(), now(), rh, freshCelsius())
  if state.active and state.lastRh ~= nil and (rawPeak == nil or state.lastRh > rawPeak) then
    rawPeak = state.lastRh
  end
  apply(changes)
end

--- A humidity report. It waits a moment so the same sensor's temperature report joins it.
--- @param rh number
local function onHumidity(rh)
  -- SetTimer restarts a timer of the same name, so only the first waiting report arms it.
  local waiting = pendingHumidity ~= nil
  pendingHumidity = rh
  if not waiting then
    SetTimer("PairSample", PAIR_WAIT, takeSample)
  end
end

--- A temperature report. It never makes a sample of its own.
--- @param celsius number
local function onTemperature(celsius)
  lastCelsius = celsius
  lastCelsiusTime = now()
end

--------------------------------------------------------------------------------
-- Connections
--------------------------------------------------------------------------------

--- Register the handlers of the humidity input.
--- @param binding Binding
local function registerHumidityHandlers(binding)
  RFP[binding.bindingId] = function(idBinding, strCommand, tParams, _args)
    log:trace("RFP[%s](%s, %s, %s)", binding.bindingId, idBinding, strCommand, tParams)
    if strCommand == "VALUE_CHANGED" then
      local value = tofinite(Select(tParams, "VALUE"))
      if value then
        onHumidity(value)
      end
    end
  end

  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    -- Another sensor reads a few points apart, so its first report only sets a baseline.
    Detector.reseed(state)
    pendingHumidity = nil
    CancelTimer("PairSample")
    if not bIsBound and state.active and licensed() then
      endAlert()
    end
    if bIsBound then
      SendToProxy(binding.bindingId, "GET_VALUE", {})
    end
  end
end

--- Register the handlers of the temperature input.
--- @param binding Binding
local function registerTemperatureHandlers(binding)
  RFP[binding.bindingId] = function(idBinding, strCommand, tParams, _args)
    log:trace("RFP[%s](%s, %s, %s)", binding.bindingId, idBinding, strCommand, tParams)
    if strCommand == "VALUE_CHANGED" then
      local value = CelsiusFromParams(tParams, "CELSIUS")
      if value then
        onTemperature(value)
      end
    end
  end

  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    lastCelsius = nil
    lastCelsiusTime = nil
    if bIsBound then
      SendToProxy(binding.bindingId, "GET_VALUE", {})
    end
  end
end

--- Register the handler of the contact output.
--- @param binding Binding
local function registerContactHandlers(binding)
  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    lastContactState = nil
    if bIsBound and licensed() then
      tellContact(true)
    end
  end
end

--- Make the connections the settings call for, in one fixed order, and wire their handlers.
local function reconcileConnections()
  local humidity =
    bindings:getOrAddDynamicBinding(NS_INPUT, INPUT_HUMIDITY, "CONTROL", false, "Humidity", "HUMIDITY_VALUE")
  if humidity then
    registerHumidityHandlers(humidity)
  end
  local temperature =
    bindings:getOrAddDynamicBinding(NS_INPUT, INPUT_TEMPERATURE, "CONTROL", false, "Temperature", "TEMPERATURE_VALUE")
  if temperature then
    registerTemperatureHandlers(temperature)
  end
  local contact =
    bindings:getOrAddDynamicBinding(NS_OUTPUT, OUTPUT_CONTACT, "PROXY", true, "Alert Contact", "CONTACT_SENSOR")
  if contact then
    registerContactHandlers(contact)
  end
end

--- Ask each input for its value now: a sensor that reports only changes may stay silent for hours.
local function requestReadings()
  for _, key in ipairs({ INPUT_HUMIDITY, INPUT_TEMPERATURE }) do
    local binding = bindings:getDynamicBinding(NS_INPUT, key)
    if binding then
      SendToProxy(binding.bindingId, "GET_VALUE", {})
    end
  end
end

--- Show the detection properties the mode uses and hide the rest. A hidden one keeps its value.
local function showModeProperties()
  local hidden = {}
  for _, name in ipairs(UNUSED_BY_MODE[Properties["Detection Mode"]] or {}) do
    hidden[name] = true
  end
  for _, name in ipairs(MODE_PROPERTIES) do
    C4:SetPropertyAttribs(name, hidden[name] and constants.HIDE_PROPERTY or constants.SHOW_PROPERTY)
  end
end

--- Create the variables, in their fixed order, with what the state holds.
local function createVariables()
  values:update(VAR_ACTIVE, state.active, "BOOL")
  values:update(VAR_REASON, state.reason, "STRING")
  values:update(VAR_RISE, 0, "NUMBER")
end

--#ifndef DRIVERCENTRAL
--- Get all device IDs for instances of this driver, sorted ascending.
--- @return integer[]
local function getDriverIds()
  local drivers = C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}
  local ids = {}
  for id, _ in pairs(drivers) do
    table.insert(ids, tointeger(id))
  end
  table.sort(ids)
  return ids
end
--#endif

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  drivercentral:startClient()
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  -- Restore persisted state
  values:restoreValues()
  bindings:restoreBindings()

  --- @type AlertRecord|nil
  local record = persist:get(PERSIST_STATE)
  if type(record) == "table" and type(record.state) == "table" then
    state = record.state
    rawPeak = tonumber(record.rawPeak)
  else
    state = Detector.newState()
    rawPeak = nil
  end
  -- An alert that outlasted the downtime is restored as it was and ended by the first tick.
  Detector.restart(state, now())
  lastContactState = nil
  pendingHumidity = nil
  lastCelsius = nil
  lastCelsiusTime = nil
  lastSaved = now()

  createVariables()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")

  if not CheckMinimumVersion("Driver Status") then
    return
  end

  reconcileConnections()

  -- Fire OnPropertyChanged for all properties
  -- The router runs each handler in its own xpcall and reports its error, so the rest still run.
  for p, _ in pairs(Properties) do
    OnPropertyChanged(p)
  end

  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    -- Recompute leader each cycle in case the previous leader was removed
    local isLeaderInstance = Select(getDriverIds(), 1) == C4:GetDeviceID()
    if isLeaderInstance and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      UpdateDrivers()
    end
  end, true)
  --#endif

  SetTimer("Tick", ONE_MINUTE, evaluate, true)

  if licensed() then
    tellContact(true)
    showStatus()
  end
  gInitialized = true
  UpdateProperty("Driver Status", "Ready")
  requestReadings()

  --#ifdef DRIVERCENTRAL
  drivercentral:startGate(function(active)
    if not active then
      -- A device that programming turned on must be turned off: end the alert, and say nothing else.
      if state.active then
        endAlert(true)
      end
      UpdateProperty("Driver Status", drivercentral.UNLICENSED_STATUS)
      return
    end
    UpdateProperty("Driver Status", "Ready")
    Detector.reseed(state)
    tellContact(true)
    showStatus()
    requestReadings()
  end)
  --#endif
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

--------------------------------------------------------------------------------
-- OPC Handlers
--------------------------------------------------------------------------------

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
    return
  end
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    UpdateProperty("Log Level", "3 - Info", true)
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
  OnPropertyChanged("Log Level")
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
end

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  if not gInitialized then
    return
  end
  updateSettings:share("Automatic Updates", propertyValue, { "humidity_alert.c4z" })
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if not gInitialized then
    return
  end
  updateSettings:share("Update Channel", propertyValue, { "humidity_alert.c4z" })
end
--#endif

--- An update setting changed on another item.
function EC.SET_UPDATE_SETTING(params)
  log:trace("EC.SET_UPDATE_SETTING(%s)", params)
  updateSettings:take(params)
end

--#ifdef DRIVERCENTRAL
--- Not logged: the value is the code.
function OPC.Support_Code(propertyValue)
  supportCode:enter(propertyValue)
end

--- Turns Cloud Monitoring on or off.
--- @param propertyValue string
function OPC.Cloud_Monitoring(propertyValue)
  diagnostics:setEnabled(propertyValue == "Enabled")
end

--- Prints a diagnostics report, and sends it while Cloud Monitoring is on.
function EC.DiagnosticsSnapshot()
  diagnostics:dumpSnapshot()
end
--#endif

function OPC.Detection(propertyValue)
  log:trace("OPC.Detection('%s')", propertyValue)
  evaluate()
end

function OPC.Detection_Mode(propertyValue)
  log:trace("OPC.Detection_Mode('%s')", propertyValue)
  showModeProperties()
  evaluate()
end

function OPC.Rise_Amount(propertyValue)
  log:trace("OPC.Rise_Amount('%s')", propertyValue)
  evaluate()
end

function OPC.Recovery(propertyValue)
  log:trace("OPC.Recovery('%s')", propertyValue)
  evaluate()
end

function OPC.Alert_Above(propertyValue)
  log:trace("OPC.Alert_Above('%s')", propertyValue)
  evaluate()
end

function OPC.Clear_Below(propertyValue)
  log:trace("OPC.Clear_Below('%s')", propertyValue)
  evaluate()
end

OPC["Run-On_Time"] = function(propertyValue)
  log:trace("OPC.Run-On_Time('%s')", propertyValue)
  evaluate()
end

function OPC.Maximum_Alert_Time(propertyValue)
  log:trace("OPC.Maximum_Alert_Time('%s')", propertyValue)
  evaluate()
end

function OPC.Sensor_Timeout(propertyValue)
  log:trace("OPC.Sensor_Timeout('%s')", propertyValue)
  evaluate()
end

--------------------------------------------------------------------------------
-- TC Handlers
--------------------------------------------------------------------------------

--- Test a two-valued conditional against a state.
--- @param tParams table The conditional's parameters.
--- @param trueText string The text driver.xml gives the true state.
--- @param actual boolean The state now.
--- @return boolean result
local function testState(tParams, trueText, actual)
  local test = Select(tParams, "VALUE") == trueText
  if Select(tParams, "LOGIC") == "NOT_EQUAL" then
    return test ~= actual
  end
  return test == actual
end

function TC.ALERT_ACTIVE(_strConditionName, tParams)
  return testState(tParams, "Active", state.active)
end

function TC.HUMIDITY_SENSOR_STALE(_strConditionName, tParams)
  return testState(tParams, "Stale", state.stale)
end

--------------------------------------------------------------------------------
-- EC Handlers
--------------------------------------------------------------------------------

--- Start an alert by command, for a number of minutes.
function EC.Start_Alert(params)
  log:trace("EC.Start_Alert(%s)", params)
  if not gInitialized or not licensed() then
    return
  end
  local minutes = tonumber(Select(params, "Minutes")) or 20
  apply(Detector.startManual(state, settings(), now(), minutes * 60))
end

--- End the alert now.
function EC.Clear_Alert(params)
  log:trace("EC.Clear_Alert(%s)", params)
  if not gInitialized or not licensed() then
    return
  end
  endAlert()
end

--- Turn detection on: the Detection property's twin.
function EC.Enable_Detection(params)
  log:trace("EC.Enable_Detection(%s)", params)
  UpdateProperty("Detection", "Enabled", true)
end

--- Turn detection off: the Detection property's twin.
function EC.Disable_Detection(params)
  log:trace("EC.Disable_Detection(%s)", params)
  UpdateProperty("Detection", "Disabled", true)
end

--- Reset driver to initial state
function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")

  -- The contact goes with its binding, so a device an alert turned on is turned off first.
  if state.active and licensed() then
    endAlert()
  end
  CancelTimer("PairSample")

  -- Reset all dynamic state
  bindings:reset()
  values:reset()
  persist:set(PERSIST_STATE, nil)
  state = Detector.newState()
  rawPeak = nil
  pendingHumidity = nil
  lastCelsius = nil
  lastCelsiusTime = nil
  lastContactState = nil

  -- Reset properties to defaults
  local resetValues = GetPropertyResetValues({})
  for propName, defaultValue in pairs(resetValues) do
    UpdateProperty(propName, defaultValue, true)
  end
  for propName, defaultValue in pairs(SETTING_DEFAULTS) do
    UpdateProperty(propName, defaultValue)
  end
  --#ifdef DRIVERCENTRAL
  UpdateProperty("Cloud Monitoring", "Enabled", true)
  --#endif

  reconcileConnections()
  createVariables()
  showModeProperties()
  tellContact(true)
  showStatus()
end

--#ifndef DRIVERCENTRAL
--- Action: Update Drivers
function EC.Update_Drivers()
  log:trace("EC.Update_Drivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end

--- Update the driver from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if the driver is up to date (optional).
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, { "humidity_alert.c4z" }, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if not IsEmpty(updatedDrivers) then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      else
        log:info("No driver updates available")
      end
    end, function(error)
      log:error("An error occurred updating drivers: %s", error)
    end)
end
--#endif
