--- Device Programmer Driver
--#ifdef DRIVERCENTRAL
DC_PID = nil
DC_X = nil
DC_FILENAME = "device_programmer.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-finite-labs-essentials"
DRIVER_FILENAMES = { "device_programmer.c4z" }
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local bindings = require("lib.bindings")
local persist = require("lib.persist")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Namespace for temperature output bindings
local NS_TEMPERATURE = "Temperature"

--- Namespace for humidity output bindings
local NS_HUMIDITY = "Humidity"

--- Namespace for contact output bindings
local NS_CONTACT = "Contact"

--- Namespace for relay output bindings
local NS_RELAY = "Relay"

--- Persist keys
local PERSIST_TEMPERATURE_VALUES = "TemperatureValues"
local PERSIST_HUMIDITY_VALUES = "HumidityValues"
local PERSIST_CONTACT_VALUES = "ContactValues"
local PERSIST_RELAY_VALUES = "RelayValues"

--------------------------------------------------------------------------------
-- Name Parsing
--------------------------------------------------------------------------------

--- Parse a comma-delimited string of sensor names.
--- Trims whitespace, removes empty entries, strips colons, and deduplicates (case-insensitive, first wins).
--- @param rawNames string The raw comma-delimited names string.
--- @return string[] names The parsed, deduplicated list of names.
local function parseNames(rawNames)
  if IsEmpty(rawNames) then
    return {}
  end
  local names = {}
  local seen = {}
  for part in string.gmatch(rawNames, "[^,]+") do
    -- Trim whitespace
    local name = part:match("^%s*(.-)%s*$") or ""
    -- Strip colons (reserved for namespace separator)
    name = name:gsub(":", "")
    if name ~= "" then
      local lowerName = string.lower(name)
      if not seen[lowerName] then
        seen[lowerName] = true
        table.insert(names, name)
      end
    end
  end
  return names
end

--------------------------------------------------------------------------------
-- State Accessors
--------------------------------------------------------------------------------

--- Get persisted temperature values.
--- @return table<string, number?> values Map of name → Celsius value.
local function getTemperatureValues()
  return persist:get(PERSIST_TEMPERATURE_VALUES, {})
end

--- Get persisted humidity values.
--- @return table<string, number?> values Map of name → percent value.
local function getHumidityValues()
  return persist:get(PERSIST_HUMIDITY_VALUES, {})
end

--- Get persisted contact values.
--- @return table<string, boolean?> values Map of name → closed state.
local function getContactValues()
  return persist:get(PERSIST_CONTACT_VALUES, {})
end

--- Get parsed temperature names from the property.
--- @return string[] names
local function getTemperatureNames()
  return parseNames(Properties["Temperature Names"])
end

--- Get parsed humidity names from the property.
--- @return string[] names
local function getHumidityNames()
  return parseNames(Properties["Humidity Names"])
end

--- Get parsed contact names from the property.
--- @return string[] names
local function getContactNames()
  return parseNames(Properties["Contact Names"])
end

--- Get persisted relay values.
--- @return table<string, boolean?> values Map of name → closed state.
local function getRelayValues()
  return persist:get(PERSIST_RELAY_VALUES, {})
end

--- Get parsed relay names from the property.
--- @return string[] names
local function getRelayNames()
  return parseNames(Properties["Relay Names"])
end

--- Check if a name exists in a names list.
--- @param names string[] The list of names.
--- @param name string The name to check.
--- @return boolean found
local function nameExists(names, name)
  for _, n in ipairs(names) do
    if n == name then
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- Output Binding Helpers
--------------------------------------------------------------------------------

--- Get the project temperature scale for VALUE_CHANGED messages.
--- @return string scale "CELSIUS" or "FAHRENHEIT"
local function getTemperatureScale()
  return Select({
    CELSIUS = "CELSIUS",
    FAHRENHEIT = "FAHRENHEIT",
  }, C4:GetProjectProperty("TemperatureScale")) or "FAHRENHEIT"
end

--- Send temperature value to a specific binding.
--- @param binding Binding? The binding to send to.
--- @param value number? The temperature value.
local function sendTemperatureValue(binding, value)
  if binding and value then
    SendToProxy(binding.bindingId, "VALUE_CHANGED", { VALUE = value, SCALE = getTemperatureScale() })
  end
end

--- Send humidity value to a specific binding.
--- @param binding Binding? The binding to send to.
--- @param value number? The humidity percent.
local function sendHumidityValue(binding, value)
  if binding and value then
    SendToProxy(binding.bindingId, "VALUE_CHANGED", { VALUE = value, SCALE = "PERCENT" })
  end
end

--- Send contact state to a specific binding (runtime, triggers programming).
--- @param binding Binding The binding to send to.
--- @param closed boolean The contact state.
local function sendContactValue(binding, closed)
  if binding and closed ~= nil then
    SendToProxy(binding.bindingId, closed and "CLOSED" or "OPENED", {}, "NOTIFY")
  end
end

--- Send contact state to a specific binding (init/bind, no programming trigger).
--- @param binding Binding The binding to send to.
--- @param closed boolean The contact state.
local function sendContactState(binding, closed)
  if binding and closed ~= nil then
    SendToProxy(binding.bindingId, closed and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
  end
end

--- Send relay state to a specific binding (runtime, triggers programming).
--- @param binding Binding The binding to send to.
--- @param closed boolean The relay state.
local function sendRelayValue(binding, closed)
  if binding and closed ~= nil then
    SendToProxy(binding.bindingId, closed and "CLOSED" or "OPENED", {}, "NOTIFY")
  end
end

--- Send relay state to a specific binding (init/bind, no programming trigger).
--- @param binding Binding The binding to send to.
--- @param closed boolean The relay state.
local function sendRelayState(binding, closed)
  if binding and closed ~= nil then
    SendToProxy(binding.bindingId, closed and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
  end
end

--------------------------------------------------------------------------------
-- Output Binding Handler Registration
--------------------------------------------------------------------------------

--- Register RFP and OBC handlers for a temperature output binding.
--- @param binding Binding The output binding.
--- @param name string The sensor name.
local function registerTemperatureOutputHandlers(binding, name)
  -- RFP handler: respond to GET_VALUE
  RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
    log:trace("RFP[%s](%s, %s)", binding.bindingId, idBinding, strCommand)
    if strCommand == "GET_VALUE" then
      local value = getTemperatureValues()[name]
      if value then
        SendToProxy(idBinding, "VALUE_CHANGED", { VALUE = value, SCALE = getTemperatureScale() })
      end
    end
  end

  -- OBC handler: send current value when consumer connects
  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    if bIsBound then
      local value = getTemperatureValues()[name]
      if value then
        SendToProxy(idBinding, "VALUE_CHANGED", { VALUE = value, SCALE = getTemperatureScale() })
      end
    end
  end
end

--- Register RFP and OBC handlers for a humidity output binding.
--- @param binding Binding The output binding.
--- @param name string The sensor name.
local function registerHumidityOutputHandlers(binding, name)
  -- RFP handler: respond to GET_VALUE
  RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
    log:trace("RFP[%s](%s, %s)", binding.bindingId, idBinding, strCommand)
    if strCommand == "GET_VALUE" then
      local value = getHumidityValues()[name]
      if value then
        SendToProxy(idBinding, "VALUE_CHANGED", { VALUE = value, SCALE = "PERCENT" })
      end
    end
  end

  -- OBC handler: send current value when consumer connects
  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    if bIsBound then
      local value = getHumidityValues()[name]
      if value then
        SendToProxy(idBinding, "VALUE_CHANGED", { VALUE = value, SCALE = "PERCENT" })
      end
    end
  end
end

--- Register OBC handler for a contact output binding.
--- @param binding Binding The output binding.
--- @param name string The sensor name.
local function registerContactOutputHandlers(binding, name)
  -- No RFP handler (contact sensors are push-only, no GET_VALUE)

  -- OBC handler: send current state when consumer connects
  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    if bIsBound then
      local closed = getContactValues()[name]
      if closed ~= nil then
        -- Use STATE_ prefix on bind to set state without triggering programming events
        SendToProxy(idBinding, closed and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
      end
    end
  end
end

--- Register RFP and OBC handlers for a relay output binding.
--- @param binding Binding The output binding.
--- @param name string The relay name.
local function registerRelayOutputHandlers(binding, name)
  -- RFP handler: respond to OPEN/CLOSE/TOGGLE from bound consumers
  RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
    log:trace("RFP[%s](%s, %s)", binding.bindingId, idBinding, strCommand)
    if strCommand == "OPEN" then
      EC.Open_Relay({ Name = name })
    elseif strCommand == "CLOSE" then
      EC.Close_Relay({ Name = name })
    elseif strCommand == "TOGGLE" then
      EC.Toggle_Relay({ Name = name })
    end
  end

  -- OBC handler: send current state when consumer connects
  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    if bIsBound then
      local closed = getRelayValues()[name]
      if closed ~= nil then
        -- Use STATE_ prefix on bind to set state without triggering programming events
        SendToProxy(idBinding, closed and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Binding Reconciliation
--------------------------------------------------------------------------------

--- Reconcile output bindings for a sensor type.
--- @param namespace string The binding namespace.
--- @param persistValuesKey string The persist key for values.
--- @param parsedNames string[] The current parsed names.
--- @param bindingType string "CONTROL" or "PROXY".
--- @param bindingClass string The binding class (e.g., "TEMPERATURE_VALUE").
--- @param displaySuffix string The suffix for display name (e.g., " Temperature").
--- @param registerFn function The handler registration function.
local function reconcileBindings(
  namespace,
  persistValuesKey,
  parsedNames,
  bindingType,
  bindingClass,
  displaySuffix,
  registerFn
)
  log:info("reconcileBindings(%s)", namespace)

  -- Build desired set of names
  local desiredNames = {}
  for _, name in ipairs(parsedNames) do
    desiredNames[name] = true
  end

  -- Get existing bindings for this namespace
  local existingBindings = bindings:getDynamicBindings(namespace)

  -- Delete bindings for names that no longer exist
  local values = persist:get(persistValuesKey, {})
  for key in pairs(existingBindings) do
    if not desiredNames[key] then
      log:info("Removing %s binding for '%s'", namespace, key)
      bindings:deleteBinding(namespace, key)
      values[key] = nil
    end
  end
  persist:set(persistValuesKey, not IsEmpty(values) and values or nil)

  -- Create bindings for current names and register handlers
  for _, name in ipairs(parsedNames) do
    local binding =
      bindings:getOrAddDynamicBinding(namespace, name, bindingType, true, name .. displaySuffix, bindingClass)
    if binding then
      registerFn(binding, name)
    end
  end
end

--------------------------------------------------------------------------------
-- Restore Persisted Values to Bindings
--------------------------------------------------------------------------------

--- Restore all persisted sensor values to their output bindings.
--- Uses STATE_ prefix for contacts to avoid triggering programming on init.
local function restorePersistedValues()
  log:info("restorePersistedValues()")

  -- Restore temperature values
  for name, value in pairs(getTemperatureValues()) do
    local binding = bindings:getDynamicBinding(NS_TEMPERATURE, name)
    if binding then
      sendTemperatureValue(binding, value)
    end
  end

  -- Restore humidity values
  for name, value in pairs(getHumidityValues()) do
    local binding = bindings:getDynamicBinding(NS_HUMIDITY, name)
    if binding then
      sendHumidityValue(binding, value)
    end
  end

  -- Restore contact values (use STATE_ to avoid programming triggers)
  for name, closed in pairs(getContactValues()) do
    local binding = bindings:getDynamicBinding(NS_CONTACT, name)
    if binding then
      sendContactState(binding, closed)
    end
  end

  -- Restore relay values (use STATE_ to avoid programming triggers)
  for name, closed in pairs(getRelayValues()) do
    local binding = bindings:getDynamicBinding(NS_RELAY, name)
    if binding then
      sendRelayState(binding, closed)
    end
  end
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  -- Restore persisted state
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Fire OnPropertyChanged for all properties (triggers reconciliation)
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  -- Restore persisted values to bindings
  restorePersistedValues()

  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    if toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver updates")
      UpdateDrivers()
    end
  end, true)
  --#endif

  gInitialized = true
  UpdateProperty("Driver Status", "Ready")
end

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
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
    DEBUG_WEBSOCKET = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
    DEBUG_WEBSOCKET = false
  end
end

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
end
--#endif

function OPC.Temperature_Names(propertyValue)
  log:trace("OPC.Temperature_Names('%s')", propertyValue)
  local names = parseNames(propertyValue or "")

  -- Reconcile temperature bindings
  reconcileBindings(
    NS_TEMPERATURE,
    PERSIST_TEMPERATURE_VALUES,
    names,
    "CONTROL",
    "TEMPERATURE_VALUE",
    " Temperature",
    registerTemperatureOutputHandlers
  )

  -- Restore persisted values to new/existing bindings
  local values = getTemperatureValues()
  for _, name in ipairs(names) do
    local binding = bindings:getDynamicBinding(NS_TEMPERATURE, name)
    if binding and values[name] then
      sendTemperatureValue(binding, values[name])
    end
  end
end

function OPC.Humidity_Names(propertyValue)
  log:trace("OPC.Humidity_Names('%s')", propertyValue)
  local names = parseNames(propertyValue or "")

  -- Reconcile humidity bindings
  reconcileBindings(
    NS_HUMIDITY,
    PERSIST_HUMIDITY_VALUES,
    names,
    "CONTROL",
    "HUMIDITY_VALUE",
    " Humidity",
    registerHumidityOutputHandlers
  )

  -- Restore persisted values to new/existing bindings
  local values = getHumidityValues()
  for _, name in ipairs(names) do
    local binding = bindings:getDynamicBinding(NS_HUMIDITY, name)
    if binding and values[name] then
      sendHumidityValue(binding, values[name])
    end
  end
end

function OPC.Contact_Names(propertyValue)
  log:trace("OPC.Contact_Names('%s')", propertyValue)
  local names = parseNames(propertyValue or "")

  -- Reconcile contact bindings
  reconcileBindings(
    NS_CONTACT,
    PERSIST_CONTACT_VALUES,
    names,
    "PROXY",
    "CONTACT_SENSOR",
    " Contact",
    registerContactOutputHandlers
  )

  -- Restore persisted states to new/existing bindings (use STATE_ to avoid programming triggers)
  local values = getContactValues()
  for _, name in ipairs(names) do
    local binding = bindings:getDynamicBinding(NS_CONTACT, name)
    if binding and values[name] ~= nil then
      sendContactState(binding, values[name])
    end
  end
end

function OPC.Relay_Names(propertyValue)
  log:trace("OPC.Relay_Names('%s')", propertyValue)
  local names = parseNames(propertyValue or "")

  -- Reconcile relay bindings
  reconcileBindings(NS_RELAY, PERSIST_RELAY_VALUES, names, "CONTROL", "RELAY", " Relay", registerRelayOutputHandlers)

  -- Restore persisted states to new/existing bindings (use STATE_ to avoid programming triggers)
  local values = getRelayValues()
  for _, name in ipairs(names) do
    local binding = bindings:getDynamicBinding(NS_RELAY, name)
    if binding and values[name] ~= nil then
      sendRelayState(binding, values[name])
    end
  end
end

function OPC.Hide_Devices(propertyValue)
  log:trace("OPC.Hide_Devices('%s')", propertyValue)
  if IsEmpty(propertyValue) then
    return
  end

  local rooms = C4:GetDevicesByC4iName("roomdevice.c4i") or {}
  local devices = ParseDeviceIdList(propertyValue)

  for deviceId, device in pairs(devices) do
    log:info("Hiding device '%s' (ID: %s) from all navigators", device.displayName, deviceId)
    for roomId, _ in pairs(rooms) do
      C4:SendToDevice(
        roomId,
        "SET_DEVICE_HIDDEN_STATE",
        { PROXY_GROUP = "ALL", DEVICE_ID = deviceId, IS_HIDDEN = true }
      )
    end
  end

  -- Clear the property after processing
  UpdateProperty("Hide Devices", "", false)
end

--------------------------------------------------------------------------------
-- Programming Command Handlers (EC)
--------------------------------------------------------------------------------

--- Convert a temperature value from one scale to another.
--- @param value number The temperature value.
--- @param fromScale string "FAHRENHEIT" or "CELSIUS".
--- @param toScale string "FAHRENHEIT" or "CELSIUS".
--- @return number|nil converted The converted temperature value.
local function convertTemperature(value, fromScale, toScale)
  if fromScale == toScale then
    return value
  elseif fromScale == "FAHRENHEIT" then
    return f2c(value)
  else
    return c2f(value)
  end
end

--- Normalize a scale parameter to "FAHRENHEIT" or "CELSIUS".
--- @param scale string? The scale parameter (e.g., "Fahrenheit", "Celsius").
--- @return string scale "FAHRENHEIT" or "CELSIUS".
local function normalizeScale(scale)
  if type(scale) == "string" and scale:upper() == "CELSIUS" then
    return "CELSIUS"
  end
  return "FAHRENHEIT"
end

--- Set Temperature command handler.
--- Value is converted from the given scale to the project's temperature scale.
--- @param params table Command parameters: Name, Value, Scale.
function EC.Set_Temperature(params)
  log:trace("EC.Set_Temperature(%s)", params)
  local name = Select(params, "Name")
  local valueStr = Select(params, "Value")
  local scale = normalizeScale(Select(params, "Scale"))

  if IsEmpty(name) then
    log:warn("Set Temperature: missing Name parameter")
    return
  end

  -- Validate name exists
  local names = getTemperatureNames()
  if not nameExists(names, name) then
    log:warn("Set Temperature: name '%s' not found in configured names", name)
    return
  end

  -- Parse value
  local value = tonumber(valueStr)
  if value == nil then
    log:warn("Set Temperature: invalid value '%s'", valueStr)
    return
  end

  -- Convert to project scale
  local projectScale = getTemperatureScale()
  value = convertTemperature(value, scale, projectScale)

  log:info("Set Temperature: %s = %s (%s)", name, value, projectScale)

  -- Persist value
  local values = getTemperatureValues()
  values[name] = value
  persist:set(PERSIST_TEMPERATURE_VALUES, values)

  -- Send to binding
  local binding = bindings:getDynamicBinding(NS_TEMPERATURE, name)
  if binding then
    sendTemperatureValue(binding, value)
  end
end

--- Set Humidity command handler.
--- @param params table Command parameters: Name, Value.
function EC.Set_Humidity(params)
  log:trace("EC.Set_Humidity(%s)", params)
  local name = Select(params, "Name")
  local valueStr = Select(params, "Value")

  if IsEmpty(name) then
    log:warn("Set Humidity: missing Name parameter")
    return
  end

  -- Validate name exists
  local names = getHumidityNames()
  if not nameExists(names, name) then
    log:warn("Set Humidity: name '%s' not found in configured names", name)
    return
  end

  -- Parse value
  local value = tonumber(valueStr)
  if value == nil then
    log:warn("Set Humidity: invalid value '%s'", valueStr)
    return
  end
  value = math.max(0, math.min(100, value)) -- Clamp to 0-100%

  log:info("Set Humidity: %s = %s%%", name, value)

  -- Persist value
  local values = getHumidityValues()
  values[name] = value
  persist:set(PERSIST_HUMIDITY_VALUES, values)

  -- Send to binding
  local binding = bindings:getDynamicBinding(NS_HUMIDITY, name)
  if binding then
    sendHumidityValue(binding, value)
  end
end

--- Set Contact command handler.
--- @param params table Command parameters: Name, State.
function EC.Set_Contact(params)
  log:trace("EC.Set_Contact(%s)", params)
  local name = Select(params, "Name")
  local state = Select(params, "State")

  if IsEmpty(name) then
    log:warn("Set Contact: missing Name parameter")
    return
  end

  -- Validate name exists
  local names = getContactNames()
  if not nameExists(names, name) then
    log:warn("Set Contact: name '%s' not found in configured names", name)
    return
  end

  -- Parse state
  local closed
  if state == "Closed" then
    closed = true
  elseif state == "Open" then
    closed = false
  else
    log:warn("Set Contact: invalid state '%s' (expected 'Open' or 'Closed')", state)
    return
  end

  log:info("Set Contact: %s = %s", name, state)

  -- Persist value
  local values = getContactValues()
  values[name] = closed
  persist:set(PERSIST_CONTACT_VALUES, values)

  -- Send to binding (runtime, triggers programming)
  local binding = bindings:getDynamicBinding(NS_CONTACT, name)
  if binding then
    sendContactValue(binding, closed)
  end
end

--- Set Temperature from Variable command handler.
--- Delegates to Set_Temperature using the variable's current value.
--- @param params table Command parameters: Name, Variable, Scale.
function EC.Set_Temperature_from_Variable(params)
  log:trace("EC.Set_Temperature_from_Variable(%s)", params)
  EC.Set_Temperature({
    Name = Select(params, "Name"),
    Value = Select(params, "Variable"),
    Scale = Select(params, "Scale"),
  })
end

--- Set Humidity from Variable command handler.
--- Delegates to Set_Humidity using the variable's current value.
--- @param params table Command parameters: Name, Variable.
function EC.Set_Humidity_from_Variable(params)
  log:trace("EC.Set_Humidity_from_Variable(%s)", params)
  EC.Set_Humidity({
    Name = Select(params, "Name"),
    Value = Select(params, "Variable"),
  })
end

--- Set Contact from Variable command handler.
--- Delegates to Set_Contact using the variable's current value.
--- @param params table Command parameters: Name, Variable.
function EC.Set_Contact_from_Variable(params)
  log:trace("EC.Set_Contact_from_Variable(%s)", params)
  EC.Set_Contact({
    Name = Select(params, "Name"),
    State = toboolean(Select(params, "Variable")) and "Closed" or "Open",
  })
end

--------------------------------------------------------------------------------
-- Relay Command Handlers
--------------------------------------------------------------------------------

--- Apply a relay state change: persist and notify.
--- @param name string The relay name.
--- @param closed boolean The new relay state (true=closed, false=opened).
local function applyRelayState(name, closed)
  log:info("%s Relay: %s", closed and "Close" or "Open", name)

  -- Persist value
  local values = getRelayValues()
  values[name] = closed
  persist:set(PERSIST_RELAY_VALUES, values)

  -- Send to binding (runtime, triggers programming)
  local binding = bindings:getDynamicBinding(NS_RELAY, name)
  if binding then
    sendRelayValue(binding, closed)
  end
end

--- Open Relay command handler.
--- @param params table Command parameters: Name.
function EC.Open_Relay(params)
  log:trace("EC.Open_Relay(%s)", params)
  local name = Select(params, "Name")

  if IsEmpty(name) then
    log:warn("Open Relay: missing Name parameter")
    return
  end

  local names = getRelayNames()
  if not nameExists(names, name) then
    log:warn("Open Relay: name '%s' not found in configured names", name)
    return
  end

  applyRelayState(name, false)
end

--- Close Relay command handler.
--- @param params table Command parameters: Name.
function EC.Close_Relay(params)
  log:trace("EC.Close_Relay(%s)", params)
  local name = Select(params, "Name")

  if IsEmpty(name) then
    log:warn("Close Relay: missing Name parameter")
    return
  end

  local names = getRelayNames()
  if not nameExists(names, name) then
    log:warn("Close Relay: name '%s' not found in configured names", name)
    return
  end

  applyRelayState(name, true)
end

--- Toggle Relay command handler.
--- @param params table Command parameters: Name.
function EC.Toggle_Relay(params)
  log:trace("EC.Toggle_Relay(%s)", params)
  local name = Select(params, "Name")

  if IsEmpty(name) then
    log:warn("Toggle Relay: missing Name parameter")
    return
  end

  local names = getRelayNames()
  if not nameExists(names, name) then
    log:warn("Toggle Relay: name '%s' not found in configured names", name)
    return
  end

  -- Read current state; default unset to open, so toggle -> closed
  local currentClosed = getRelayValues()[name]
  if currentClosed == nil then
    currentClosed = false
  end

  applyRelayState(name, not currentClosed)
end

--- Set Relay from Variable command handler.
--- Sets the relay state from a boolean variable's current value.
--- @param params table Command parameters: Name, Variable.
function EC.Set_Relay_from_Variable(params)
  log:trace("EC.Set_Relay_from_Variable(%s)", params)
  local closed = toboolean(Select(params, "Variable"))
  if closed then
    EC.Close_Relay({ Name = Select(params, "Name") })
  else
    EC.Open_Relay({ Name = Select(params, "Name") })
  end
end

--------------------------------------------------------------------------------
-- GCPL Handlers (Dynamic List Population)
--------------------------------------------------------------------------------

--- Populate the Name dropdown for Set Temperature command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of temperature sensor names.
function GCPL.Set_Temperature(paramName)
  log:trace("GCPL.Set_Temperature(%s)", paramName)
  if paramName ~= "Name" then
    return {}
  end
  return getTemperatureNames()
end

--- Populate the Name dropdown for Set Humidity command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of humidity sensor names.
function GCPL.Set_Humidity(paramName)
  log:trace("GCPL.Set_Humidity(%s)", paramName)
  if paramName ~= "Name" then
    return {}
  end
  return getHumidityNames()
end

--- Populate the Name dropdown for Set Contact command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of contact sensor names.
function GCPL.Set_Contact(paramName)
  log:trace("GCPL.Set_Contact(%s)", paramName)
  if paramName ~= "Name" then
    return {}
  end
  return getContactNames()
end

--- Populate the Name dropdown for Set Temperature from Variable command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of temperature sensor names.
function GCPL.Set_Temperature_from_Variable(paramName)
  log:trace("GCPL.Set_Temperature_from_Variable(%s)", paramName)
  if paramName ~= "Name" then
    return {}
  end
  return getTemperatureNames()
end

--- Populate the Name dropdown for Set Humidity from Variable command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of humidity sensor names.
function GCPL.Set_Humidity_from_Variable(paramName)
  log:trace("GCPL.Set_Humidity_from_Variable(%s)", paramName)
  if paramName ~= "Name" then
    return {}
  end
  return getHumidityNames()
end

--- Populate the Name dropdown for Set Contact from Variable command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of contact sensor names.
function GCPL.Set_Contact_from_Variable(paramName)
  log:trace("GCPL.Set_Contact_from_Variable(%s)", paramName)
  if paramName ~= "Name" then
    return {}
  end
  return getContactNames()
end

--- Populate the Name dropdown for Open Relay command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of relay names.
function GCPL.Open_Relay(paramName)
  log:trace("GCPL.Open_Relay(%s)", paramName)
  if paramName ~= "Name" then
    return {}
  end
  return getRelayNames()
end

--- Populate the Name dropdown for Close Relay command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of relay names.
function GCPL.Close_Relay(paramName)
  log:trace("GCPL.Close_Relay(%s)", paramName)
  if paramName ~= "Name" then
    return {}
  end
  return getRelayNames()
end

--- Populate the Name dropdown for Toggle Relay command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of relay names.
function GCPL.Toggle_Relay(paramName)
  log:trace("GCPL.Toggle_Relay(%s)", paramName)
  if paramName ~= "Name" then
    return {}
  end
  return getRelayNames()
end

--- Populate the Name dropdown for Set Relay from Variable command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of relay names.
function GCPL.Set_Relay_from_Variable(paramName)
  log:trace("GCPL.Set_Relay_from_Variable(%s)", paramName)
  if paramName ~= "Name" then
    return {}
  end
  return getRelayNames()
end

--------------------------------------------------------------------------------
-- Reset Handler
--------------------------------------------------------------------------------

--- Reset driver to initial state.
function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")

  -- Reset all dynamic state
  bindings:reset()
  persist:reset({ PERSIST_TEMPERATURE_VALUES, PERSIST_HUMIDITY_VALUES, PERSIST_CONTACT_VALUES, PERSIST_RELAY_VALUES })

  -- Reset properties to defaults
  local resetValues = GetPropertyResetValues({})
  for propName, defaultValue in pairs(resetValues) do
    UpdateProperty(propName, defaultValue, true)
  end
end

--#ifndef DRIVERCENTRAL
--------------------------------------------------------------------------------
-- Update Drivers
--------------------------------------------------------------------------------

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
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
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
