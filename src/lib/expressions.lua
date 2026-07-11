--- Variable watch engine for expression auto-recompute.
---
--- Manages registering/unregistering Control4 variable listeners on behalf of
--- named expressions and coalescing variable-change storms into debounced
--- recompute calls. Modeled on the control4-influxdb subscription engine:
--- listeners are ref-counted per variable across expressions, changes only
--- schedule work, and a trailing-edge debounce timer per expression does the
--- actual recompute.

local log = require("lib.logging")

---------------------------------------------------------------------------
-- Local Helpers
---------------------------------------------------------------------------

--- Build the ref key for a device/variable pair.
--- @param deviceId number
--- @param variableId number
--- @return string key e.g. "100:1002"
local function varKey(deviceId, variableId)
  return tostring(deviceId) .. ":" .. tostring(variableId)
end

--- Parse a ref key back into its numeric components.
--- @param key string
--- @return number|nil deviceId
--- @return number|nil variableId
local function parseVarKey(key)
  local devStr, varStr = key:match("^(%d+):(%d+)$")
  if not devStr then
    return nil, nil
  end
  return tonumber(devStr), tonumber(varStr)
end

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------

--- @class ExpressionReference
--- @field deviceId number
--- @field variableId number

--- @class ExpressionEngine
--- @field _refs table<string, table<string, boolean>> varKey -> set of expression names
--- @field _byExpression table<string, string[]> expression name -> list of varKeys
--- @field _debounceMs number
--- @field _getExpressions fun(): table<string, table>
--- @field _extractRefs fun(template: string): ExpressionReference[]
--- @field _recompute fun(name: string)
local ExpressionEngine = {}
ExpressionEngine.__index = ExpressionEngine

--- Create a new ExpressionEngine instance.
--- @param opts table Constructor options:
---   - getExpressions: fun(): table<string, table> map of name -> expression config
---   - extractRefs: fun(template: string): ExpressionReference[] resolve a template's references
---   - recompute: fun(name: string) recompute a named expression
---   - debounceMs: number? debounce window in milliseconds (default 1000)
--- @return ExpressionEngine
function ExpressionEngine:new(opts)
  log:trace("ExpressionEngine:new(opts)")
  opts = opts or {}
  local instance = setmetatable({}, self)
  instance._refs = {}
  instance._byExpression = {}
  instance._debounceMs = opts.debounceMs or 1000
  instance._getExpressions = assert(opts.getExpressions, "getExpressions is required")
  instance._extractRefs = assert(opts.extractRefs, "extractRefs is required")
  instance._recompute = assert(opts.recompute, "recompute is required")
  return instance
end

---------------------------------------------------------------------------
-- Private Methods
---------------------------------------------------------------------------

--- Debounce timer name for an expression.
--- @param name string
--- @return string
local function debounceTimerName(name)
  return "ExprDebounce::" .. name
end

--- Callback invoked when a watched variable's value changes.
--- Schedules a debounced recompute for every expression referencing it;
--- the change itself does no work, so chatty variables (power meters)
--- coalesce into one recompute per debounce window.
--- @param deviceId number
--- @param variableId number
function ExpressionEngine:_onVariableChanged(deviceId, variableId)
  log:trace("ExpressionEngine:_onVariableChanged(%s, %s)", deviceId, variableId)
  local names = self._refs[varKey(deviceId, variableId)]
  if not names then
    return
  end
  for name in pairs(names) do
    self:_scheduleRecompute(name)
  end
end

--- Arm (or re-arm) the trailing-edge debounce timer for an expression.
--- SetTimer cancels any existing timer with the same name, so every change
--- pushes the recompute out by the debounce window.
--- @param name string
function ExpressionEngine:_scheduleRecompute(name)
  SetTimer(debounceTimerName(name), self._debounceMs, function()
    local ok, err = pcall(self._recompute, name)
    if not ok then
      log:error("Debounced recompute of '%s' failed: %s", name, err)
    end
  end)
end

--- Register the C4 listener for a variable if this is its first reference.
--- @param key string
function ExpressionEngine:_registerListener(key)
  local deviceId, variableId = parseVarKey(key)
  if not deviceId or not variableId then
    return
  end
  RegisterVariableListener(deviceId, variableId, function(devId, varId, _value)
    self:_onVariableChanged(devId, varId)
  end)
  log:info("Watching variable %s", key)
end

--- Unregister the C4 listener for a variable that has no remaining references.
--- @param key string
function ExpressionEngine:_unregisterListener(key)
  local deviceId, variableId = parseVarKey(key)
  if not deviceId or not variableId then
    return
  end
  pcall(UnregisterVariableListener, deviceId, variableId)
  log:info("Stopped watching variable %s (no remaining references)", key)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Subscribe an expression to its referenced variables. Only expressions with
--- auto recompute enabled are watched. Idempotent per expression: call
--- refreshExpression() after edits instead of subscribing twice.
--- @param name string
function ExpressionEngine:subscribeExpression(name)
  log:trace("ExpressionEngine:subscribeExpression('%s')", name)
  local config = self._getExpressions()[name]
  if not config or not toboolean(config.auto) then
    return
  end

  local seen = {}
  local keys = {}
  for _, ref in ipairs(self._extractRefs(config.template or "")) do
    local key = varKey(ref.deviceId, ref.variableId)
    if not seen[key] then
      seen[key] = true
      keys[#keys + 1] = key
    end
  end

  self._byExpression[name] = keys
  for _, key in ipairs(keys) do
    local isFirstRef = self._refs[key] == nil
    self._refs[key] = self._refs[key] or {}
    self._refs[key][name] = true
    if isFirstRef then
      self:_registerListener(key)
    end
  end

  if #keys > 0 then
    log:debug("Expression '%s' watching %d variable(s)", name, #keys)
  end
end

--- Unsubscribe an expression from all of its watched variables.
--- Listeners with no remaining references are unregistered.
--- @param name string
function ExpressionEngine:unsubscribeExpression(name)
  log:trace("ExpressionEngine:unsubscribeExpression('%s')", name)
  for _, key in ipairs(self._byExpression[name] or {}) do
    local refs = self._refs[key]
    if refs then
      refs[name] = nil
      if not next(refs) then
        self._refs[key] = nil
        self:_unregisterListener(key)
      end
    end
  end
  self._byExpression[name] = nil
  CancelTimer(debounceTimerName(name))
end

--- Refresh an expression's subscriptions after a config change.
--- @param name string
function ExpressionEngine:refreshExpression(name)
  log:trace("ExpressionEngine:refreshExpression('%s')", name)
  self:unsubscribeExpression(name)
  self:subscribeExpression(name)
end

--- Subscribe every configured expression. Called on driver init to restore
--- watches after a restart.
function ExpressionEngine:resubscribeAll()
  log:trace("ExpressionEngine:resubscribeAll()")
  local count = 0
  for name in pairs(self._getExpressions()) do
    self:subscribeExpression(name)
    count = count + 1
  end
  log:info("resubscribeAll: restored watches for %d expression(s)", count)
end

--- Number of variables an expression is currently watching.
--- @param name string
--- @return number
function ExpressionEngine:watchedCount(name)
  return #(self._byExpression[name] or {})
end

--- Notify the engine of a variable change it cannot observe through a C4
--- listener. Director does not deliver watch events for a driver's own
--- variables, so the driver calls this after writing its own outputs to keep
--- chained expressions recomputing. The writer is excluded to avoid
--- self-referential loops.
--- @param deviceId number
--- @param variableId number
--- @param excludeName string? Expression to skip (the one that wrote the value).
function ExpressionEngine:notifyVariableChanged(deviceId, variableId, excludeName)
  log:trace("ExpressionEngine:notifyVariableChanged(%s, %s, %s)", deviceId, variableId, excludeName)
  local names = self._refs[varKey(deviceId, variableId)]
  if not names then
    return
  end
  for name in pairs(names) do
    if name ~= excludeName then
      self:_scheduleRecompute(name)
    end
  end
end

--- Handle device removal gracefully: unregister affected listeners, drop
--- references, and report which expressions were affected.
--- @param deviceId number
--- @return string[] affected Names of expressions that referenced the device.
function ExpressionEngine:handleDeviceRemoved(deviceId)
  log:trace("ExpressionEngine:handleDeviceRemoved(%s)", deviceId)
  local affected = {}
  local prefix = tostring(deviceId) .. ":"
  for key, refs in pairs(self._refs) do
    if key:sub(1, #prefix) == prefix then
      self:_unregisterListener(key)
      for name in pairs(refs) do
        affected[name] = true
        local keys = self._byExpression[name] or {}
        for i = #keys, 1, -1 do
          if keys[i] == key then
            table.remove(keys, i)
          end
        end
      end
      self._refs[key] = nil
    end
  end

  local names = {}
  for name in pairs(affected) do
    names[#names + 1] = name
  end
  table.sort(names)
  if #names > 0 then
    log:warn("Device %d removed: expression(s) %s reference it", deviceId, table.concat(names, ", "))
  end
  return names
end

return ExpressionEngine
