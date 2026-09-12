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

local senders = 0
for name, src in pairs(drivers) do
  for line in src:gmatch("[^\n]+") do
    -- The RFP handlers compare against the same string, so anchor on the send.
    local params = line:match('SendToProxy%s*%(.-"VALUE_CHANGED"%s*,%s*(.-)%s*%)%s*$')
    if params then
      senders = senders + 1
      T.check(name .. ": " .. (line:gsub("^%s+", "")), params:match("^SensorValueParams%("), params)
    end
  end
end

-- A rename or refactor that stopped matching would otherwise pass silently.
T.check("the scan found sender lines to check", senders > 0, senders)

--------------------------------------------------------------------------------
T.section("temperature inputs use the tolerant parse")
--------------------------------------------------------------------------------

-- A provider may send CELSIUS, FAHRENHEIT, or VALUE with a SCALE; YoLink sends
-- CELSIUS and FAHRENHEIT and no VALUE at all.
for _, name in ipairs({ "sensor_aggregator", "sensor_multiplexer" }) do
  local src = drivers[name]
  if src then
    T.check(name .. " reads a temperature input with CelsiusFromParams", src:find("CelsiusFromParams(", 1, true) ~= nil)
  else
    T.check(name .. " source was read", false, "missing")
  end
end

-- Humidity has no scale conversion, so it still reads VALUE directly; asserting
-- that keeps a future edit from routing a percentage through a Celsius parse.
for _, name in ipairs({ "sensor_aggregator", "sensor_multiplexer" }) do
  local src = drivers[name]
  if src then
    T.check(name .. " still reads a humidity input from VALUE", src:find('Select(tParams, "VALUE")', 1, true) ~= nil)
  end
end

T.finish()
