--- Variable Manipulator Driver
--#ifdef DRIVERCENTRAL
DC_PID = nil
DC_X = nil
DC_FILENAME = "variable_manipulator.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-finite-labs-essentials"
DRIVER_FILENAMES = { "variable_manipulator.c4z" }
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local log = require("lib.logging")
local persist = require("lib.persist")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Output variable holding the most recent Create String result.
local VAR_STRING = "STRING"

--- Output variable holding the most recent Calculate Equation result.
local VAR_NUMBER = "NUMBER"

--- Static event ids (must match driver.xml <events>).
local EVENT_STRING_CREATED = 1
local EVENT_EQUATION_CALCULATED = 2

--- Persist keys for the last computed outputs and rendered expressions
--- (restored on boot).
local PERSIST_STRING = "StringOutput"
local PERSIST_NUMBER = "NumberOutput"
local PERSIST_STRING_EXPR = "StringExpression"
local PERSIST_NUMBER_EXPR = "NumberExpression"

--- Placeholder emitted when a PARAM{} token references a missing variable.
local ERROR_VARIABLE_NOT_FOUND = "ERROR_VARIABLE_NOT_FOUND"

--- Message shown in the Equation Output property when an equation fails.
local ERROR_IN_EQUATION = "ERROR IN EQUATION"

--------------------------------------------------------------------------------
-- Token Substitution
--------------------------------------------------------------------------------

--- Decode the XML entities Composer applies to command string parameters.
--- Composer escapes `<`, `>`, `&`, and quotes, so `a < b` arrives as `a &lt; b`.
--- `&amp;` is decoded first so a double-escaped `&amp;lt;` resolves correctly.
--- @param s string? The raw parameter value.
--- @return string decoded
local function unescapeEntities(s)
  s = s or ""
  s = s:gsub("&amp;", "&")
  s = s:gsub("&lt;", "<")
  s = s:gsub("&gt;", ">")
  s = s:gsub("&quot;", '"')
  s = s:gsub("&#39;", "'")
  s = s:gsub("&apos;", "'")
  return s
end

--- Lua pattern matching a PARAM{device,variable} token, capturing the two ids
--- with surrounding whitespace trimmed.
local PARAM_PATTERN = "PARAM%s*{%s*(.-)%s*,%s*(.-)%s*}"

--- Resolve a variable reference on a device to its numeric id and name.
--- C4:GetVariable requires a numeric variable id, so a name is looked up against
--- the device's variables. A numeric reference is mapped back to its name for
--- display purposes.
--- @param deviceId integer The numeric device id.
--- @param variable string The variable id or name.
--- @return integer|nil variableId The numeric id, or nil if it cannot be resolved.
--- @return string name The variable name, falling back to the raw reference.
local function resolveVariable(deviceId, variable)
  local ok, vars = pcall(function()
    return C4:GetDeviceVariables(deviceId)
  end)
  vars = (ok and type(vars) == "table") and vars or {}
  local asId = tonumber(variable)
  if asId then
    for id, v in pairs(vars) do
      if tonumber(id) == asId and type(v) == "table" then
        return asId, v.name or variable
      end
    end
    return asId, variable
  end
  for id, v in pairs(vars) do
    if type(v) == "table" and v.name == variable then
      return tonumber(id), variable
    end
  end
  return nil, variable
end

--- Read a Control4 variable referenced by a PARAM{} token. The device must be a
--- numeric id; the variable may be a numeric id or a name. Wrapped in pcall so a
--- malformed reference yields nil rather than aborting the whole command.
--- @param device string The device id.
--- @param variable string The variable id or name.
--- @return any|nil value
local function readVariable(device, variable)
  local deviceId = tonumber(device)
  if not deviceId then
    return nil
  end
  local variableId = resolveVariable(deviceId, variable)
  if not variableId then
    return nil
  end
  local ok, value = pcall(function()
    return C4:GetVariable(deviceId, variableId)
  end)
  if not ok then
    return nil
  end
  return value
end

--- Replace every `PARAM{device,variable}` token with the referenced variable's
--- current value. Whitespace around the ids is tolerated. Missing references are
--- replaced with ERROR_VARIABLE_NOT_FOUND and flagged.
--- @param template string The template string or equation.
--- @return string result The substituted string.
--- @return boolean missing True if any referenced variable was not found.
local function substituteTokens(template)
  local missing = false
  local result = template:gsub(PARAM_PATTERN, function(device, variable)
    local value = readVariable(device, variable)
    if value == nil then
      log:warn("Variable not found: device='%s' variable='%s'", device, variable)
      missing = true
      return ERROR_VARIABLE_NOT_FOUND
    end
    return tostring(value)
  end)
  return result, missing
end

--- Render a template into a human-readable form by replacing each PARAM{} token
--- with `[Room > Device > Variable]`. Used to show what an expression references
--- at a glance in the driver properties.
--- @param template string The template string or equation.
--- @return string rendered
local function renderTemplate(template)
  return (
    template:gsub(PARAM_PATTERN, function(device, variable)
      local deviceId = tonumber(device)
      local deviceLabel = "Device " .. device
      local variableLabel = variable
      if deviceId then
        local dev = GetDevice(deviceId)
        if dev and not IsEmpty(dev.displayName) then
          deviceLabel = dev.displayName
        end
        local _, name = resolveVariable(deviceId, variable)
        variableLabel = name
      end
      return string.format("[%s > %s]", deviceLabel, variableLabel)
    end)
  )
end

--------------------------------------------------------------------------------
-- Equation Evaluation
--------------------------------------------------------------------------------

--- The sandbox environment equations are evaluated in. Exposes the math library
--- plus a handful of bare helpers so installers can write `abs(a - b)` directly.
--- Nothing else (including driver globals) is reachable from an equation.
local EQUATION_ENV = {
  math = math,
  abs = math.abs,
  ceil = math.ceil,
  floor = math.floor,
  sqrt = math.sqrt,
  min = math.min,
  max = math.max,
  pi = math.pi,
  huge = math.huge,
  round = round,
  tonumber = tonumber,
  tostring = tostring,
}

--- Evaluate a substituted equation string as a Lua numeric expression.
--- @param expression string The equation with tokens already substituted.
--- @return number|nil result The numeric result, or nil on failure.
--- @return string? err The compile or runtime error, when result is nil.
local function evaluateEquation(expression)
  local fn, compileErr = loadstring("return " .. expression)
  if not fn then
    return nil, compileErr
  end
  setfenv(fn, EQUATION_ENV)
  local ok, result = pcall(fn)
  if not ok then
    return nil, result
  end
  if type(result) ~= "number" then
    return nil, string.format("result is not a number (got %s)", type(result))
  end
  return result
end

--------------------------------------------------------------------------------
-- Output Variables
--------------------------------------------------------------------------------

--- Create the STRING and NUMBER output variables if they do not already exist,
--- seeding them with the last persisted values so they survive a driver restart.
local function ensureOutputVariables()
  if Variables[VAR_STRING] == nil then
    C4:AddVariable(VAR_STRING, persist:get(PERSIST_STRING, "") or "", "STRING", true, false)
  end
  if Variables[VAR_NUMBER] == nil then
    C4:AddVariable(VAR_NUMBER, persist:get(PERSIST_NUMBER, 0) or 0, "NUMBER", true, false)
  end
end

--------------------------------------------------------------------------------
-- Multi-instance helpers
--------------------------------------------------------------------------------

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
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")

  C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")

  if not CheckMinimumVersion("Driver Status") then
    return
  end

  ensureOutputVariables()

  -- Fire OnPropertyChanged for all properties to set initial global state
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  -- Reflect the last computed outputs and rendered expressions in the properties
  UpdateProperty("String Output", persist:get(PERSIST_STRING, "") or "")
  UpdateProperty("String Expression", persist:get(PERSIST_STRING_EXPR, "") or "")
  UpdateProperty("Equation Output", tostring(persist:get(PERSIST_NUMBER, "") or ""))
  UpdateProperty("Equation Expression", persist:get(PERSIST_NUMBER_EXPR, "") or "")

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
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Automatic Updates", propertyValue)
  --#endif
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Update Channel", propertyValue)
end
--#endif

--------------------------------------------------------------------------------
-- Token Builder (property helper)
--------------------------------------------------------------------------------

--- Parse the value of a VARIABLE_SELECTOR property, which Composer stores as
--- "deviceId,variableId", into its two numeric ids.
--- @param value any The raw property value.
--- @return integer|nil deviceId
--- @return integer|nil variableId
local function parseVariableReference(value)
  local deviceId, variableId = tostring(value or ""):match("(%d+)%s*,%s*(%d+)")
  return tonumber(deviceId), tonumber(variableId)
end

--- When a variable is selected in the Token Builder, build its PARAM{} token
--- into the Reference Token property for the installer to copy.
function OPC.Reference_Variable(propertyValue)
  log:trace("OPC.Reference_Variable('%s')", propertyValue)
  local deviceId, variableId = parseVariableReference(propertyValue)
  if deviceId and variableId then
    UpdateProperty("Reference Token", string.format("PARAM{%d,%d}", deviceId, variableId))
  else
    UpdateProperty("Reference Token", "")
  end
end

--------------------------------------------------------------------------------
-- Programming Command Handlers (EC)
--------------------------------------------------------------------------------

--- Create String command handler.
--- Substitutes PARAM{} tokens in the template and publishes the result to the
--- STRING variable, the String Output property, and the String Created event.
--- @param params table Command parameters: String.
function EC.Create_String(params)
  log:trace("EC.Create_String(%s)", params)
  local template = unescapeEntities(Select(params, "String") or "")
  local result = substituteTokens(template)
  local rendered = renderTemplate(template)

  log:info("Create String: %s => '%s'", rendered, result)
  persist:set(PERSIST_STRING, result)
  persist:set(PERSIST_STRING_EXPR, rendered)
  C4:SetVariable(VAR_STRING, result)
  UpdateProperty("String Output", result)
  UpdateProperty("String Expression", rendered)
  C4:FireEvent(EVENT_STRING_CREATED)
end

--- Calculate Equation command handler.
--- Substitutes PARAM{} tokens, evaluates the result as a numeric expression, and
--- publishes it to the NUMBER variable, the Equation Output property, and the
--- Equation Calculated event. Reference or evaluation errors leave the previous
--- NUMBER value untouched and surface ERROR IN EQUATION in the property.
--- @param params table Command parameters: Equation.
function EC.Calculate_Equation(params)
  log:trace("EC.Calculate_Equation(%s)", params)
  local template = unescapeEntities(Select(params, "Equation") or "")
  local expression, missing = substituteTokens(template)
  local rendered = renderTemplate(template)
  UpdateProperty("Equation Expression", rendered)

  if missing then
    log:warn("Calculate Equation: unresolved variable in %s", rendered)
    UpdateProperty("Equation Output", ERROR_IN_EQUATION)
    return
  end

  local result, err = evaluateEquation(expression)
  if result == nil then
    log:warn("Calculate Equation: failed to evaluate '%s': %s", expression, tostring(err))
    UpdateProperty("Equation Output", ERROR_IN_EQUATION)
    return
  end

  log:info("Calculate Equation: %s = %s", rendered, result)
  persist:set(PERSIST_NUMBER, result)
  persist:set(PERSIST_NUMBER_EXPR, rendered)
  C4:SetVariable(VAR_NUMBER, result)
  UpdateProperty("Equation Output", tostring(result))
  C4:FireEvent(EVENT_EQUATION_CALCULATED)
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

  persist:reset({ PERSIST_STRING, PERSIST_NUMBER, PERSIST_STRING_EXPR, PERSIST_NUMBER_EXPR })
  C4:SetVariable(VAR_STRING, "")
  C4:SetVariable(VAR_NUMBER, 0)

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
