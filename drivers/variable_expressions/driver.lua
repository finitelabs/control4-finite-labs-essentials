--- Variable Expressions Driver
--#ifdef DRIVERCENTRAL
DC_PID = nil
DC_X = nil
DC_FILENAME = "variable_expressions.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-finite-labs-essentials"
DRIVER_FILENAMES = { "variable_expressions.c4z" }
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local transform = require("lib.transform")
local values = require("lib.values")
local events = require("lib.events")
local ExpressionEngine = require("lib.expressions")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Namespace for dynamic per-expression events.
local NS_EXPRESSION = "Expression"

--- Suffix appended to an expression name to form its output variable.
local RESULT_SUFFIX = " Result"

--- Debounce window for auto recompute of expressions (trailing edge).
local RECALC_DEBOUNCE_MS = 1000

--- Persist keys for named expressions and their last results.
local PERSIST_EXPRESSIONS = "Expressions"
local PERSIST_RESULTS = "ExpressionResults"

--- Placeholder emitted when a PARAM{} token references a missing variable.
local ERROR_VARIABLE_NOT_FOUND = "ERROR_VARIABLE_NOT_FOUND"

--------------------------------------------------------------------------------
-- Token Substitution
--------------------------------------------------------------------------------

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
--- at a glance.
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

--- Extract the resolvable variable references from a template.
--- Unresolvable tokens are skipped; they surface as evaluation errors instead.
--- @param template string The template string or equation.
--- @return { deviceId: integer, variableId: integer }[] refs
local function extractReferences(template)
  local refs = {}
  for device, variable in template:gmatch(PARAM_PATTERN) do
    local deviceId = tonumber(device)
    if deviceId then
      local variableId = resolveVariable(deviceId, variable)
      if variableId then
        refs[#refs + 1] = { deviceId = deviceId, variableId = variableId }
      end
    end
  end
  return refs
end

--------------------------------------------------------------------------------
-- Evaluation
--------------------------------------------------------------------------------

--- Evaluate a substituted equation string as a numeric expression in the
--- shared sandbox.
--- @param expression string The equation with tokens already substituted.
--- @return number|nil result The numeric result, or nil on failure.
--- @return string? err The compile or runtime error, when result is nil.
local function evaluateEquation(expression)
  local result, err = transform.eval(expression)
  if err then
    return nil, err
  end
  if type(result) ~= "number" then
    return nil, string.format("result is not a number (got %s)", type(result))
  end
  return result
end

--- Evaluate a template in either mode without touching any outputs.
--- @param mode string "equation" or "string".
--- @param template string The template with PARAM{} tokens.
--- @return table eval { rendered, substituted, result?, error? }
local function evaluateTemplate(mode, template)
  local substituted, missing = substituteTokens(template or "")
  local rendered = renderTemplate(template or "")
  if missing then
    return { rendered = rendered, substituted = substituted, error = "unresolved variable reference" }
  end
  if mode == "string" then
    return { rendered = rendered, substituted = substituted, result = substituted }
  end
  local result, err = evaluateEquation(substituted)
  if result == nil then
    return { rendered = rendered, substituted = substituted, error = err or "unknown error" }
  end
  return { rendered = rendered, substituted = substituted, result = result }
end

--------------------------------------------------------------------------------
-- Named Expressions
--------------------------------------------------------------------------------

--- Get the configured expressions.
--- @return table<string, table> expressions Map of name -> { name, mode, template, auto }.
local function getExpressions()
  return persist:get(PERSIST_EXPRESSIONS, {}) or {}
end

--- Save the configured expressions.
--- @param expressions table<string, table>
local function saveExpressions(expressions)
  persist:set(PERSIST_EXPRESSIONS, not IsEmpty(expressions) and expressions or nil)
end

--- Get the last results per expression.
--- @return table<string, table> results Map of name -> { result?, error?, rendered, ts }.
local function getResults()
  return persist:get(PERSIST_RESULTS, {}) or {}
end

--- Save a single expression result entry and push it to the tab UI.
--- @param name string
--- @param entry table
local function setResult(name, entry)
  local results = getResults()
  results[name] = entry
  persist:set(PERSIST_RESULTS, results)
  C4:SendDataToUI("EXPRESSION_RESULT", {
    name = name,
    result = entry.result or "",
    error = entry.error or "",
    rendered = entry.rendered or "",
    ts = entry.ts or os.time(),
  })
end

--- Output variable name for an expression.
--- @param name string
--- @return string
local function outputVariableName(name)
  return name .. RESULT_SUFFIX
end

--- Ensure the dynamic event for an expression exists.
--- @param name string
local function ensureExpressionEvent(name)
  events:getOrAddEvent(
    NS_EXPRESSION,
    name,
    name .. " Calculated",
    string.format("Fires after expression '%s' recalculates.", name)
  )
end

--- Forward declaration; assigned after the engine is constructed.
--- @type fun(varName: string, excludeName: string?)
local notifyOwnVariableChanged

--- Recompute a named expression: evaluate, publish outputs, fire its event,
--- and push the result to the tab UI. Evaluation errors preserve the previous
--- output value and surface as a row state instead.
--- @param name string
--- @return table|nil entry The stored result entry, or nil if not configured.
local function recomputeExpression(name)
  log:trace("recomputeExpression('%s')", name)
  local config = getExpressions()[name]
  if not config then
    return nil
  end

  local eval = evaluateTemplate(config.mode, config.template)
  local entry = {
    rendered = eval.rendered,
    ts = os.time(),
    -- Keep the last good result visible alongside an error state
    result = Select(getResults(), name, "result"),
  }

  if eval.error then
    entry.error = eval.error
    log:warn("Expression '%s' failed: %s", name, eval.error)
  else
    entry.result = tostring(eval.result)
    values:update(outputVariableName(name), eval.result, config.mode == "string" and "STRING" or "NUMBER")
    ensureExpressionEvent(name)
    events:fire(NS_EXPRESSION, name)
    if notifyOwnVariableChanged then
      notifyOwnVariableChanged(outputVariableName(name), name)
    end
    log:info("Expression '%s' = %s", name, entry.result)
  end

  setResult(name, entry)
  return entry
end

--- The variable watch engine driving auto recompute with debounce.
local engine = ExpressionEngine:new({
  getExpressions = getExpressions,
  extractRefs = extractReferences,
  recompute = function(name)
    recomputeExpression(name)
  end,
  debounceMs = RECALC_DEBOUNCE_MS,
})

--- Director does not deliver variable watch events for a driver's own
--- variables, so after writing one of our outputs, poke the engine directly.
--- This keeps expressions that reference another expression's Result
--- recomputing. The writing expression is excluded to avoid self-referential
--- loops.
--- @param varName string The output variable name that was just written.
--- @param excludeName string? Expression name to skip.
function notifyOwnVariableChanged(varName, excludeName)
  local variableId = resolveVariable(C4:GetDeviceID(), varName)
  if variableId then
    engine:notifyVariableChanged(C4:GetDeviceID(), variableId, excludeName)
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

  -- Restore per-expression output variables here: programming attached to
  -- variables added after OnDriverInit may not work after a Director restart.
  values:restoreValues()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")

  C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")

  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Restore dynamic per-expression events
  events:restoreEvents()

  -- One-time cleanup of the retired ad hoc outputs (pre-release builds only).
  -- The variables were registered with C4:AddVariable, which persists in the
  -- project until explicitly deleted.
  for _, name in ipairs({ "STRING", "NUMBER" }) do
    if Variables[name] ~= nil then
      C4:DeleteVariable(name)
      Variables[name] = nil
    end
  end
  for _, key in ipairs({ "StringOutput", "NumberOutput", "StringExpression", "NumberExpression" }) do
    persist:set(key, nil)
  end

  -- Fire OnPropertyChanged for all properties to set initial global state
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  -- Restore variable watches and recompute auto expressions once at boot so
  -- outputs reflect changes missed while the driver was down.
  engine:resubscribeAll()
  for name, config in pairs(getExpressions()) do
    ensureExpressionEvent(name)
    if toboolean(config.auto) then
      local ok, err = pcall(recomputeExpression, name)
      if not ok then
        log:error("Initial recompute of '%s' failed: %s", name, err)
      end
    end
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

  gInitialized = true
  UpdateProperty("Driver Status", "Ready")
end

--- Clean up watches and flag expressions when a referenced device is removed.
--- @param deviceId number
function OnDeviceRemovedFromProject(deviceId)
  log:trace("OnDeviceRemovedFromProject(%s)", deviceId)
  DeviceUpdated(deviceId)
  local affected = engine:handleDeviceRemoved(tonumber(deviceId) or -1)
  for _, name in ipairs(affected) do
    local entry = getResults()[name] or {}
    entry.error = "referenced device removed"
    entry.ts = os.time()
    setResult(name, entry)
  end
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
-- Web UI Request Handlers (UIR)
--------------------------------------------------------------------------------

--- Send a response to the web UI via both return value (for REST) and
--- SendDataToUI (for socket push). Returns JSON for REST callers.
--- @param command string The response command name.
--- @param data table The response data.
--- @return string JSON response for REST callers.
local function uiRespond(command, data)
  -- C4:SendDataToUI cannot serialize boolean values (Director throws a
  -- basic_string construction error), so send them as strings on the socket
  -- push. The REST return keeps real booleans via JSON encoding.
  local safe = {}
  for k, v in pairs(data) do
    safe[k] = type(v) == "boolean" and tostring(v) or v
  end
  C4:SendDataToUI(command, safe)
  data._command = command
  return JSON:encode(data)
end

--- Send the full expression configuration and last results to the web UI.
function UIR._GET_CONFIG()
  log:trace("UIR.GET_CONFIG()")
  local results = getResults()
  local expressions = {}
  for name, config in pairs(getExpressions()) do
    local entry = results[name] or {}
    expressions[#expressions + 1] = {
      name = name,
      mode = config.mode or "equation",
      template = config.template or "",
      auto = toboolean(config.auto),
      watched = engine:watchedCount(name),
      result = entry.result,
      error = entry.error,
      rendered = entry.rendered,
      ts = entry.ts,
    }
  end
  table.sort(expressions, function(a, b)
    return (a.name or "") < (b.name or "")
  end)
  return uiRespond("CONFIG_DATA", { expressions = JSON:encode(expressions) })
end

--- Create or update a named expression.
--- @param tParams table
function UIR._SAVE_EXPRESSION(tParams)
  log:trace("UIR.SAVE_EXPRESSION()")
  local params = JSON:decode(C4:Base64Decode(tParams.DATA or "e30="))
  local name = tostring(params.name or ""):match("^%s*(.-)%s*$")
  local originalName = tostring(params.originalName or ""):match("^%s*(.-)%s*$")
  local mode = params.mode == "string" and "string" or "equation"
  local template = tostring(params.template or "")
  local auto = toboolean(params.auto)

  if IsEmpty(name) then
    return uiRespond("SAVE_RESULT", { ok = false, error = "Name is required" })
  end
  if IsEmpty(template) then
    return uiRespond("SAVE_RESULT", { ok = false, error = "Expression is required" })
  end

  local expressions = getExpressions()
  if not IsEmpty(originalName) and originalName ~= name and expressions[originalName] then
    -- Rename: retire the old identity
    engine:unsubscribeExpression(originalName)
    values:delete(outputVariableName(originalName))
    events:deleteEvent(NS_EXPRESSION, originalName)
    expressions[originalName] = nil
    local results = getResults()
    results[originalName] = nil
    persist:set(PERSIST_RESULTS, results)
  end

  expressions[name] = { name = name, mode = mode, template = template, auto = auto }
  saveExpressions(expressions)
  ensureExpressionEvent(name)
  engine:refreshExpression(name)
  recomputeExpression(name)
  return UIR._GET_CONFIG()
end

--- Delete a named expression and its outputs.
--- @param tParams table
function UIR._DELETE_EXPRESSION(tParams)
  log:trace("UIR.DELETE_EXPRESSION()")
  local params = JSON:decode(C4:Base64Decode(tParams.DATA or "e30="))
  local name = tostring(params.name or "")
  local expressions = getExpressions()
  if expressions[name] then
    engine:unsubscribeExpression(name)
    values:delete(outputVariableName(name))
    events:deleteEvent(NS_EXPRESSION, name)
    expressions[name] = nil
    saveExpressions(expressions)
    local results = getResults()
    results[name] = nil
    persist:set(PERSIST_RESULTS, results)
  end
  return UIR._GET_CONFIG()
end

--- Recompute a named expression now.
--- @param tParams table
function UIR._RUN_EXPRESSION(tParams)
  log:trace("UIR.RUN_EXPRESSION()")
  local params = JSON:decode(C4:Base64Decode(tParams.DATA or "e30="))
  recomputeExpression(tostring(params.name or ""))
  return UIR._GET_CONFIG()
end

--- Evaluate a draft expression without saving. Used by the editor's live
--- preview; the id correlates concurrent previews on the UI side.
--- @param tParams table
function UIR._EVAL_EXPRESSION(tParams)
  log:trace("UIR.EVAL_EXPRESSION()")
  local params = JSON:decode(C4:Base64Decode(tParams.DATA or "e30="))
  local mode = params.mode == "string" and "string" or "equation"
  local eval = evaluateTemplate(mode, tostring(params.template or ""))
  return uiRespond("EVAL_RESULT", {
    id = params.id or "",
    rendered = eval.rendered or "",
    substituted = eval.substituted or "",
    result = eval.result ~= nil and tostring(eval.result) or "",
    error = eval.error or "",
  })
end

--- Send the device list to the web UI with display names (Room > Device).
function UIR._GET_DEVICES()
  log:trace("UIR.GET_DEVICES()")
  local devices = {}
  local allDevices = C4:GetDevices() or {}
  for id, dev in pairs(allDevices) do
    local name = dev.deviceName or ("Device " .. id)
    devices[#devices + 1] = {
      id = id,
      name = name,
      roomName = dev.roomName or "",
    }
  end
  table.sort(devices, function(a, b)
    if (a.roomName or "") ~= (b.roomName or "") then
      return (a.roomName or "") < (b.roomName or "")
    end
    return (a.name or "") < (b.name or "")
  end)
  return uiRespond("DEVICES_DATA", { devices = JSON:encode(devices) })
end

--- Send variables for a specific device to the web UI.
--- @param tParams table
function UIR._GET_DEVICE_VARIABLES(tParams)
  log:trace("UIR.GET_DEVICE_VARIABLES()")
  local params = JSON:decode(C4:Base64Decode(tParams.DATA or "e30="))
  local devId = tonumber(params.deviceId)
  if not devId then
    return
  end
  local vars = {}
  local ok, deviceVars = pcall(C4.GetDeviceVariables, C4, devId)
  if ok and deviceVars then
    for varId, varInfo in pairs(deviceVars) do
      vars[#vars + 1] = {
        id = tonumber(varId),
        name = varInfo.name or ("var" .. varId),
        type = varInfo.type or "STRING",
        value = varInfo.value,
      }
    end
  end
  table.sort(vars, function(a, b)
    return (a.name or "") < (b.name or "")
  end)
  return uiRespond("DEVICE_VARIABLES_DATA", {
    deviceId = tostring(devId),
    variables = JSON:encode(vars),
  })
end

--------------------------------------------------------------------------------
-- Programming Command Handlers (EC)
--------------------------------------------------------------------------------

--- Calculate Expression command handler: recompute a named expression.
--- @param params table Command parameters: Expression.
function EC.Calculate_Expression(params)
  log:trace("EC.Calculate_Expression(%s)", params)
  local name = Select(params, "Expression")
  if IsEmpty(name) or not getExpressions()[name] then
    log:warn("Calculate Expression: unknown expression '%s'", tostring(name))
    return
  end
  recomputeExpression(name)
end

--------------------------------------------------------------------------------
-- GCPL Handlers (Dynamic List Population)
--------------------------------------------------------------------------------

--- Populate the Expression dropdown for the Calculate Expression command.
--- @param paramName string The parameter name being requested.
--- @return string[] list Sorted expression names.
function GCPL.Calculate_Expression(paramName)
  log:trace("GCPL.Calculate_Expression(%s)", paramName)
  if paramName ~= "Expression" then
    return {}
  end
  local names = {}
  for name in pairs(getExpressions()) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
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

  for name in pairs(getExpressions()) do
    engine:unsubscribeExpression(name)
  end
  values:reset()
  events:reset()
  persist:reset({ PERSIST_EXPRESSIONS, PERSIST_RESULTS })

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
