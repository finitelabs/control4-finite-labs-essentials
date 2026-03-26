--- Sensor Multiplexer Driver
--#ifdef DRIVERCENTRAL
DC_PID = nil
DC_X = nil
DC_FILENAME = "sensor_multiplexer.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-finite-labs-essentials"
DRIVER_FILENAMES = { "sensor_multiplexer.c4z" }
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
local events = require("lib.events")
local conditionals = require("lib.conditionals")
local constants = require("constants")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

--#ifndef DRIVERCENTRAL
--- Whether this instance is the leader (lowest device ID) for update checks.
--- @type boolean
local isLeaderInstance = false
--#endif

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Namespace prefix for input bindings (e.g., "In:Home", "In:Away")
local NS_INPUT_PREFIX = "In:"

--- Namespace for output bindings
local NS_OUTPUT = "Output"

--- Output binding keys
local OUTPUT_TEMP = "temperature"
local OUTPUT_HUM = "humidity"
local OUTPUT_CONTACT = "contact"

--- Input binding keys (within each named namespace)
local INPUT_TEMP = "temp"
local INPUT_HUM = "hum"
local INPUT_CONTACT = "contact"

--- Persist keys
local PERSIST_INPUT_VALUES = "InputValues"
local PERSIST_ACTIVE_INPUT = "ActiveInput"
local PERSIST_PARSED_NAMES = "ParsedNames"

--- Event/conditional namespace
local NS_EVENTS = "Mux"
local NS_CONDITIONALS = "Mux"

--- Event key
local EVENT_SELECTION_CHANGED = "selection_changed"

--------------------------------------------------------------------------------
-- Name Parsing
--------------------------------------------------------------------------------

--- Parse a comma-delimited string of input names.
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
    local name = part:match("^%s*(.-)%s*$")
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

--- Get the input namespace for a given name.
--- @param name string The input group name.
--- @return string namespace The namespace string.
local function inputNamespace(name)
  return NS_INPUT_PREFIX .. name
end

--------------------------------------------------------------------------------
-- State Accessors
--------------------------------------------------------------------------------

--- Get the parsed names list from persist.
--- @return string[] names The parsed names list.
local function getParsedNames()
  return persist:get(PERSIST_PARSED_NAMES, {})
end

--- Set the parsed names list in persist.
--- @param names string[] The parsed names list.
local function setParsedNames(names)
  persist:set(PERSIST_PARSED_NAMES, names)
end

--- Get the active input name from persist.
--- @return string|nil name The active input name, or nil if none selected.
local function getActiveInput()
  return persist:get(PERSIST_ACTIVE_INPUT, nil)
end

--- Get all cached input values from persist.
--- @return table<string, table<string, any>> values The cached input values, keyed by name then sensor type.
local function getInputValues()
  return persist:get(PERSIST_INPUT_VALUES, {})
end

--- Set a cached input value.
--- @param name string The input group name.
--- @param sensorKey string The sensor type key (INPUT_TEMP, INPUT_HUM, INPUT_CONTACT).
--- @param value any The value to cache.
local function setCachedInputValue(name, sensorKey, value)
  local cache = getInputValues()
  cache[name] = cache[name] or {}
  cache[name][sensorKey] = value
  persist:set(PERSIST_INPUT_VALUES, cache)
end

--- Clear a cached input value.
--- @param name string The input group name.
--- @param sensorKey string The sensor type key.
local function clearCachedInputValue(name, sensorKey)
  local cache = getInputValues()
  if cache[name] then
    cache[name][sensorKey] = nil
    if IsEmpty(cache[name]) then
      cache[name] = nil
    end
  end
  persist:set(PERSIST_INPUT_VALUES, cache)
end

--- Clear all cached values for a name.
--- @param name string The input group name.
local function clearCachedInputGroup(name)
  local cache = getInputValues()
  cache[name] = nil
  persist:set(PERSIST_INPUT_VALUES, cache)
end

--- Get cached value for a specific input and sensor type.
--- @param name string The input group name.
--- @param sensorKey string The sensor type key.
--- @return any value The cached value, or nil.
local function getCachedInputValue(name, sensorKey)
  return Select(getInputValues(), name, sensorKey)
end

--------------------------------------------------------------------------------
-- Property Helpers
--------------------------------------------------------------------------------

--- Check if temperature is enabled.
--- @return boolean enabled
local function isTempEnabled()
  return Properties["Enable Temperature"] == "Yes"
end

--- Check if humidity is enabled.
--- @return boolean enabled
local function isHumEnabled()
  return Properties["Enable Humidity"] == "Yes"
end

--- Check if contact is enabled.
--- @return boolean enabled
local function isContactEnabled()
  return Properties["Enable Contact"] == "Yes"
end

--------------------------------------------------------------------------------
-- Last Contact Output State (for change detection)
--------------------------------------------------------------------------------

local lastContactOutputState = nil

--------------------------------------------------------------------------------
-- Output Binding Helpers
--------------------------------------------------------------------------------

--- Send temperature value to the output binding.
--- @param value number|nil The temperature value in Celsius.
local function sendTempOutput(value)
  local binding = bindings:getDynamicBinding(NS_OUTPUT, OUTPUT_TEMP)
  if binding and value then
    SendToProxy(binding.bindingId, "VALUE_CHANGED", { VALUE = value, SCALE = "CELSIUS" })
  end
end

--- Send humidity value to the output binding.
--- @param value number|nil The humidity value.
local function sendHumOutput(value)
  local binding = bindings:getDynamicBinding(NS_OUTPUT, OUTPUT_HUM)
  if binding and value then
    SendToProxy(binding.bindingId, "VALUE_CHANGED", { VALUE = value, SCALE = "PERCENT" })
  end
end

--- Send contact output for runtime state changes (triggers programming events).
--- @param value boolean|nil The contact state.
local function sendContactOutput(value)
  local binding = bindings:getDynamicBinding(NS_OUTPUT, OUTPUT_CONTACT)
  if binding and value ~= nil then
    SendToProxy(binding.bindingId, value and "CLOSED" or "OPENED", {}, "NOTIFY")
  end
end

--- Send contact state for init/bind (no programming event trigger).
--- @param value boolean|nil The contact state.
local function sendContactState(value)
  local binding = bindings:getDynamicBinding(NS_OUTPUT, OUTPUT_CONTACT)
  if binding and value ~= nil then
    SendToProxy(binding.bindingId, value and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
  end
end

--------------------------------------------------------------------------------
-- Output Update
--------------------------------------------------------------------------------

--- Update all output display properties and send values from the active group.
local function updateOutputs()
  log:trace("updateOutputs()")
  local activeName = getActiveInput()

  -- Temperature
  if isTempEnabled() then
    local tempC = activeName and getCachedInputValue(activeName, INPUT_TEMP) or nil
    if tempC then
      UpdateProperty("Output Temperature C", tostring(tempC) .. " °C", true)
      UpdateProperty("Output Temperature F", tostring(c2f(tempC)) .. " °F", true)
      sendTempOutput(tempC)
    else
      UpdateProperty("Output Temperature C", "", true)
      UpdateProperty("Output Temperature F", "", true)
    end
  end

  -- Humidity
  if isHumEnabled() then
    local hum = activeName and getCachedInputValue(activeName, INPUT_HUM) or nil
    if hum then
      UpdateProperty("Output Humidity", tostring(hum) .. " %", true)
      sendHumOutput(hum)
    else
      UpdateProperty("Output Humidity", "", true)
    end
  end

  -- Contact
  if isContactEnabled() then
    local contact = activeName and getCachedInputValue(activeName, INPUT_CONTACT) or nil
    if contact ~= nil then
      UpdateProperty("Output Contact", contact and "Closed" or "Open", true)
      if contact ~= lastContactOutputState then
        lastContactOutputState = contact
        if gInitialized then
          sendContactOutput(contact)
        else
          sendContactState(contact)
        end
      end
    else
      UpdateProperty("Output Contact", "", true)
      lastContactOutputState = nil
    end
  end
end

--------------------------------------------------------------------------------
-- Selection Logic
--------------------------------------------------------------------------------

--- Set the active input group by name.
--- @param name string|nil The name to select, or nil to deselect.
local function setActiveInput(name)
  log:info("setActiveInput(%s)", name)
  local names = getParsedNames()

  -- Validate name exists in parsed names
  if name ~= nil then
    local found = false
    for _, n in ipairs(names) do
      if n == name then
        found = true
        break
      end
    end
    if not found then
      log:warn("setActiveInput: name '%s' not found in parsed names", name)
      return
    end
  end

  local previousName = getActiveInput()
  persist:set(PERSIST_ACTIVE_INPUT, name)
  UpdateProperty("Active Input Name", name or "", true)

  -- Fire selection changed event if actually changed
  if previousName ~= name and gInitialized then
    events:fire(NS_EVENTS, EVENT_SELECTION_CHANGED)
  end

  -- Update outputs from newly selected group
  lastContactOutputState = nil
  updateOutputs()
end

--------------------------------------------------------------------------------
-- Input Binding Handler Registration
--------------------------------------------------------------------------------

--- Register RFP and OBC handlers for a temperature or humidity input binding.
--- @param binding Binding The input binding.
--- @param name string The input group name.
--- @param sensorKey string The sensor type key.
local function registerNumericInputHandlers(binding, name, sensorKey)
  -- RFP handler: receive VALUE_CHANGED from provider
  RFP[binding.bindingId] = function(idBinding, strCommand, tParams, _args)
    log:trace("RFP[%s](%s, %s, %s)", binding.bindingId, idBinding, strCommand, tParams)
    if strCommand == "VALUE_CHANGED" then
      local value = tonumber(Select(tParams, "VALUE"))
      if value then
        setCachedInputValue(name, sensorKey, value)
        if getActiveInput() == name then
          updateOutputs()
        end
      end
    end
  end

  -- OBC handler: update outputs on binding change
  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace(
      "OBC[%s](%s, %s, %s, %s, %s)",
      binding.bindingId,
      idBinding,
      _strClass,
      bIsBound,
      _otherDeviceId,
      _otherBindingId
    )
    if not bIsBound then
      clearCachedInputValue(name, sensorKey)
    end
    if getActiveInput() == name then
      updateOutputs()
    end
  end
end

--- Register RFP and OBC handlers for a contact input binding.
--- @param binding Binding The input binding.
--- @param name string The input group name.
local function registerContactInputHandlers(binding, name)
  -- RFP handler: receive OPENED/CLOSED from provider
  RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
    log:trace("RFP[%s](%s, %s)", binding.bindingId, idBinding, strCommand)
    if strCommand == "CLOSED" or strCommand == "STATE_CLOSED" then
      setCachedInputValue(name, INPUT_CONTACT, true)
      if getActiveInput() == name then
        updateOutputs()
      end
    elseif strCommand == "OPENED" or strCommand == "STATE_OPENED" then
      setCachedInputValue(name, INPUT_CONTACT, false)
      if getActiveInput() == name then
        updateOutputs()
      end
    end
  end

  -- OBC handler: update outputs on binding change
  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace(
      "OBC[%s](%s, %s, %s, %s, %s)",
      binding.bindingId,
      idBinding,
      _strClass,
      bIsBound,
      _otherDeviceId,
      _otherBindingId
    )
    if not bIsBound then
      clearCachedInputValue(name, INPUT_CONTACT)
    end
    if getActiveInput() == name then
      updateOutputs()
    end
  end
end

--------------------------------------------------------------------------------
-- Output Binding Handler Registration
--------------------------------------------------------------------------------

--- Register handlers for a temperature or humidity output binding.
--- @param binding Binding The output binding.
--- @param sensorKey string The sensor type key (INPUT_TEMP or INPUT_HUM).
--- @param scale string The value scale ("CELSIUS" or "PERCENT").
local function registerNumericOutputHandlers(binding, sensorKey, scale)
  -- RFP handler: respond to GET_VALUE
  RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
    log:trace("RFP[%s](%s, %s)", binding.bindingId, idBinding, strCommand)
    if strCommand == "GET_VALUE" then
      local activeName = getActiveInput()
      if activeName then
        local value = getCachedInputValue(activeName, sensorKey)
        if value then
          SendToProxy(idBinding, "VALUE_CHANGED", { VALUE = value, SCALE = scale })
        end
      end
    end
  end

  -- OBC handler: send current value when consumer connects
  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    if bIsBound then
      local activeName = getActiveInput()
      if activeName then
        local value = getCachedInputValue(activeName, sensorKey)
        if value then
          SendToProxy(idBinding, "VALUE_CHANGED", { VALUE = value, SCALE = scale })
        end
      end
    end
  end
end

--- Register handlers for the contact output binding.
--- @param binding Binding The output binding.
local function registerContactOutputHandlers(binding)
  -- No RFP handler (contact sensors are push-only, no GET_VALUE)

  -- OBC handler: send current state when consumer connects
  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    if bIsBound then
      local activeName = getActiveInput()
      if activeName then
        local value = getCachedInputValue(activeName, INPUT_CONTACT)
        if value ~= nil then
          -- Use STATE_ prefix on bind to set state without triggering programming events
          SendToProxy(idBinding, value and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Binding Reconciliation
--------------------------------------------------------------------------------

--- Reconcile input bindings for all names and enabled sensor types.
local function reconcileInputBindings()
  log:info("reconcileInputBindings()")
  local names = getParsedNames()
  local tempEnabled = isTempEnabled()
  local humEnabled = isHumEnabled()
  local contactEnabled = isContactEnabled()

  -- Build the desired set of namespace+key pairs
  local desiredNamespaces = {}
  for _, name in ipairs(names) do
    local ns = inputNamespace(name)
    desiredNamespaces[ns] = {}
    if tempEnabled then
      desiredNamespaces[ns][INPUT_TEMP] = true
    end
    if humEnabled then
      desiredNamespaces[ns][INPUT_HUM] = true
    end
    if contactEnabled then
      desiredNamespaces[ns][INPUT_CONTACT] = true
    end
  end

  -- Get all current bindings and determine which to keep/delete
  local allBindings = bindings:getBindings()
  local existingInputNamespaces = {}
  for ns in pairs(allBindings) do
    if ns:sub(1, #NS_INPUT_PREFIX) == NS_INPUT_PREFIX then
      existingInputNamespaces[ns] = true
    end
  end

  -- Delete bindings/namespaces no longer needed
  for ns in pairs(existingInputNamespaces) do
    if not desiredNamespaces[ns] then
      -- Entire namespace no longer needed
      local name = ns:sub(#NS_INPUT_PREFIX + 1)
      log:info("Removing all input bindings for '%s'", name)
      bindings:deleteAllBindings(ns)
      clearCachedInputGroup(name)
    else
      -- Check individual keys within namespace
      local existingKeys = bindings:getDynamicBindings(ns)
      for key in pairs(existingKeys) do
        if not desiredNamespaces[ns][key] then
          local name = ns:sub(#NS_INPUT_PREFIX + 1)
          log:info("Removing %s input binding for '%s'", key, name)
          bindings:deleteBinding(ns, key)
          clearCachedInputValue(name, key)
        end
      end
    end
  end

  -- Create bindings for new namespace+key pairs and register handlers
  for _, name in ipairs(names) do
    local ns = inputNamespace(name)

    if tempEnabled then
      local binding =
        bindings:getOrAddDynamicBinding(ns, INPUT_TEMP, "CONTROL", false, name .. " Temperature", "TEMPERATURE_VALUE")
      if binding then
        registerNumericInputHandlers(binding, name, INPUT_TEMP)
      end
    end

    if humEnabled then
      local binding =
        bindings:getOrAddDynamicBinding(ns, INPUT_HUM, "CONTROL", false, name .. " Humidity", "HUMIDITY_VALUE")
      if binding then
        registerNumericInputHandlers(binding, name, INPUT_HUM)
      end
    end

    if contactEnabled then
      local binding =
        bindings:getOrAddDynamicBinding(ns, INPUT_CONTACT, "PROXY", false, name .. " Contact", "CONTACT_SENSOR")
      if binding then
        registerContactInputHandlers(binding, name)
      end
    end
  end
end

--- Ensure output bindings exist and have handlers registered.
local function ensureOutputBindings()
  log:trace("ensureOutputBindings()")

  if isTempEnabled() then
    local tempBinding = bindings:getOrAddDynamicBinding(
      NS_OUTPUT,
      OUTPUT_TEMP,
      "CONTROL",
      true,
      "Output Temperature",
      "TEMPERATURE_VALUE"
    )
    if tempBinding then
      registerNumericOutputHandlers(tempBinding, INPUT_TEMP, "CELSIUS")
    end
    C4:SetPropertyAttribs("Output Temperature C", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Output Temperature F", constants.SHOW_PROPERTY)
  else
    bindings:deleteBinding(NS_OUTPUT, OUTPUT_TEMP)
    UpdateProperty("Output Temperature C", "", true)
    UpdateProperty("Output Temperature F", "", true)
    C4:SetPropertyAttribs("Output Temperature C", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Output Temperature F", constants.HIDE_PROPERTY)
  end

  if isHumEnabled() then
    local humBinding =
      bindings:getOrAddDynamicBinding(NS_OUTPUT, OUTPUT_HUM, "CONTROL", true, "Output Humidity", "HUMIDITY_VALUE")
    if humBinding then
      registerNumericOutputHandlers(humBinding, INPUT_HUM, "PERCENT")
    end
    C4:SetPropertyAttribs("Output Humidity", constants.SHOW_PROPERTY)
  else
    bindings:deleteBinding(NS_OUTPUT, OUTPUT_HUM)
    UpdateProperty("Output Humidity", "", true)
    C4:SetPropertyAttribs("Output Humidity", constants.HIDE_PROPERTY)
  end

  if isContactEnabled() then
    local contactBinding =
      bindings:getOrAddDynamicBinding(NS_OUTPUT, OUTPUT_CONTACT, "PROXY", true, "Output Contact", "CONTACT_SENSOR")
    if contactBinding then
      registerContactOutputHandlers(contactBinding)
    end
    C4:SetPropertyAttribs("Output Contact", constants.SHOW_PROPERTY)
  else
    bindings:deleteBinding(NS_OUTPUT, OUTPUT_CONTACT)
    UpdateProperty("Output Contact", "", true)
    C4:SetPropertyAttribs("Output Contact", constants.HIDE_PROPERTY)
    lastContactOutputState = nil
  end
end

--------------------------------------------------------------------------------
-- Events and Conditionals Reconciliation
--------------------------------------------------------------------------------

--- Ensure the "Selection Changed" event exists.
local function ensureSelectionChangedEvent()
  events:getOrAddEvent(
    NS_EVENTS,
    EVENT_SELECTION_CHANGED,
    "Selection Changed",
    "Fires when the active input selection changes"
  )
end

--- Reconcile conditionals to match current parsed names.
--- Creates "Is <Name> Active?" conditionals for each name and removes stale ones.
local function reconcileConditionals()
  log:trace("reconcileConditionals()")
  local names = getParsedNames()

  -- Build set of desired conditional keys
  local desiredKeys = {}
  for _, name in ipairs(names) do
    desiredKeys[name] = true
  end

  -- Delete conditionals for names that no longer exist
  local allConditionals = conditionals:getConditionals()
  local nsConditionals = allConditionals[NS_CONDITIONALS] or {}
  for key in pairs(nsConditionals) do
    if not desiredKeys[key] then
      log:info("Removing conditional for '%s'", key)
      conditionals:deleteConditional(NS_CONDITIONALS, key)
    end
  end

  -- Create/update conditionals for current names
  for _, name in ipairs(names) do
    conditionals:upsertConditional(NS_CONDITIONALS, name, {
      type = "BOOL",
      condition_statement = name,
      description = "NAME input " .. name .. " is STRING",
      true_text = "Active",
      false_text = "Inactive",
    }, function()
      return getActiveInput() == name
    end)
  end
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

--- Sync a property value to all other instances of this driver.
--- Only syncs if the other instance has a different value (avoids infinite loops).
--- @param propertyName string
--- @param propertyValue string
local function syncPropertyToOtherInstances(propertyName, propertyValue)
  local ids = getDriverIds()
  local myId = C4:GetDeviceID()
  for _, deviceId in ipairs(ids) do
    if deviceId ~= myId then
      log:info("Syncing property '%s' = '%s' to device %d", propertyName, propertyValue, deviceId)
      SetDeviceProperties(deviceId, { [propertyName] = propertyValue }, true)
    end
  end
end
--#endif

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
  values:restoreValues()
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")

  C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")

  --#ifndef DRIVERCENTRAL
  isLeaderInstance = Select(getDriverIds(), 1) == C4:GetDeviceID()
  --#endif
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Ensure output bindings exist
  ensureOutputBindings()

  -- Restore events
  events:restoreEvents()

  -- Fire OnPropertyChanged for all properties (triggers reconciliation)
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    -- Recompute leader each cycle in case the previous leader was removed
    isLeaderInstance = Select(getDriverIds(), 1) == C4:GetDeviceID()
    if isLeaderInstance and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
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
  --#ifndef DRIVERCENTRAL
  if not gInitialized and not isLeaderInstance then
    return
  end
  syncPropertyToOtherInstances("Automatic Updates", propertyValue)
  --#endif
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if not gInitialized and not isLeaderInstance then
    return
  end
  syncPropertyToOtherInstances("Update Channel", propertyValue)
end
--#endif

function OPC.Input_Names(propertyValue)
  log:trace("OPC.Input_Names('%s')", propertyValue)
  local names = parseNames(propertyValue or "")
  setParsedNames(names)

  -- Reconcile bindings, events, conditionals
  reconcileInputBindings()
  ensureSelectionChangedEvent()
  reconcileConditionals()

  -- Validate active selection
  local activeName = getActiveInput()
  if #names == 0 then
    -- Empty names list: deselect
    if activeName ~= nil then
      setActiveInput(nil)
    end
  elseif activeName == nil then
    -- No active selection, select first
    setActiveInput(names[1])
  else
    -- Check if active name still exists
    local found = false
    for _, name in ipairs(names) do
      if name == activeName then
        found = true
        break
      end
    end
    if not found then
      -- Active name removed, select first remaining
      setActiveInput(names[1])
    end
  end

  updateOutputs()
end

function OPC.Enable_Temperature(propertyValue)
  log:trace("OPC.Enable_Temperature('%s')", propertyValue)
  reconcileInputBindings()
  ensureOutputBindings()
  updateOutputs()
end

function OPC.Enable_Humidity(propertyValue)
  log:trace("OPC.Enable_Humidity('%s')", propertyValue)
  reconcileInputBindings()
  ensureOutputBindings()
  updateOutputs()
end

function OPC.Enable_Contact(propertyValue)
  log:trace("OPC.Enable_Contact('%s')", propertyValue)
  reconcileInputBindings()
  ensureOutputBindings()
  updateOutputs()
end

--------------------------------------------------------------------------------
-- Command Handlers
--------------------------------------------------------------------------------

--- Populate the Input parameter dropdown for the Select Input command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of input names.
function GCPL.Select_Input(paramName)
  log:trace("GCPL.Select_Input(%s)", paramName)
  if paramName ~= "Input" then
    return {}
  end
  return getParsedNames()
end

--- Execute the Select Input command.
--- @param params table<string, any> Command parameters containing Input name.
function EC.Select_Input(params)
  log:trace("EC.Select_Input(%s)", params)
  local inputName = Select(params, "Input")
  if IsEmpty(inputName) then
    log:warn("Select Input command called without input name")
    return
  end
  setActiveInput(inputName)
end

--------------------------------------------------------------------------------
-- EC Handlers
--------------------------------------------------------------------------------

--- Cycle to the next input in the parsed names list, wrapping around.
function EC.Cycle_Input()
  log:trace("EC.Cycle_Input()")
  local names = getParsedNames()
  if #names == 0 then
    return
  end
  local activeName = getActiveInput()
  local nextIndex = 1
  for i, name in ipairs(names) do
    if name == activeName then
      nextIndex = (i % #names) + 1
      break
    end
  end
  log:print("Cycling input: %s → %s", activeName or "(none)", names[nextIndex])
  setActiveInput(names[nextIndex])
end

--- Reset driver to initial state
function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")

  -- Reset all dynamic state
  bindings:reset()
  values:reset()
  events:reset()
  conditionals:reset()
  persist:set(PERSIST_INPUT_VALUES, nil)
  persist:set(PERSIST_ACTIVE_INPUT, nil)
  persist:set(PERSIST_PARSED_NAMES, nil)

  -- Reset last output state
  lastContactOutputState = nil

  -- Reset properties to defaults
  local resetValues = GetPropertyResetValues({})
  for propName, defaultValue in pairs(resetValues) do
    UpdateProperty(propName, defaultValue, true)
  end

  -- Recreate output bindings
  ensureOutputBindings()

  -- Re-fire property handlers to reconcile state
  OPC.Input_Names(Properties["Input Names"])
  OPC.Enable_Temperature(Properties["Enable Temperature"])
  OPC.Enable_Humidity(Properties["Enable Humidity"])
  OPC.Enable_Contact(Properties["Enable Contact"])
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
