--- Variable Expressions Driver
--#ifndef DRIVERCENTRAL
DRIVER_GITHUB_REPO = "finitelabs/control4-finite-labs-essentials"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local page = require("lib.ui.page")
local pageParams = require("lib.ui.page-params")
local persist = require("lib.persist")
local values = require("lib.values")
local events = require("lib.events")
local Expressions = require("lib.expressions")
local updateSettings = require("lib.update-settings")
local devices = require("lib.ui.devices")
local expressionTab = require("lib.ui.expression-tab")
local tabProperties = require("lib.ui.tab-properties")
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

--- Namespace for dynamic per-expression events.
local NS_EXPRESSION = "Expression"

--- Suffix appended to an expression name to form its output variable.
local RESULT_SUFFIX = " Result"

--- Debounce window for auto recompute of expressions (trailing edge).
local RECALC_DEBOUNCE_MS = 1000

--- Persist keys for named expressions and their last results.
local PERSIST_EXPRESSIONS = "Expressions"
local PERSIST_RESULTS = "ExpressionResults"

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
  page.send("EXPRESSION_RESULT", {
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
  if not config or not licensed() then
    return nil
  end

  local eval = Expressions.evaluate(config.mode, config.template)
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
local engine = Expressions:new({
  getExpressions = getExpressions,
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
  for id, variable in pairs(C4:GetDeviceVariables(C4:GetDeviceID()) or {}) do
    if variable.name == varName then
      engine:notifyVariableChanged(C4:GetDeviceID(), tonumber(id), excludeName)
      return
    end
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

  -- Restore per-expression output variables here: programming attached to
  -- variables added after OnDriverInit may not work after a Director restart.
  values:restoreValues()
end

--- Recomputes every auto expression, so outputs catch up on changes the driver missed while down or stopped.
local function recomputeAutoExpressions()
  for name, config in pairs(getExpressions()) do
    if toboolean(config.auto) then
      local ok, err = pcall(recomputeExpression, name)
      if not ok then
        log:error("Recompute of '%s' failed: %s", name, err)
      end
    end
  end
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")

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
  -- The router runs each handler in its own xpcall and reports its error, so the rest still run.
  for p, _ in pairs(Properties) do
    OnPropertyChanged(p)
  end

  -- Restore variable watches and recompute auto expressions once at boot.
  engine:resubscribeAll()
  for name in pairs(getExpressions()) do
    ensureExpressionEvent(name)
  end
  recomputeAutoExpressions()

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

  --#ifdef DRIVERCENTRAL
  drivercentral:startGate(function(active)
    if not active then
      UpdateProperty("Driver Status", drivercentral.UNLICENSED_STATUS)
      return
    end
    UpdateProperty("Driver Status", "Ready")
    recomputeAutoExpressions()
  end)
  --#endif
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

--- Stop watching a removed device. Its expressions recompute, and their rows show why they failed.
--- @param deviceId number
function OnDeviceRemovedFromProject(deviceId)
  log:trace("OnDeviceRemovedFromProject(%s)", deviceId)
  DeviceUpdated(deviceId)
  engine:handleDeviceRemoved(tonumber(deviceId) or -1)
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
end

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  if not gInitialized then
    return
  end
  updateSettings:share("Automatic Updates", propertyValue, { "variable_expressions.c4z" })
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if not gInitialized then
    return
  end
  updateSettings:share("Update Channel", propertyValue, { "variable_expressions.c4z" })
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

--------------------------------------------------------------------------------
-- Web UI Request Handlers (UIR)
--------------------------------------------------------------------------------

tabProperties:serve()
devices.serve()
expressionTab.serve({ modes = { "equation", "string" } })

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
  page.send("CONFIG_DATA", { expressions = expressions })
end

--- Create or update a named expression.
--- @param tParams table
function UIR._SAVE_EXPRESSION(tParams)
  log:trace("UIR.SAVE_EXPRESSION()")
  local params = pageParams(tParams)
  local name = tostring(params.name or ""):match("^%s*(.-)%s*$")
  local originalName = tostring(params.originalName or ""):match("^%s*(.-)%s*$")
  local mode = params.mode == "string" and "string" or "equation"
  local template = tostring(params.template or "")
  local auto = toboolean(params.auto)

  if IsEmpty(name) then
    return page.send("SAVE_RESULT", { ok = false, error = "Name is required" })
  end
  if IsEmpty(template) then
    return page.send("SAVE_RESULT", { ok = false, error = "Expression is required" })
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
  local params = pageParams(tParams)
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
  local params = pageParams(tParams)
  recomputeExpression(tostring(params.name or ""))
  return UIR._GET_CONFIG()
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
  --#ifdef DRIVERCENTRAL
  UpdateProperty("Cloud Monitoring", "Enabled", true)
  --#endif
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
    :updateAll(
      DRIVER_GITHUB_REPO,
      { "variable_expressions.c4z" },
      Properties["Update Channel"] == "Prerelease",
      forceUpdate
    )
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
