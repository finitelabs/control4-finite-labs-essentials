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
local INPUT_REFERENCE_HUMIDITY = "reference_humidity"
local INPUT_REFERENCE_TEMPERATURE = "reference_temperature"
local OUTPUT_CONTACT = "contact"
local OUTPUT_FAN_RELAY = "fan_relay"

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

--- Control Method choices
local METHOD_NONE = "None"
local METHOD_RELAY = "Relay"
local METHOD_LIGHT = "Light Switch"
local METHOD_FAN = "Fan Speed Controller"

--- The key of the one fan a relay connection drives.
local FAN_RELAY_KEY = "relay"

--- The variable a light or a fan controller reports its on state in.
--- @type integer
local VAR_DEVICE_ON = 1000

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
  ["Reference Sensor"] = "Disabled",
  ["Run-On Time"] = "10",
  ["Maximum Alert Time"] = "60",
  ["Sensor Timeout"] = "24",
  ["Control Method"] = METHOD_NONE,
  ["Light Switches"] = "",
  ["Fan Controller"] = "",
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

--- @class AlertRecord
--- @field state HumidityState The detector's state, stored without its history.
--- @field rawPeak number|nil The highest humidity the sensor reported in this alert.
--- @field owned table<string, boolean>|nil The fans this alert turned on.

--- @class Fan
--- @field deviceId integer|nil The light or fan controller, nil for the relay connection.
--- @field name string What the log calls it.
--- @field on boolean|nil Whether it runs, nil when not known yet.

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

--- The reference sensor's newest temperature report, in degrees Celsius, and when it came.
--- @type number|nil
local referenceCelsius = nil
--- @type number|nil
local referenceCelsiusTime = nil

--- A reference humidity report waiting to be paired with a temperature.
--- @type number|nil
local pendingReference = nil

--- The state last told to the contact output (nil until one is told).
--- @type boolean|nil
local lastContactState = nil

--- When the state was last written, in seconds.
--- @type number
local lastSaved = 0

--- The fans the Control Method selects, by key: "relay", or a device id as text.
--- @type table<string, Fan>
local fans = {}

--- The fans the current alert turned on. Only these are turned off when it ends.
--- @type table<string, boolean>
local owned = {}

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
    if key ~= "history" and key ~= "refHistory" then
      stored[key] = value
    end
  end
  persist:set(PERSIST_STATE, { state = stored, rawPeak = rawPeak, owned = owned })
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

--------------------------------------------------------------------------------
-- Fans
--------------------------------------------------------------------------------

--- End the alert now, whatever started it. Defined with the alert handling below.
--- @type fun(quiet?: boolean)
local endAlert

--- The selected fans' keys, sorted so commands go out in one order.
--- @return string[] keys
local function fanKeys()
  local keys = TableKeys(fans)
  table.sort(keys)
  return keys
end

--- @return boolean running True when any selected fan is known to run.
local function anyFanOn()
  for _, fan in pairs(fans) do
    if fan.on then
      return true
    end
  end
  return false
end

--- Send a fan its on or off command.
--- @param fan Fan
--- @param on boolean
local function sendFan(fan, on)
  log:info("Turning %s %s", fan.name, on and "on" or "off")
  if fan.deviceId ~= nil then
    SendToDevice(fan.deviceId, on and "ON" or "OFF", {})
    return
  end
  local binding = bindings:getDynamicBinding(NS_OUTPUT, OUTPUT_FAN_RELAY)
  if binding then
    SendToProxy(binding.bindingId, on and "CLOSE" or "OPEN", {})
  end
end

--- Command a selected fan.
--- @param key string
--- @param on boolean
local function commandFan(key, on)
  local fan = fans[key]
  if fan ~= nil then
    sendFan(fan, on)
  end
end

--- An alert started: turn on every selected fan that is off. Those are the alert's own.
local function engageFans()
  for _, key in ipairs(fanKeys()) do
    if not fans[key].on and not owned[key] then
      owned[key] = true
      commandFan(key, true)
    end
  end
end

--- An alert ended: turn off the fans it turned on, and no others.
local function releaseFans()
  for _, key in ipairs(fanKeys()) do
    if owned[key] then
      commandFan(key, false)
    end
  end
  owned = {}
end

--- A selected fan reported its state.
--- @param key string
--- @param on boolean
--- @param isChange boolean False for a report of where it stands, as at a start or a bind.
local function onFanState(key, on, isChange)
  local fan = fans[key]
  if fan == nil then
    return
  end
  local was = fan.on
  fan.on = on
  if was == on then
    return
  end
  if on then
    Detector.fanStarted(state, now())
    return
  end

  -- Outdoor air leaks back onto a sensor in the fan's housing, whoever stopped the fan.
  Detector.fanStopped(state, now())
  if anyFanOn() then
    Detector.fanStarted(state, now())
  end
  if not isChange or was == nil or not gInitialized or not licensed() or not state.active then
    return
  end
  if owned[key] then
    log:info("%s was turned off during the alert; ending the alert", fan.name)
    owned[key] = nil
    endAlert()
  else
    -- Whatever ran this fan has finished with it, or the driver's own off from the last alert landed
    -- late: the alert still needs it. It is the alert's from here, so a second off ends the alert.
    log:info("%s stopped during the alert; turning it back on", fan.name)
    owned[key] = true
    commandFan(key, true)
    -- Saved at once: a restart must still know this fan is the alert's to turn off.
    saveState()
  end
end

--- Stop watching the selected fans.
local function forgetFans()
  for key, fan in pairs(fans) do
    if fan.deviceId ~= nil then
      UnregisterVariableListener(fan.deviceId, VAR_DEVICE_ON)
    end
  end
  fans = {}
end

--- Watch a light or a fan controller as a fan.
--- @param deviceId integer
--- @param name string
local function watchDevice(deviceId, name)
  local key = tostring(deviceId)
  fans[key] = {
    deviceId = deviceId,
    name = name,
    on = toboolean(C4:GetDeviceVariable(deviceId, VAR_DEVICE_ON)),
  }
  RegisterVariableListener(deviceId, VAR_DEVICE_ON, function(_, _, strValue)
    onFanState(key, toboolean(strValue), true)
  end)
end

--- Register the handlers of the Relay connection.
--- @param binding Binding
local function registerFanRelayHandlers(binding)
  RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
    log:trace("RFP[%s](%s, %s)", binding.bindingId, idBinding, strCommand)
    if strCommand == "CLOSED" or strCommand == "OPENED" then
      onFanState(FAN_RELAY_KEY, strCommand == "CLOSED", true)
    elseif strCommand == "STATE_CLOSED" or strCommand == "STATE_OPENED" then
      onFanState(FAN_RELAY_KEY, strCommand == "STATE_CLOSED", false)
    end
  end

  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    local fan = fans[FAN_RELAY_KEY]
    if fan ~= nil then
      -- Another relay, or none: what the last one showed says nothing about it.
      fan.on = nil
    end
    if not bIsBound then
      owned[FAN_RELAY_KEY] = nil
    end
  end
end

--- Make or remove the Relay connection as the Control Method asks.
local function reconcileFanRelay()
  if Properties["Control Method"] == METHOD_RELAY then
    local relay = bindings:getOrAddDynamicBinding(NS_OUTPUT, OUTPUT_FAN_RELAY, "CONTROL", false, "Relay", "RELAY")
    if relay then
      registerFanRelayHandlers(relay)
    end
  else
    local relay = bindings:getDynamicBinding(NS_OUTPUT, OUTPUT_FAN_RELAY)
    if relay then
      RFP[relay.bindingId] = nil
      OBC[relay.bindingId] = nil
      bindings:deleteBinding(NS_OUTPUT, OUTPUT_FAN_RELAY)
    end
  end
end

--- The devices the Control Method's selector names.
--- @param method string The Control Method.
--- @return table<string, string> names Each device's display name, by its id as text.
local function selectedDevices(method)
  local names = {}
  local property = method == METHOD_LIGHT and "Light Switches" or method == METHOD_FAN and "Fan Controller" or nil
  if property ~= nil then
    ParseDeviceIdPropertyList(property, function(deviceId, device)
      names[tostring(deviceId)] = device.displayName
      return device
    end)
  end
  return names
end

--- Watch the fans the Control Method and its selector name, and show only that selector.
local function configureFans()
  local method = Properties["Control Method"]
  local devices = selectedDevices(method)

  -- A fan the alert turned on that is no longer selected is turned off while it can still be reached,
  -- also when it left the selection while the driver was down and so has no entry in fans yet.
  local ownedKeys = TableKeys(owned)
  table.sort(ownedKeys)
  for _, key in ipairs(ownedKeys) do
    local stays = (key == FAN_RELAY_KEY and method == METHOD_RELAY) or devices[key] ~= nil
    if not stays and state.active then
      local fan = fans[key]
        or (key == FAN_RELAY_KEY and { name = "the relay" } or { name = "device " .. key, deviceId = tointeger(key) })
      -- Forgotten before the off goes out, so its answer is not taken for someone switching it off.
      if fan.deviceId ~= nil then
        UnregisterVariableListener(fan.deviceId, VAR_DEVICE_ON)
      end
      fans[key] = nil
      owned[key] = nil
      sendFan(fan, false)
    end
  end
  local previous = fans
  forgetFans()
  reconcileFanRelay()
  C4:SetPropertyAttribs("Light Switches", method == METHOD_LIGHT and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY)
  C4:SetPropertyAttribs("Fan Controller", method == METHOD_FAN and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY)

  if method == METHOD_RELAY then
    local before = previous[FAN_RELAY_KEY]
    fans[FAN_RELAY_KEY] = { name = "the relay", on = before and before.on or nil }
  else
    for key, name in pairs(devices) do
      watchDevice(tointeger(key), name)
    end
  end

  for key, _ in pairs(owned) do
    if fans[key] == nil then
      owned[key] = nil
    end
  end
  if anyFanOn() then
    Detector.fanStarted(state, now())
  elseif state.fanRunning then
    -- No selected fan runs any longer: it stopped while the driver was down, or is no longer selected.
    Detector.fanStopped(state, now())
  end
  if gInitialized and state.active and licensed() then
    engageFans()
    saveState()
  end
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
  local reference = "Not used"
  if Properties["Reference Sensor"] == "Enabled" then
    local rh, silent = Detector.referenceReading(state, settings(), now())
    if rh ~= nil then
      reference = "In use: " .. humidityText(rh)
    elseif silent then
      reference = "Silent, not in use"
    else
      reference = "Waiting for a reading"
    end
  end
  UpdateProperty("Reference", reference, true)

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
      engageFans()
      C4:FireEvent(EVENT_STARTED)
    elseif change.type == Detector.Change.CLEARED then
      rawPeak = nil
      tellContact()
      releaseFans()
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

--- @param quiet? boolean Fire no events: the driver itself is stopping.
endAlert = function(quiet)
  apply(Detector.clear(state, settings(), now()), quiet)
end

--------------------------------------------------------------------------------
-- Readings
--------------------------------------------------------------------------------

--- A sensor's newest temperature, unless it is older than the sensor may stay silent.
--- @param celsius number|nil
--- @param at integer|nil When it was reported.
--- @return number|nil celsius
local function freshCelsius(celsius, at)
  if celsius == nil or at == nil then
    return nil
  end
  local timeout = settings().sensorTimeoutSeconds
  if timeout > 0 and now() - at > timeout then
    return nil
  end
  return celsius
end

--- Hand the waiting humidity report to the detector, with the newest temperature.
local function takeSample()
  local rh = pendingHumidity
  pendingHumidity = nil
  if rh == nil or not licensed() then
    return
  end
  local changes = Detector.sample(state, settings(), now(), rh, freshCelsius(lastCelsius, lastCelsiusTime))
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

--- Forget what the reference sensor said: it was unbound, changed or turned off.
local function forgetReference()
  Detector.dropReference(state)
  pendingReference = nil
  referenceCelsius = nil
  referenceCelsiusTime = nil
  CancelTimer("PairReference")
end

--- Hand the waiting reference report to the detector, with that sensor's newest temperature.
local function takeReference()
  local rh = pendingReference
  pendingReference = nil
  if rh == nil or not licensed() then
    return
  end
  Detector.reference(state, now(), rh, freshCelsius(referenceCelsius, referenceCelsiusTime))
  showStatus()
end

--- A reference humidity report. It waits a moment for the same sensor's temperature, as the room's does.
--- @param rh number
local function onReferenceHumidity(rh)
  local waiting = pendingReference ~= nil
  pendingReference = rh
  if not waiting then
    SetTimer("PairReference", PAIR_WAIT, takeReference)
  end
end

--- A reference temperature report. It never makes a sample of its own.
--- @param celsius number
local function onReferenceTemperature(celsius)
  referenceCelsius = celsius
  referenceCelsiusTime = now()
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

--- Register the handlers of the reference humidity input.
--- @param binding Binding
local function registerReferenceHumidityHandlers(binding)
  RFP[binding.bindingId] = function(idBinding, strCommand, tParams, _args)
    log:trace("RFP[%s](%s, %s, %s)", binding.bindingId, idBinding, strCommand, tParams)
    if strCommand == "VALUE_CHANGED" then
      local value = tofinite(Select(tParams, "VALUE"))
      if value then
        onReferenceHumidity(value)
      end
    end
  end

  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    -- Another sensor reads a few points apart: only its own changes may be compared.
    forgetReference()
    showStatus()
    if bIsBound then
      SendToProxy(binding.bindingId, "GET_VALUE", {})
    end
  end
end

--- Register the handlers of the reference temperature input.
--- @param binding Binding
local function registerReferenceTemperatureHandlers(binding)
  RFP[binding.bindingId] = function(idBinding, strCommand, tParams, _args)
    log:trace("RFP[%s](%s, %s, %s)", binding.bindingId, idBinding, strCommand, tParams)
    if strCommand == "VALUE_CHANGED" then
      local value = CelsiusFromParams(tParams, "CELSIUS")
      if value then
        onReferenceTemperature(value)
      end
    end
  end

  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    -- Readings paired with the old temperature cannot be compared with ones that have none.
    forgetReference()
    showStatus()
    if bIsBound then
      SendToProxy(binding.bindingId, "GET_VALUE", {})
    end
  end
end

--- Make or remove the reference inputs as the Reference Sensor property asks.
local function reconcileReference()
  if Properties["Reference Sensor"] == "Enabled" then
    local humidity = bindings:getOrAddDynamicBinding(
      NS_INPUT,
      INPUT_REFERENCE_HUMIDITY,
      "CONTROL",
      false,
      "Reference Humidity",
      "HUMIDITY_VALUE"
    )
    if humidity then
      registerReferenceHumidityHandlers(humidity)
    end
    local temperature = bindings:getOrAddDynamicBinding(
      NS_INPUT,
      INPUT_REFERENCE_TEMPERATURE,
      "CONTROL",
      false,
      "Reference Temperature",
      "TEMPERATURE_VALUE"
    )
    if temperature then
      registerReferenceTemperatureHandlers(temperature)
    end
  else
    for _, key in ipairs({ INPUT_REFERENCE_HUMIDITY, INPUT_REFERENCE_TEMPERATURE }) do
      local binding = bindings:getDynamicBinding(NS_INPUT, key)
      if binding then
        RFP[binding.bindingId] = nil
        OBC[binding.bindingId] = nil
        bindings:deleteBinding(NS_INPUT, key)
      end
    end
    forgetReference()
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
  -- The Relay connection is left to configureFans, which must send a dropped relay an OPEN before deleting it.
  reconcileReference()
end

--- Ask each input for its value now: a sensor that reports only changes may stay silent for hours.
local function requestReadings()
  for _, key in ipairs({
    INPUT_HUMIDITY,
    INPUT_TEMPERATURE,
    INPUT_REFERENCE_HUMIDITY,
    INPUT_REFERENCE_TEMPERATURE,
  }) do
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
    owned = type(record.owned) == "table" and record.owned or {}
  else
    state = Detector.newState()
    rawPeak = nil
    owned = {}
  end
  fans = {}
  -- An alert that outlasted the downtime is restored as it was and ended by the first tick.
  Detector.restart(state, now())
  lastContactState = nil
  pendingHumidity = nil
  lastCelsius = nil
  lastCelsiusTime = nil
  pendingReference = nil
  referenceCelsius = nil
  referenceCelsiusTime = nil
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

function OPC.Reference_Sensor(propertyValue)
  log:trace("OPC.Reference_Sensor('%s')", propertyValue)
  reconcileReference()
  if gInitialized and licensed() then
    showStatus()
    requestReadings()
  end
end

function OPC.Control_Method(propertyValue)
  log:trace("OPC.Control_Method('%s')", propertyValue)
  configureFans()
end

function OPC.Light_Switches(propertyValue)
  log:trace("OPC.Light_Switches('%s')", propertyValue)
  if Properties["Control Method"] == METHOD_LIGHT then
    configureFans()
  end
end

function OPC.Fan_Controller(propertyValue)
  log:trace("OPC.Fan_Controller('%s')", propertyValue)
  if Properties["Control Method"] == METHOD_FAN then
    configureFans()
  end
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
  CancelTimer("PairReference")
  forgetFans()

  -- Reset all dynamic state
  bindings:reset()
  values:reset()
  persist:set(PERSIST_STATE, nil)
  state = Detector.newState()
  rawPeak = nil
  owned = {}
  pendingHumidity = nil
  lastCelsius = nil
  lastCelsiusTime = nil
  pendingReference = nil
  referenceCelsius = nil
  referenceCelsiusTime = nil
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
  configureFans()
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
