--- Sensor Aggregator Driver
--#ifdef DRIVERCENTRAL
DC_PID = nil
DC_X = nil
DC_FILENAME = "sensor_aggregator.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-finite-labs-essentials"
DRIVER_FILENAMES = { "sensor_aggregator.c4z" }
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
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Namespaces for dynamic bindings
local NS_TEMP_IN = "TempIn"
local NS_HUM_IN = "HumIn"
local NS_OUTPUT = "Output"

--- Output binding keys
local OUTPUT_TEMP = "temperature"
local OUTPUT_HUM = "humidity"

--- Persist keys for cached input values
local PERSIST_TEMP_VALUES = "TempInputValues"
local PERSIST_HUM_VALUES = "HumInputValues"
local PERSIST_CONTACT_VALUES = "ContactInputValues"

--- Namespace for contact input bindings
local NS_CONTACT_IN = "ContactIn"

--- Output binding key for contact
local OUTPUT_CONTACT = "contact"

--- Aggregation function names (numeric)
local AGG_MEAN = "Mean"
local AGG_MEDIAN = "Median"
local AGG_MODE = "Mode"
local AGG_MIN = "Min"
local AGG_MAX = "Max"
local AGG_IQR_MEAN = "IQR Mean"

--- Aggregation function names (boolean)
local AGG_ANY = "Any"
local AGG_ALL = "All"
local AGG_MAJORITY = "Majority"

--------------------------------------------------------------------------------
-- Aggregation Functions
--------------------------------------------------------------------------------

--- Compute the mean of a list of numbers.
--- @param vals number[]
--- @return number|nil
local function calcMean(vals)
  if #vals == 0 then
    return nil
  end
  local sum = 0
  for _, v in ipairs(vals) do
    sum = sum + v
  end
  return round(sum / #vals, 1)
end

--- Compute the median of a list of numbers.
--- @param vals number[]
--- @return number|nil
local function calcMedian(vals)
  if #vals == 0 then
    return nil
  end
  local sorted = {}
  for _, v in ipairs(vals) do
    table.insert(sorted, v)
  end
  table.sort(sorted)
  local n = #sorted
  if n % 2 == 1 then
    return sorted[math.ceil(n / 2)]
  else
    return round((sorted[n / 2] + sorted[n / 2 + 1]) / 2, 1)
  end
end

--- Compute the mode of a list of numbers (most frequent value).
--- Ties are broken by returning the smallest value.
--- @param vals number[]
--- @return number|nil
local function calcMode(vals)
  if #vals == 0 then
    return nil
  end
  local counts = {}
  for _, v in ipairs(vals) do
    local key = tostring(v)
    counts[key] = (counts[key] or 0) + 1
  end
  local bestVal, bestCount = nil, 0
  for key, count in pairs(counts) do
    local num = tonumber(key)
    if count > bestCount or (count == bestCount and (bestVal == nil or num < bestVal)) then
      bestVal = num
      bestCount = count
    end
  end
  return bestVal
end

--- Compute the minimum of a list of numbers.
--- @param vals number[]
--- @return number|nil
local function calcMin(vals)
  if #vals == 0 then
    return nil
  end
  local m = vals[1]
  for i = 2, #vals do
    if vals[i] < m then
      m = vals[i]
    end
  end
  return m
end

--- Compute the maximum of a list of numbers.
--- @param vals number[]
--- @return number|nil
local function calcMax(vals)
  if #vals == 0 then
    return nil
  end
  local m = vals[1]
  for i = 2, #vals do
    if vals[i] > m then
      m = vals[i]
    end
  end
  return m
end

--- Compute the IQR-filtered mean of a list of numbers.
--- Excludes values outside 1.5x the interquartile range, then averages the rest.
--- With fewer than 4 values, falls back to a regular mean.
--- @param vals number[]
--- @return number|nil
local function calcIQRMean(vals)
  if #vals == 0 then
    return nil
  end
  if #vals < 4 then
    return calcMean(vals)
  end
  local sorted = {}
  for _, v in ipairs(vals) do
    table.insert(sorted, v)
  end
  table.sort(sorted)
  local n = #sorted
  local q1Idx = math.ceil(n * 0.25)
  local q3Idx = math.ceil(n * 0.75)
  local q1 = sorted[q1Idx]
  local q3 = sorted[q3Idx]
  local iqr = q3 - q1
  local lower = q1 - 1.5 * iqr
  local upper = q3 + 1.5 * iqr
  local filtered = {}
  for _, v in ipairs(sorted) do
    if v >= lower and v <= upper then
      table.insert(filtered, v)
    end
  end
  if #filtered == 0 then
    return calcMean(vals)
  end
  return calcMean(filtered)
end

--- Map of aggregation function names to functions.
local AGG_FUNCTIONS = {
  [AGG_MEAN] = calcMean,
  [AGG_MEDIAN] = calcMedian,
  [AGG_MODE] = calcMode,
  [AGG_MIN] = calcMin,
  [AGG_MAX] = calcMax,
  [AGG_IQR_MEAN] = calcIQRMean,
}

--------------------------------------------------------------------------------
-- Boolean Aggregation Functions
--------------------------------------------------------------------------------

--- Returns true if any value is true.
--- @param vals boolean[]
--- @return boolean|nil
local function calcAny(vals)
  if #vals == 0 then
    return nil
  end
  for _, v in ipairs(vals) do
    if v then
      return true
    end
  end
  return false
end

--- Returns true only if all values are true.
--- @param vals boolean[]
--- @return boolean|nil
local function calcAll(vals)
  if #vals == 0 then
    return nil
  end
  for _, v in ipairs(vals) do
    if not v then
      return false
    end
  end
  return true
end

--- Returns true if more than half of the values are true.
--- @param vals boolean[]
--- @return boolean|nil
local function calcMajority(vals)
  if #vals == 0 then
    return nil
  end
  local trueCount = 0
  for _, v in ipairs(vals) do
    if v then
      trueCount = trueCount + 1
    end
  end
  return trueCount > #vals / 2
end

--- Map of boolean aggregation function names to functions.
local BOOL_AGG_FUNCTIONS = {
  [AGG_ANY] = calcAny,
  [AGG_ALL] = calcAll,
  [AGG_MAJORITY] = calcMajority,
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

--- Current aggregation function setting for temperature
local tempAggregationFunction = AGG_MEAN

--- Current aggregation function setting for humidity
local humAggregationFunction = AGG_MEAN

--- Current aggregation function setting for contact
local contactAggregationFunction = AGG_ANY

--- Last output state for change detection (avoids redundant NOTIFY commands)
local lastContactOutputState = nil

--------------------------------------------------------------------------------
-- Value Cache Helpers
--------------------------------------------------------------------------------

--- Get non-nil numeric values from the input cache.
--- @param persistKey string
--- @return number[]
local function getActiveValues(persistKey)
  local cache = persist:get(persistKey, {})
  local vals = {}
  for _, v in pairs(cache) do
    if type(v) == "number" then
      table.insert(vals, v)
    end
  end
  return vals
end

--- Get non-nil boolean values from the input cache.
--- @param persistKey string
--- @return boolean[]
local function getActiveBoolValues(persistKey)
  local cache = persist:get(persistKey, {})
  local vals = {}
  for _, v in pairs(cache) do
    if type(v) == "boolean" then
      table.insert(vals, v)
    end
  end
  return vals
end

--- Set a cached input value.
--- @param persistKey string
--- @param key string
--- @param value number|boolean|nil
local function setCachedValue(persistKey, key, value)
  local cache = persist:get(persistKey, {})
  cache[key] = value
  persist:set(persistKey, cache)
end

--- Clear a cached input value.
--- @param persistKey string
--- @param key string
local function clearCachedValue(persistKey, key)
  setCachedValue(persistKey, key, nil)
end

--------------------------------------------------------------------------------
-- Output Binding Helpers
--------------------------------------------------------------------------------

--- Get or create an output binding.
--- @param key string OUTPUT_TEMP or OUTPUT_HUM
--- @param displayName string
--- @param bindingClass string
--- @return Binding|nil
local function getOrCreateOutputBinding(key, displayName, bindingClass)
  local binding = bindings:getOrAddDynamicBinding(NS_OUTPUT, key, "CONTROL", true, displayName, bindingClass)
  return binding
end

--- Send aggregated value to the output binding.
--- @param outputKey string OUTPUT_TEMP or OUTPUT_HUM
--- @param value number|nil
--- @param scale string
local function sendAggregatedValue(outputKey, value, scale)
  local binding = bindings:getDynamicBinding(NS_OUTPUT, outputKey)
  if binding and value then
    SendToProxy(binding.bindingId, "VALUE_CHANGED", { VALUE = value, SCALE = scale })
  end
end

--- Send contact output for runtime state changes (triggers programming events).
--- @param outputKey string
--- @param value boolean|nil
local function sendContactOutput(outputKey, value)
  local binding = bindings:getDynamicBinding(NS_OUTPUT, outputKey)
  if binding and value ~= nil then
    SendToProxy(binding.bindingId, value and "CLOSED" or "OPENED", {}, "NOTIFY")
  end
end

--- Send contact state for init/bind (no programming event trigger).
--- @param outputKey string
--- @param value boolean|nil
local function sendContactState(outputKey, value)
  local binding = bindings:getDynamicBinding(NS_OUTPUT, outputKey)
  if binding and value ~= nil then
    SendToProxy(binding.bindingId, value and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
  end
end

--------------------------------------------------------------------------------
-- Recalculation
--------------------------------------------------------------------------------

--- Recalculate the aggregated temperature and update outputs/properties.
local function recalcTemperature()
  log:trace("recalcTemperature()")
  local vals = getActiveValues(PERSIST_TEMP_VALUES)
  local aggFunc = AGG_FUNCTIONS[tempAggregationFunction] or calcMean
  local result = aggFunc(vals)

  UpdateProperty("Active Temperature Inputs", tostring(#vals), true)

  if result then
    UpdateProperty("Aggregated Temperature C", tostring(result) .. " °C", true)
    UpdateProperty("Aggregated Temperature F", tostring(c2f(result)) .. " °F", true)
    sendAggregatedValue(OUTPUT_TEMP, result, "CELSIUS")
  else
    UpdateProperty("Aggregated Temperature C", "", true)
    UpdateProperty("Aggregated Temperature F", "", true)
  end

  if #vals > 0 then
    UpdateProperty("Driver Status", "Active")
  end
end

--- Recalculate the aggregated humidity and update outputs/properties.
local function recalcHumidity()
  log:trace("recalcHumidity()")
  local vals = getActiveValues(PERSIST_HUM_VALUES)
  local aggFunc = AGG_FUNCTIONS[humAggregationFunction] or calcMean
  local result = aggFunc(vals)

  UpdateProperty("Active Humidity Inputs", tostring(#vals), true)

  if result then
    UpdateProperty("Aggregated Humidity", tostring(result) .. " %", true)
    sendAggregatedValue(OUTPUT_HUM, result, "PERCENT")
  else
    UpdateProperty("Aggregated Humidity", "", true)
  end

  if #vals > 0 then
    UpdateProperty("Driver Status", "Active")
  end
end

--- Recalculate the aggregated contact state and update outputs/properties.
local function recalcContact()
  log:trace("recalcContact()")
  local vals = getActiveBoolValues(PERSIST_CONTACT_VALUES)
  local aggFunc = BOOL_AGG_FUNCTIONS[contactAggregationFunction] or calcAny
  local result = aggFunc(vals)

  UpdateProperty("Active Contact Inputs", tostring(#vals), true)

  if result ~= nil then
    UpdateProperty("Aggregated Contact", result and "Closed" or "Open", true)
    if result ~= lastContactOutputState then
      lastContactOutputState = result
      if gInitialized then
        sendContactOutput(OUTPUT_CONTACT, result)
      else
        sendContactState(OUTPUT_CONTACT, result)
      end
    end
  else
    UpdateProperty("Aggregated Contact", "", true)
    lastContactOutputState = nil
  end

  if #vals > 0 then
    UpdateProperty("Driver Status", "Active")
  end
end

--------------------------------------------------------------------------------
-- Handler Registration for Input Bindings
--------------------------------------------------------------------------------

--- Register RFP and OBC handlers for an input binding.
--- @param binding Binding
--- @param persistKey string
--- @param recalcFn function
local function registerInputHandlers(binding, persistKey, recalcFn)
  -- RFP handler: receive VALUE_CHANGED from provider
  RFP[binding.bindingId] = function(idBinding, strCommand, tParams, _args)
    log:trace("RFP[%s](%s, %s, %s)", binding.bindingId, idBinding, strCommand, tParams)
    if strCommand == "VALUE_CHANGED" then
      local value = tonumber(Select(tParams, "VALUE"))
      if value then
        setCachedValue(persistKey, binding.key, value)
        recalcFn()
      end
    end
  end

  -- OBC handler: clear cached value when input unbinds
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
      clearCachedValue(persistKey, binding.key)
      recalcFn()
    end
  end
end

--- Register RFP and OBC handlers for an output binding.
--- @param binding Binding
--- @param outputKey string
--- @param scale string
--- @param persistKey string
local function registerOutputHandlers(binding, outputKey, scale, persistKey)
  -- RFP handler: respond to GET_VALUE
  RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
    log:trace("RFP[%s](%s, %s)", binding.bindingId, idBinding, strCommand)
    if strCommand == "GET_VALUE" then
      local vals = getActiveValues(persistKey)
      local aggFuncName = outputKey == OUTPUT_TEMP and tempAggregationFunction or humAggregationFunction
      local aggFunc = AGG_FUNCTIONS[aggFuncName] or calcMean
      local result = aggFunc(vals)
      if result then
        SendToProxy(idBinding, "VALUE_CHANGED", { VALUE = result, SCALE = scale })
      end
    end
  end

  -- OBC handler: send current aggregate when consumer connects
  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    if bIsBound then
      local vals = getActiveValues(persistKey)
      local aggFuncName = outputKey == OUTPUT_TEMP and tempAggregationFunction or humAggregationFunction
      local aggFunc = AGG_FUNCTIONS[aggFuncName] or calcMean
      local result = aggFunc(vals)
      if result then
        SendToProxy(idBinding, "VALUE_CHANGED", { VALUE = result, SCALE = scale })
      end
    end
  end
end

--- Register RFP and OBC handlers for a contact input binding.
--- @param binding Binding
--- @param persistKey string
--- @param recalcFn function
local function registerContactInputHandlers(binding, persistKey, recalcFn)
  -- RFP handler: receive OPENED/CLOSED from provider
  RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
    log:trace("RFP[%s](%s, %s)", binding.bindingId, idBinding, strCommand)
    if strCommand == "CLOSED" or strCommand == "STATE_CLOSED" then
      setCachedValue(persistKey, binding.key, true)
      recalcFn()
    elseif strCommand == "OPENED" or strCommand == "STATE_OPENED" then
      setCachedValue(persistKey, binding.key, false)
      recalcFn()
    end
  end

  -- OBC handler: clear cached value when input unbinds
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
      clearCachedValue(persistKey, binding.key)
      recalcFn()
    end
  end
end

--- Register OBC handler for a contact output binding.
--- @param binding Binding
--- @param outputKey string
--- @param persistKey string
--- @param getAggFn function Returns the current aggregation function name
local function registerContactOutputHandlers(binding, outputKey, persistKey, getAggFn)
  -- No RFP handler (contact sensors are push-only, no GET_VALUE)

  -- OBC handler: send current state when consumer connects
  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s, %s)", binding.bindingId, idBinding, _strClass, bIsBound)
    if bIsBound then
      local vals = getActiveBoolValues(persistKey)
      local aggFuncName = getAggFn()
      local aggFunc = BOOL_AGG_FUNCTIONS[aggFuncName] or calcAny
      local result = aggFunc(vals)
      if result ~= nil then
        -- Use STATE_ prefix on bind to set state without triggering programming events
        SendToProxy(idBinding, result and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Binding Reconciliation
--------------------------------------------------------------------------------

--- Reconcile input bindings to match the desired count.
--- @param namespace string
--- @param desiredCount number
--- @param bindingType string "CONTROL" or "PROXY"
--- @param bindingClass string e.g. "TEMPERATURE_VALUE", "CONTACT_SENSOR"
--- @param displayPrefix string e.g. "Temperature Input"
--- @param persistKey string
--- @param recalcFn function
--- @param registerHandlersFn function
local function reconcileInputBindings(
  namespace,
  desiredCount,
  bindingType,
  bindingClass,
  displayPrefix,
  persistKey,
  recalcFn,
  registerHandlersFn
)
  log:info("reconcileInputBindings(%s, %d)", namespace, desiredCount)

  local existing = bindings:getDynamicBindings(namespace)

  -- Count existing bindings
  local existingCount = 0
  for _ in pairs(existing) do
    existingCount = existingCount + 1
  end

  -- Add bindings for new indices
  for i = existingCount + 1, desiredCount do
    local key = "input_" .. i
    local displayName = displayPrefix .. " " .. i
    local binding = bindings:getOrAddDynamicBinding(namespace, key, bindingType, false, displayName, bindingClass)
    if binding then
      log:info("Created input binding %s (id=%s)", displayName, binding.bindingId)
    end
  end

  -- Remove bindings for indices beyond desired count
  for i = desiredCount + 1, existingCount do
    local key = "input_" .. i
    clearCachedValue(persistKey, key)
    bindings:deleteBinding(namespace, key)
    log:info("Removed input binding %s %d", displayPrefix, i)
  end

  -- Re-register handlers for all active bindings
  local activeBindings = bindings:getDynamicBindings(namespace)
  for _, binding in pairs(activeBindings) do
    registerHandlersFn(binding, persistKey, recalcFn)
  end

  recalcFn()
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
  values:restoreValues()
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

function OPC.Temperature_Inputs(propertyValue)
  log:trace("OPC.Temperature_Inputs('%s')", propertyValue)
  local count = tointeger(propertyValue) or 2

  if count > 0 then
    local tempBinding = getOrCreateOutputBinding(OUTPUT_TEMP, "Aggregated Temperature", "TEMPERATURE_VALUE")
    if tempBinding then
      registerOutputHandlers(tempBinding, OUTPUT_TEMP, "CELSIUS", PERSIST_TEMP_VALUES)
    end
    C4:SetPropertyAttribs("Aggregated Temperature C", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Aggregated Temperature F", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Active Temperature Inputs", constants.SHOW_PROPERTY)
  else
    bindings:deleteBinding(NS_OUTPUT, OUTPUT_TEMP)
    UpdateProperty("Aggregated Temperature C", "", true)
    UpdateProperty("Aggregated Temperature F", "", true)
    C4:SetPropertyAttribs("Aggregated Temperature C", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Aggregated Temperature F", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Active Temperature Inputs", constants.HIDE_PROPERTY)
  end

  reconcileInputBindings(
    NS_TEMP_IN,
    count,
    "CONTROL",
    "TEMPERATURE_VALUE",
    "Temperature Input",
    PERSIST_TEMP_VALUES,
    recalcTemperature,
    registerInputHandlers
  )
end

function OPC.Humidity_Inputs(propertyValue)
  log:trace("OPC.Humidity_Inputs('%s')", propertyValue)
  local count = tointeger(propertyValue) or 2

  if count > 0 then
    local humBinding = getOrCreateOutputBinding(OUTPUT_HUM, "Aggregated Humidity", "HUMIDITY_VALUE")
    if humBinding then
      registerOutputHandlers(humBinding, OUTPUT_HUM, "PERCENT", PERSIST_HUM_VALUES)
    end
    C4:SetPropertyAttribs("Aggregated Humidity", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Active Humidity Inputs", constants.SHOW_PROPERTY)
  else
    bindings:deleteBinding(NS_OUTPUT, OUTPUT_HUM)
    UpdateProperty("Aggregated Humidity", "", true)
    C4:SetPropertyAttribs("Aggregated Humidity", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Active Humidity Inputs", constants.HIDE_PROPERTY)
  end

  reconcileInputBindings(
    NS_HUM_IN,
    count,
    "CONTROL",
    "HUMIDITY_VALUE",
    "Humidity Input",
    PERSIST_HUM_VALUES,
    recalcHumidity,
    registerInputHandlers
  )
end

function OPC.Contact_Inputs(propertyValue)
  log:trace("OPC.Contact_Inputs('%s')", propertyValue)
  local count = tointeger(propertyValue) or 0

  if count > 0 then
    local contactBinding =
      bindings:getOrAddDynamicBinding(NS_OUTPUT, OUTPUT_CONTACT, "PROXY", true, "Aggregated Contact", "CONTACT_SENSOR")
    if contactBinding then
      registerContactOutputHandlers(contactBinding, OUTPUT_CONTACT, PERSIST_CONTACT_VALUES, function()
        return contactAggregationFunction
      end)
    end
    C4:SetPropertyAttribs("Aggregated Contact", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Active Contact Inputs", constants.SHOW_PROPERTY)
  else
    bindings:deleteBinding(NS_OUTPUT, OUTPUT_CONTACT)
    UpdateProperty("Aggregated Contact", "", true)
    C4:SetPropertyAttribs("Aggregated Contact", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Active Contact Inputs", constants.HIDE_PROPERTY)
    lastContactOutputState = nil
  end

  reconcileInputBindings(
    NS_CONTACT_IN,
    count,
    "PROXY",
    "CONTACT_SENSOR",
    "Contact Input",
    PERSIST_CONTACT_VALUES,
    recalcContact,
    registerContactInputHandlers
  )
end

function OPC.Temperature_Aggregation(propertyValue)
  log:trace("OPC.Temperature_Aggregation('%s')", propertyValue)
  tempAggregationFunction = propertyValue or AGG_MEAN
  recalcTemperature()
end

function OPC.Humidity_Aggregation(propertyValue)
  log:trace("OPC.Humidity_Aggregation('%s')", propertyValue)
  humAggregationFunction = propertyValue or AGG_MEAN
  recalcHumidity()
end

function OPC.Contact_Aggregation(propertyValue)
  log:trace("OPC.Contact_Aggregation('%s')", propertyValue)
  contactAggregationFunction = propertyValue or AGG_ANY
  recalcContact()
end

--------------------------------------------------------------------------------
-- EC Handlers
--------------------------------------------------------------------------------

--- Get the display name of the device bound to a given input binding.
--- @param bindingId number
--- @return string|nil
local function getBoundDeviceName(bindingId)
  local providerId = C4:GetBoundProviderDevice(C4:GetDeviceID(), bindingId)
  if providerId and providerId ~= 0 then
    return C4:GetDeviceDisplayName(providerId)
  end
  return nil
end

--- Print a calibration report for a set of input bindings.
--- @param namespace string NS_TEMP_IN or NS_HUM_IN
--- @param persistKey string
--- @param aggFuncName string
--- @param label string e.g. "Temperature" or "Humidity"
--- @param unit string e.g. "°C" or "%"
--- @param showFahrenheit boolean? If true, also show Fahrenheit values and deltas
local function printCalibrationReport(namespace, persistKey, aggFuncName, label, unit, showFahrenheit)
  local allBindings = bindings:getDynamicBindings(namespace)

  -- Sort bindings by key for consistent output order
  local sorted = {}
  for key, binding in pairs(allBindings) do
    table.insert(sorted, { key = key, binding = binding })
  end
  table.sort(sorted, function(a, b)
    return a.key < b.key
  end)

  -- Compute aggregate
  local aggFunc = AGG_FUNCTIONS[aggFuncName] or calcMean
  local vals = getActiveValues(persistKey)
  local aggregate = aggFunc(vals)

  -- Print header
  log:print("=== %s Calibration Report (%s) ===", label, aggFuncName)
  if aggregate then
    if showFahrenheit then
      log:print("Aggregate: %s°C / %s°F", aggregate, c2f(aggregate))
    else
      log:print("Aggregate: %s %s", aggregate, unit)
    end
  else
    log:print("Aggregate: (no values)")
  end

  -- Print each binding
  local cache = persist:get(persistKey, {})
  for _, entry in ipairs(sorted) do
    local binding = entry.binding
    local cachedValue = cache[entry.key]
    local deviceName = getBoundDeviceName(binding.bindingId)

    if not deviceName then
      log:print("  (not bound) (%s): (no value)", binding.displayName)
    elseif cachedValue == nil then
      log:print("  %s (%s): (no value)", deviceName, binding.displayName)
    elseif aggregate then
      local deltaC = round(aggregate - cachedValue, 1)
      local signC = deltaC >= 0 and "+" or ""
      if showFahrenheit then
        local deltaF = round(deltaC * 9 / 5, 1)
        local signF = deltaF >= 0 and "+" or ""
        log:print(
          "  %s (%s): %s°C / %s°F → adjust by %s%s°C / %s%s°F",
          deviceName,
          binding.displayName,
          cachedValue,
          c2f(cachedValue),
          signC,
          deltaC,
          signF,
          deltaF
        )
      else
        log:print(
          "  %s (%s): %s %s → adjust by %s%s",
          deviceName,
          binding.displayName,
          cachedValue,
          unit,
          signC,
          deltaC
        )
      end
    else
      if showFahrenheit then
        log:print("  %s (%s): %s°C / %s°F", deviceName, binding.displayName, cachedValue, c2f(cachedValue))
      else
        log:print("  %s (%s): %s %s", deviceName, binding.displayName, cachedValue, unit)
      end
    end
  end
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
  persist:set(PERSIST_TEMP_VALUES, nil)
  persist:set(PERSIST_HUM_VALUES, nil)
  persist:set(PERSIST_CONTACT_VALUES, nil)

  -- Reset last output state
  lastContactOutputState = nil

  -- Reset properties to defaults
  local resetValues = GetPropertyResetValues({})
  for propName, defaultValue in pairs(resetValues) do
    UpdateProperty(propName, defaultValue, true)
  end

  -- Re-reconcile input bindings from current property values
  OPC.Temperature_Inputs(Properties["Temperature Inputs"])
  OPC.Humidity_Inputs(Properties["Humidity Inputs"])
  OPC.Contact_Inputs(Properties["Contact Inputs"])
end

--- Print calibration report showing how each input differs from the aggregate
function EC.PrintCalibrationReport()
  printCalibrationReport(NS_TEMP_IN, PERSIST_TEMP_VALUES, tempAggregationFunction, "Temperature", "°C", true)
  printCalibrationReport(NS_HUM_IN, PERSIST_HUM_VALUES, humAggregationFunction, "Humidity", "%")
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
