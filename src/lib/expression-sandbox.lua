--- Evaluates expressions in a sandbox: compiled with loadstring, with a cache keyed by
--- their text, and run with setfenv in an environment holding only `math`, `string`,
--- a few helpers, and the values an expression reads as `__p[n]`.
---
--- It limits what an expression can reach, not how long it runs: an expression the
--- integrator writes can hold a function literal, and nothing stops a loop inside
--- one. A variable's value is not an expression: it arrives as a binding, as data.

local log = require("lib.logging")

require("lib.utils")

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------

--- @class ExpressionSandbox
local Sandbox = {}

--- Cache of compiled expression functions keyed by expression string.
--- @type table<string, function>
local _cache = {}

--- Maximum number of cached expressions before eviction.
local MAX_CACHE_SIZE = 500

--- A table an expression can read but not change: an expression can hold a function
--- literal, and so assignments, and the driver shares the real tables it copies.
--- @param source table
--- @param leaveOut? string A key the expression doesn't get.
--- @return table readOnly
local function readOnlyCopy(source, leaveOut)
  local copy = {}
  for key, value in pairs(source) do
    if key ~= leaveOut then
      copy[key] = value
    end
  end
  return setmetatable({}, {
    __index = copy,
    __newindex = function()
      error("expressions can't change this table", 2)
    end,
    __metatable = false,
  })
end

local SANDBOX_MATH = readOnlyCopy(math)
local SANDBOX_STRING = readOnlyCopy(string, "dump")

---------------------------------------------------------------------------
-- Built-in Functions
---------------------------------------------------------------------------

--- Resolve a device ID to its display name via GetDevice().
--- @param id any Device ID (number or string)
--- @return string
local function deviceName(id)
  local devId = tonumber(id)
  if not devId then
    return tostring(id)
  end
  local device = GetDevice(devId)
  if device and device.deviceName and device.deviceName ~= "" then
    return device.deviceName
  end
  return tostring(id)
end

--- Resolve a device ID to its room name via GetDevice().
--- @param id any Device ID (number or string)
--- @return string
local function roomName(id)
  local devId = tonumber(id)
  if not devId then
    return tostring(id)
  end
  local device = GetDevice(devId)
  if device and device.roomName and device.roomName ~= "" then
    return device.roomName
  end
  return tostring(id)
end

---------------------------------------------------------------------------
-- Core
---------------------------------------------------------------------------

--- Compile an expression string into a function.
--- Returns a cached version if available.
--- @param expression string Lua expression (without "return")
--- @return function|nil fn
--- @return string|nil err
local function compile(expression)
  if _cache[expression] then
    return _cache[expression]
  end

  local fn, err = loadstring("return " .. expression)
  if not fn then
    return nil, err
  end

  -- Evict oldest entry if cache is full (simple eviction: clear all)
  local count = 0
  for _ in pairs(_cache) do
    count = count + 1
  end
  if count >= MAX_CACHE_SIZE then
    _cache = {}
  end

  _cache[expression] = fn
  return fn
end

--- Build the sandboxed environment for expression evaluation.
--- @param bindings? any[] Values an expression reads as `__p[1]`, `__p[2]` and so on.
--- @return table env
local function buildEnv(bindings)
  return {
    __p = bindings,
    math = SANDBOX_MATH,
    string = SANDBOX_STRING,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    -- Bare math helpers so equations read naturally (abs(a - b), round(x, 1))
    abs = math.abs,
    ceil = math.ceil,
    floor = math.floor,
    sqrt = math.sqrt,
    min = math.min,
    max = math.max,
    pi = math.pi,
    huge = math.huge,
    round = round,
    -- Built-in transform functions
    device_name = deviceName,
    room_name = roomName,
    c2f = c2f,
    f2c = f2c,
  }
end

--- Evaluate an expression.
--- @param expression string Lua expression
--- @param bindings? any[] Values available as `__p[1]`, `__p[2]` and so on. They aren't part of the text, so the compile cache holds across values.
--- @return any result The result, or nil on error.
--- @return string|nil err Error message if evaluation failed
function Sandbox.eval(expression, bindings)
  if not expression or expression == "" then
    return nil
  end

  local fn, compileErr = compile(expression)
  if not fn then
    local msg = "compile error: " .. (compileErr or "unknown")
    log:warn("Expression %s for '%s'", msg, expression)
    return nil, msg
  end

  -- setfenv must target fn directly so loadstring'd code resolves names from the
  -- sandbox. Safe: C4 Lua is single-threaded with no yields between here and pcall.
  setfenv(fn, buildEnv(bindings))

  -- A string's methods read the real string table, so ("").dump needs this too.
  local dump = string.dump
  string.dump = nil
  local ok, result = pcall(fn)
  string.dump = dump
  if not ok then
    local msg = "runtime error: " .. tostring(result)
    log:warn("Expression %s for '%s'", msg, expression)
    return nil, msg
  end

  return result
end

return Sandbox
