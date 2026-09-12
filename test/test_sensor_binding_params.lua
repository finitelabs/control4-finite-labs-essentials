-- Tests that every sensor binding payload goes through the shared helpers in
-- lib/utils.lua rather than a hand-built params table.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_sensor_binding_params.lua
--
-- The helpers' own behaviour is covered by test_sensor_params.lua. What is
-- checked here is that the drivers call them, which no unit test can see: a
-- driver.lua cannot be loaded far enough to reach these handlers (OnDriverInit
-- needs project context the shim does not model), so the call sites are read
-- from the sources instead. A payload that omits TIMESTAMP crashes C4-THERM at
-- its driver.lua:2982, and one that omits CELSIUS is discarded; a consumer that
-- reads VALUE only ingests nothing from a provider sending CELSIUS/FAHRENHEIT.
-- Regression test for DRV-121.

local T = require("testlib")

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

local function ls(dir)
  local names = {}
  local pipe = io.popen(string.format("ls %q 2>/dev/null", dir))
  if not pipe then
    return names
  end
  for name in pipe:lines() do
    table.insert(names, name)
  end
  pipe:close()
  return names
end

local function stripComments(src)
  local out = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(out, (line:gsub("%-%-.*$", "")))
  end
  return table.concat(out, "\n")
end

local drivers = {}
for _, name in ipairs(ls(root .. "/drivers")) do
  local body = readFile(root .. "/drivers/" .. name .. "/driver.lua")
  if body then
    drivers[name] = stripComments(body)
  end
end

T.section("the driver sources are readable")
T.check("found at least one driver.lua", next(drivers) ~= nil, "no drivers/*/driver.lua could be read")

--------------------------------------------------------------------------------
T.section("every VALUE_CHANGED payload is built by SensorValueParams")
--------------------------------------------------------------------------------

-- Bounded on the open paren so SensorValueParamsX would not satisfy it.
local function isHelperCall(params)
  return params ~= nil and params:match("^SensorValueParams%s*%(") ~= nil
end

-- A wrapped call reaches a failure message as several lines, of which the
-- harness prints only the first.
local function oneLine(text)
  return (text:gsub("%s+", " "))
end

--- Every VALUE_CHANGED send in src as { label, params }, the number of sends
--- seen, and the number of SendToProxy occurrences %b() could not read as a
--- call. Matched over the whole source rather than line by line, so a send whose
--- arguments are wrapped across lines is parsed like any other; the RFP handlers
--- compare against the same command string, hence anchoring on the send.
local function valueChangedSends(src)
  local sends, parsed, unreadable = 0, {}, 0
  for _ in src:gmatch("SendToProxy") do
    unreadable = unreadable + 1
  end
  for call in src:gmatch("SendToProxy%s*(%b())") do
    unreadable = unreadable - 1
    if call:find('"VALUE_CHANGED"', 1, true) then
      sends = sends + 1
      local params = call:sub(2, -2):match('"VALUE_CHANGED"%s*,%s*(.-)%s*$')
      if params then
        table.insert(parsed, { label = oneLine("SendToProxy" .. call), params = params })
      end
    end
  end
  return sends, parsed, unreadable
end

local sends, parsed, unreadable = 0, {}, 0
for name, src in pairs(drivers) do
  local driverSends, driverParsed, driverUnreadable = valueChangedSends(src)
  sends = sends + driverSends
  unreadable = unreadable + driverUnreadable
  for _, send in ipairs(driverParsed) do
    table.insert(parsed, send)
    T.check(name .. ": " .. send.label, isHelperCall(send.params), oneLine(send.params))
  end
end

-- A rename or refactor that stopped matching would otherwise pass silently.
T.check("the scan found sends to check", #parsed > 0, #parsed)

-- Two ways a send goes unchecked, both of which move only the assertion count:
-- %b() cannot read the call, or it can but no payload argument parses out of it.
T.check(
  "every SendToProxy occurrence was read as a call",
  unreadable == 0,
  string.format("%d occurrences did not parse as SendToProxy(...)", unreadable)
)
T.check(
  "every VALUE_CHANGED send yielded a payload argument",
  #parsed == sends,
  string.format("parsed %d of %d sends", #parsed, sends)
)

--------------------------------------------------------------------------------
T.section("the sender scan reads a send however it is wrapped")
--------------------------------------------------------------------------------

-- stylua keeps every send in the drivers on one line, so the wrapped forms the
-- matcher exists to handle are unreachable above and nothing there would notice
-- if it stopped reading them. Both directions are asserted, because a matcher
-- accepting every payload passes the section above as quietly as one reading no
-- sends at all. A payload the helper built is correct however it is wrapped, so
-- the wrapped helper call is required to pass rather than fail closed.
local WRAPPED_HELPER = [[
C4:SendToProxy(
  bindingId,
  "VALUE_CHANGED",
  SensorValueParams(
    value,
    scale
  )
)
]]

local WRAPPED_TABLE = [[
C4:SendToProxy(
  bindingId,
  "VALUE_CHANGED",
  { VALUE = value, TIMESTAMP = os.time() }
)
]]

local WRAPPED_CASES = {
  { what = "a wrapped SensorValueParams call", src = WRAPPED_HELPER, accepted = true },
  { what = "a wrapped hand-built table", src = WRAPPED_TABLE, accepted = false },
}

for _, case in ipairs(WRAPPED_CASES) do
  local caseSends, caseParsed, caseUnreadable = valueChangedSends(case.src)
  T.check(
    case.what .. " is one readable send",
    caseSends == 1 and caseUnreadable == 0,
    string.format("%d sends, %d unreadable", caseSends, caseUnreadable)
  )
  T.check(case.what .. " yields a payload argument", #caseParsed == 1, #caseParsed)
  T.check(
    case.what .. (case.accepted and " is accepted" or " is rejected"),
    #caseParsed == 1 and isHelperCall(caseParsed[1].params) == case.accepted,
    caseParsed[1] and oneLine(caseParsed[1].params) or "no payload argument parsed"
  )
end

--------------------------------------------------------------------------------
T.section("temperature inputs use the tolerant parse")
--------------------------------------------------------------------------------

-- A provider may send CELSIUS, FAHRENHEIT, or VALUE with a SCALE; YoLink sends
-- CELSIUS and FAHRENHEIT and no VALUE at all. Humidity carries no scale to
-- convert, so its arm must keep reading VALUE directly.
--
-- Both arms are read out of the single branch that selects between them. A
-- file-global search for either call cannot see which arm it sits in, so it
-- still passes when the two are swapped.
local INPUT_BRANCHES = {
  { driver = "sensor_aggregator", lhs = "persistKey", rhs = "PERSIST_TEMP_VALUES" },
  { driver = "sensor_multiplexer", lhs = "sensorKey", rhs = "INPUT_TEMP" },
}

for _, case in ipairs(INPUT_BRANCHES) do
  local src = drivers[case.driver]
  if not src then
    T.check(case.driver .. " source was read", false, "missing")
  else
    local guarded, fallback = src:match(
      "if%s+" .. case.lhs .. "%s*==%s*" .. case.rhs .. "%s+then%s+value%s*=%s*(.-)%s*else%s+value%s*=%s*(.-)%s*end"
    )
    local missing = "no if/else on " .. case.lhs .. " == " .. case.rhs
    T.check(
      case.driver .. ": the " .. case.rhs .. " arm parses with CelsiusFromParams",
      guarded ~= nil and guarded:match("^CelsiusFromParams%s*%(") ~= nil,
      guarded or missing
    )
    T.check(
      case.driver .. ": the else arm reads VALUE directly",
      fallback ~= nil and fallback:find('Select(tParams, "VALUE")', 1, true) ~= nil,
      fallback or missing
    )
  end
end

T.finish()
