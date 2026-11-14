--- Evaluates expressions in a sandbox: compiled with loadstring, with a cache keyed by
--- their text, and run with setfenv in an environment holding only `math`, `string`,
--- a few helpers including `json(text, "$.path")`, and the values an expression reads as `__p[n]`.
---
--- An evaluation is limited in what it reaches, how long it runs and how much memory it
--- takes: an expression the integrator writes or imports can hold a function literal, and
--- so a loop. Past a limit the evaluation fails with a plain error. A variable's value is
--- not an expression: it arrives as a binding, as data.

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

--- How often, in Lua instructions, an evaluation's limits are checked. Nothing checks
--- memory between checks, and each concatenation there can multiply a string's size.
local CHECK_EVERY = 4

--- The most Lua instructions an evaluation runs: a typical expression runs under a
--- hundred. The controller runs Lua with its JIT compiler off, so every one is counted.
local MAX_INSTRUCTIONS = 1000000

--- The most memory an evaluation adds while it runs, in KB.
local MAX_MEMORY_KB = 4096

--- The longest string `rep`, `format` and `gsub` make, in bytes.
local MAX_STRING = 1024 * 1024

--- The most steps an evaluation's pattern searches may take in all, counted as Lua's
--- matcher could backtrack through each subject. A search runs in C, where no
--- instruction is counted, so each is charged before it runs.
local MAX_PATTERN_STEPS = 10000000

--- The longest pattern searched with, in characters: an expression's patterns run to a few dozen.
local MAX_PATTERN_LENGTH = 1000

local RAN_TOO_LONG = "the expression ran too long"
local TOO_MUCH_MEMORY = "the expression used too much memory"
local STRING_TOO_LONG = "the expression made a string over 1 MB"
local PATTERN_TOO_SLOW = "a pattern search in the expression would take too long"
local PATTERN_TOO_LONG = "a pattern in the expression is over 1000 characters"

--- Pattern steps the running evaluation has been charged.
local spentSteps = 0

--- Strings' shared metatable: a string's methods are read through its `__index`.
local STRING_META = getmetatable("")

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

--- @param ... any
--- @return table packed
local function pack(...)
  return { n = select("#", ...), ... }
end

--- Calls fn with the evaluation's limits paused, for the driver's own code and the
--- checks below. A limit's error is raised only in the expression's code.
--- @param fn function
--- @param ... any
--- @return any ...
local function unlimited(fn, ...)
  local hook, mask, count = debug.gethook()
  local paused = type(hook) == "function"
  if paused then
    debug.sethook()
  end
  local index = STRING_META.__index
  STRING_META.__index = string
  local results = pack(pcall(fn, ...))
  STRING_META.__index = index
  if paused then
    debug.sethook(hook, mask, count)
  end
  if not results[1] then
    error(results[2], 0)
  end
  return unpack(results, 2, results.n)
end

---------------------------------------------------------------------------
-- String functions
---------------------------------------------------------------------------

--- The last character of the single-character class at `at`, as Lua's matcher reads it.
--- @param pattern string
--- @param at integer
--- @return integer|nil last nil for a malformed class, which the real call reports.
local function classEnd(pattern, at)
  local c = pattern:sub(at, at)
  if c == "%" then
    return at < #pattern and at + 1 or nil
  elseif c == "[" then
    local p = at + 1
    if pattern:sub(p, p) == "^" then
      p = p + 1
    end
    repeat
      if p > #pattern then
        return nil
      end
      local ch = pattern:sub(p, p)
      p = p + 1
      if ch == "%" then
        p = p + 1
      end
    until pattern:sub(p, p) == "]"
    return p
  end
  return at
end

--- A pattern's items. `factor` is how many ways the matcher can try an item: "run" for
--- a repeated class, "n" for one whose work grows with the subject.
--- @param pattern string
--- @param anchored boolean Whether it starts with an anchoring "^".
--- @return table[]|nil items nil for a malformed pattern.
local function parsePattern(pattern, anchored)
  local items, at = {}, anchored and 2 or 1
  while at <= #pattern do
    local c, after = pattern:sub(at, at), pattern:sub(at + 1, at + 1)
    if c == "(" or c == ")" or (c == "$" and at == #pattern) then
      at = at + 1
    elseif c == "%" and (after == "b" or after:match("%d")) then
      items[#items + 1] = { factor = "n" }
      at = at + (after == "b" and 4 or 2)
    elseif c == "%" and after == "f" then
      local last = classEnd(pattern, at + 2)
      if not last then
        return nil
      end
      items[#items + 1] = {}
      at = last + 1
    else
      local last = classEnd(pattern, at)
      if not last then
        return nil
      end
      local class, q = pattern:sub(at, last), pattern:sub(last + 1, last + 1)
      if class == "^" or class == "$" then
        -- Literal here, but an anchor at either end of the patterns built from it below.
        class = "%" .. class
      end
      if q == "*" or q == "+" or q == "-" then
        items[#items + 1] = { class = class, factor = "run" }
        at = last + 2
      elseif q == "?" then
        items[#items + 1] = { factor = 2 }
        at = last + 2
      else
        items[#items + 1] = { class = class, fixed = true }
        at = last + 1
      end
    end
  end
  return items
end

--- The most steps Lua's matcher can take searching subject for pattern: each start
--- tried, times the ways each item can be tried there, times the pattern's length for
--- the work of a step. It's counted from this subject: how long a run each repeated
--- class can match, and where the pattern's fixed start is.
--- @param subject string
--- @param n integer How much of the subject the search covers.
--- @param pattern string
--- @param anchorable boolean
--- @param budget number Steps left: past them, the count stops early.
--- @return number steps
local function patternSteps(subject, n, pattern, anchorable, budget)
  local width = math.max(#pattern, 1)
  local anchored = anchorable and pattern:sub(1, 1) == "^"
  -- Every start is tried, each at least as far as the pattern's fixed start.
  local base = anchored and width or (n + 1) * width
  if base > budget then
    return base
  end
  local items = parsePattern(pattern, anchored)
  if not items then
    return 0
  end
  if n < #subject then
    -- Only what the search covers is scanned below, so the scan costs what's charged.
    subject = n == 0 and "" or subject:sub(-n)
  end
  local starts = anchored and 1 or n + 1
  if not anchored then
    local prefix = {}
    for _, item in ipairs(items) do
      if not item.fixed then
        break
      end
      prefix[#prefix + 1] = item.class
    end
    if #prefix > 0 then
      -- gsub counts the places that don't overlap; each hides at most one per character.
      local _, found = subject:gsub(table.concat(prefix), "")
      starts = found * #prefix
    end
  end
  local total, runs = starts * width, {}
  for _, item in ipairs(items) do
    if item.factor == "n" then
      total = total * (n + 1)
    elseif item.factor == 2 then
      total = total * 2
    elseif item.factor == "run" then
      local class = item.class
      if not runs[class] then
        -- "." matches every character: n, without copying the subject to find it.
        local longest = class == "." and n or 0
        if class ~= "." then
          for match in subject:gmatch(class .. "+") do
            longest = math.max(longest, #match)
          end
        end
        runs[class] = longest
      end
      total = total * (runs[class] + 1)
    end
  end
  return base + total
end

--- @param value any
--- @return integer length The length of value as the string functions read it; 0 for others.
local function length(value)
  local kind = type(value)
  return (kind == "string" or kind == "number") and #tostring(value) or 0
end

--- @param subject any
--- @param init any Where a search starts, as find and match read it.
--- @return integer n How much of the subject a search from init covers.
local function searched(subject, init)
  local size, start = length(subject), tonumber(init) or 1
  if start ~= math.floor(start) or math.abs(start) >= 2 ^ 31 then
    -- NaN, fractions and starts past 32 bits are converted the search's own way, which for
    -- the last differs by platform, so they're charged as all of it.
    return size
  end
  if start < 0 then
    start = math.max(size + start + 1, 1)
  elseif start == 0 then
    start = 1
  end
  return math.max(size - start + 1, 0)
end

--- Charges a search's steps to the evaluation, refusing it when they'd pass the limit.
--- @param steps number
local function charge(steps)
  if steps > MAX_PATTERN_STEPS - spentSteps then
    error(PATTERN_TOO_SLOW, 0)
  end
  spentSteps = spentSteps + steps
end

--- Charges a pattern search, refusing one that could run too long.
--- @param subject any
--- @param pattern any
--- @param anchorable boolean
--- @param init? any
local function checkPattern(subject, pattern, anchorable, init)
  if type(subject) == "number" then
    subject = tostring(subject)
  end
  if type(subject) ~= "string" or (type(pattern) ~= "string" and type(pattern) ~= "number") then
    return
  end
  pattern = tostring(pattern)
  if #pattern > MAX_PATTERN_LENGTH then
    error(PATTERN_TOO_LONG, 0)
  end
  local budget = MAX_PATTERN_STEPS - spentSteps
  charge(patternSteps(subject, searched(subject, init), pattern, anchorable, budget))
end

--- @param size number
local function checkSize(size)
  if size > MAX_STRING then
    error(STRING_TOO_LONG, 0)
  end
end

local function rep(s, n, sep)
  local count = tonumber(n)
  if count and count > 0 then
    checkSize(length(s) * count + length(sep) * (count - 1))
  end
  return string.rep(s, n, sep)
end

local function format(fmt, ...)
  -- A field is at most 99 wide, and %q at most quadruples a character.
  local size = length(fmt)
  for i = 1, select("#", ...) do
    size = size + 4 * length((select(i, ...))) + 100
  end
  checkSize(size)
  return string.format(fmt, ...)
end

--- The longest gsub's result can be: the subject, plus the longest replacement for each of
--- at most one match per character. That covers a %1 too, which is two characters of the
--- replacement and copies text from matches that don't overlap.
--- @param s any
--- @param repl any
--- @return number size
local function gsubSize(s, repl)
  local longest = length(repl)
  if type(repl) == "table" then
    for _, value in pairs(repl) do
      longest = math.max(longest, length(value))
    end
  end
  return length(s) + (length(s) + 1) * longest
end

local function gsub(s, pattern, repl, n)
  unlimited(function()
    checkPattern(s, pattern, true)
    -- A function's results are its own: the evaluation's limits run while it does.
    checkSize(gsubSize(s, repl))
  end)
  return string.gsub(s, pattern, repl, n)
end

local function find(s, pattern, init, plain)
  if plain then
    charge((searched(s, init) + 1) * length(pattern))
  else
    unlimited(checkPattern, s, pattern, true, init)
  end
  return string.find(s, pattern, init, plain)
end

local function match(s, pattern, init)
  unlimited(checkPattern, s, pattern, true, init)
  return string.match(s, pattern, init)
end

local function gmatch(s, pattern)
  unlimited(checkPattern, s, pattern, false)
  return string.gmatch(s, pattern)
end

local SANDBOX_STRING
do
  local functions = {}
  for name, fn in pairs(string) do
    functions[name] = fn
  end
  functions.dump = nil
  functions.rep, functions.format, functions.gsub = rep, format, gsub
  functions.find, functions.match, functions.gmatch = find, match, gmatch
  SANDBOX_STRING = readOnlyCopy(functions)
end

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
-- JSON
---------------------------------------------------------------------------

local LIMIT_ERRORS = { [RAN_TOO_LONG] = true, [TOO_MUCH_MEMORY] = true }

--- A JSON.lua of the sandbox's own that tags what it decodes, so `{}` encodes back as `{}`.
--- @type table|nil
local strictJson

--- The last text json() decoded in the running evaluation, so reading several values from
--- one text decodes it once.
local lastText, lastDecoded

--- Calls JSON.lua's method under the evaluation's limits, so a long text costs what it
--- takes, but with strings' real methods: its patterns are fixed and anchored.
--- @param method function
--- @param value any
--- @return boolean ok
--- @return any result
local function callJson(method, value)
  local index = STRING_META.__index
  STRING_META.__index = string
  strictJson = strictJson or JSON:new({ strictTypes = true })
  local ok, result = pcall(method, strictJson, value)
  STRING_META.__index = index
  if not ok and LIMIT_ERRORS[result] then
    error(result, 0)
  end
  return ok, result
end

--- The value at a path in a decoded JSON value: `$` is the whole value, `.name` a field
--- and `[n]` an array's item, counted from 0, which may follow another: `$.grid[0][1]`.
--- @param value any
--- @param path string
--- @return any found nil when the path doesn't lead to a value.
local function atPath(value, path)
  if not path:match("^%$") then
    return nil
  end
  local current = value
  for part in (path:match("^%$%.?(.*)$")):gmatch("[^.]+") do
    if type(current) ~= "table" then
      return nil
    end
    local field, indexes = part:match("^([^%[]*)(%[.*)$")
    if not indexes or indexes:gsub("%[%d+%]", "") ~= "" then
      -- rawget: a strict-typed table's metatable would answer a missing key.
      current = rawget(current, part)
    else
      if field ~= "" then
        current = rawget(current, field)
      end
      for index in indexes:gmatch("%d+") do
        if type(current) ~= "table" then
          return nil
        end
        current = rawget(current, tonumber(index) + 1)
      end
    end
  end
  return current
end

--- One value read from JSON text with a `$.` path. An object or array comes back as its
--- JSON text, which json() reads again; its keys may be in another order.
--- @param text any
--- @param path any
--- @return string|number|boolean|nil value nil for text that isn't JSON or a path to nothing.
local function json(text, path)
  local kind = type(text)
  if (kind ~= "string" and kind ~= "number" and kind ~= "boolean") or type(path) ~= "string" then
    return nil
  end
  text = tostring(text)
  if text ~= lastText then
    local ok, decoded = callJson(JSON.decode, text)
    lastText, lastDecoded = text, nil
    if ok then
      lastDecoded = decoded
    end
  end
  local value = atPath(lastDecoded, path)
  if type(value) == "table" then
    local ok, encoded = callJson(JSON.encode, value)
    return ok and encoded or nil
  end
  return value
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
    device_name = function(id)
      return unlimited(deviceName, id)
    end,
    room_name = function(id)
      return unlimited(roomName, id)
    end,
    c2f = c2f,
    f2c = f2c,
    json = json,
  }
end

--- Runs fn under the limits. Turned off inside the protected call, so a limit can't
--- raise once the evaluation has returned.
--- @param fn function
--- @return boolean ok
--- @return any result
local function runLimited(fn)
  local checks, startKb = 0, collectgarbage("count")
  local function stop(err)
    debug.sethook()
    return err
  end
  local function overMemory()
    if collectgarbage("count") - startKb <= MAX_MEMORY_KB then
      return false
    end
    -- What's over may be garbage the collector hasn't reached yet.
    collectgarbage("collect")
    return collectgarbage("count") - startKb > MAX_MEMORY_KB
  end
  local function limit()
    checks = checks + 1
    local over = (checks * CHECK_EVERY > MAX_INSTRUCTIONS and RAN_TOO_LONG) or (overMemory() and TOO_MUCH_MEMORY)
    -- In stop, an error is already on its way out, and raising another would replace it.
    if over and debug.getinfo(2, "f").func ~= stop then
      error(over, 0)
    end
  end
  return xpcall(function()
    debug.sethook(limit, "", CHECK_EVERY)
    local result = fn()
    debug.sethook()
    return result
  end, stop)
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
  -- sandbox. Safe: C4 Lua is single-threaded with no yields between here and the call.
  setfenv(fn, buildEnv(bindings))

  -- A string's methods are read through its metatable, so ("x"):rep(n) needs this too.
  local hook, mask, count = debug.gethook()
  local index, spent = STRING_META.__index, spentSteps
  STRING_META.__index, spentSteps = SANDBOX_STRING, 0
  local ok, result = runLimited(fn)
  lastText, lastDecoded = nil, nil
  STRING_META.__index, spentSteps = index, spent
  if type(hook) == "function" then
    debug.sethook(hook, mask, count)
  end
  if not ok then
    local msg = "runtime error: " .. tostring(result)
    log:warn("Expression %s for '%s'", msg, expression)
    return nil, msg
  end

  return result
end

return Sandbox
