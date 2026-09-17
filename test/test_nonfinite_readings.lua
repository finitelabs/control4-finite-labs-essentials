-- Tests that a non-finite reading is rejected at each point this repo's drivers
-- admit an outside number: the aggregator and multiplexer VALUE_CHANGED inputs,
-- the device_programmer Set_Temperature/Set_Humidity commands, and the
-- network_requests webhook Content-Length header.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_nonfinite_readings.lua
--
-- `tofinite`'s own behaviour is covered by test_nonfinite_numbers.lua, and that
-- the call sites name it by test_sensor_binding_params.lua. What is checked here
-- is what a handler does when one arrives, which neither of those can see.
--
-- OnDriverInit needs project context the shim does not model, so a driver.lua
-- cannot be loaded far enough to reach these handlers. Each one is instead cut
-- out of its source and run under a synthetic environment: real lib/utils
-- helpers, stubbed driver-local collaborators.
--
-- Temperature arms have no revert run: since template v0.9.25 the guard is inside CelsiusFromParams (reverted in test_sensor_params.lua).
--
-- Regression test for DRV-122.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local NAN = 0 / 0
local INF = math.huge

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

local function readDriver(name)
  local fh = assert(io.open(root .. "/drivers/" .. name .. "/driver.lua", "r"))
  local body = fh:read("*a")
  fh:close()
  return body
end

--- Cut one top-level function out of a driver source, by its declaration line.
--- stylua indents every nested block, so the first "\nend\n" after the
--- declaration is the function's own closing end.
--- @param src string
--- @param decl string The declaration, e.g. "function OnServerDataIn".
--- @return string|nil source
local function cutFunction(src, decl)
  local startPos = src:find("\n" .. decl, 1, true)
  if startPos == nil then
    return nil
  end
  local endPos = src:find("\nend\n", startPos + 1, true)
  if endPos == nil then
    return nil
  end
  return src:sub(startPos + 1, endPos + 4)
end

--- Load a cut function under `stubs`, with every other global resolving to the
--- real one so lib/utils is exercised rather than mocked.
--- @param cut string The cut source.
--- @param name string The function's name, returned from the chunk.
--- @param stubs table Driver-local collaborators.
--- @param mutate boolean|function Revert the fix: true swaps tofinite for
---   tonumber, which is what the call sites used before it; a function rewrites
---   the cut source, for a site where the fix is more than the helper swap.
local function loadCut(cut, name, stubs, mutate)
  local env = setmetatable(stubs, { __index = _G })
  local src = cut
  if type(mutate) == "function" then
    src = assert(mutate(cut), "the revert matched nothing, so the mutant is the fixed code")
    assert(src ~= cut, "the revert changed nothing, so the mutant is the fixed code")
  elseif mutate then
    env.tofinite = tonumber
  end
  local chunk = assert(loadstring(src .. "\nreturn " .. name, "=" .. name))
  setfenv(chunk, env)
  return chunk(), env
end

local LOG_STUB = setmetatable({}, {
  __index = function()
    return function() end
  end,
})

--------------------------------------------------------------------------------
T.section("each handler is readable as a whole function")
--------------------------------------------------------------------------------

local CUTS = {
  {
    what = "sensor_aggregator registerInputHandlers",
    src = readDriver("sensor_aggregator"),
    decl = "local function registerInputHandlers",
  },
  {
    what = "sensor_multiplexer registerNumericInputHandlers",
    src = readDriver("sensor_multiplexer"),
    decl = "local function registerNumericInputHandlers",
  },
  {
    what = "device_programmer EC.Set_Temperature",
    src = readDriver("device_programmer"),
    decl = "function EC.Set_Temperature",
  },
  {
    what = "device_programmer EC.Set_Humidity",
    src = readDriver("device_programmer"),
    decl = "function EC.Set_Humidity",
  },
  {
    what = "network_requests OnServerDataIn",
    src = readDriver("network_requests"),
    decl = "function OnServerDataIn",
  },
}

local cut = {}
for _, case in ipairs(CUTS) do
  local text = cutFunction(case.src, case.decl)
  cut[case.decl] = text
  -- A cut that stopped at the wrong `end` still compiles as often as not, so the
  -- balance is asserted rather than the mere absence of a load error.
  T.check(case.what .. " was cut out", text ~= nil, "no " .. case.decl)
  if text then
    T.check(
      case.what .. " compiles",
      loadstring(text, "=" .. case.decl) ~= nil,
      "cut does not compile: " .. text:sub(1, 120)
    )
    T.check(
      case.what .. " ends at its own end",
      text:match("\nend\n$") ~= nil and select(2, text:gsub("\nend\n", "")) == 1,
      "cut closes more than once"
    )
  end
end

--------------------------------------------------------------------------------
T.section("sensor_aggregator: a non-finite reading is never cached")
--------------------------------------------------------------------------------

--- Drive the aggregator's VALUE_CHANGED input handler once.
--- @param persistKey string PERSIST_TEMP_VALUES selects the temperature arm.
--- @param tParams table The params as received.
--- @param mutate boolean Revert the fix.
--- @return table cached, number recalcs
local function driveAggregator(persistKey, tParams, mutate)
  local cached, recalcs = {}, 0
  local stubs = {
    log = LOG_STUB,
    RFP = {},
    OBC = {},
    PERSIST_TEMP_VALUES = "TEMP",
    setCachedValue = function(_persistKey, key, value)
      cached[key] = value
    end,
    clearCachedValue = function() end,
  }
  local fn, env = loadCut(cut["local function registerInputHandlers"], "registerInputHandlers", stubs, mutate)
  fn({ bindingId = 7, key = "input_1" }, persistKey, function()
    recalcs = recalcs + 1
  end)
  env.RFP[7](7, "VALUE_CHANGED", tParams)
  return cached, recalcs
end

local AGGREGATOR_CASES = {
  { what = "a NaN string on the temperature arm", key = "TEMP", params = { VALUE = "nan", SCALE = "CELSIUS" } },
  { what = "an infinity string on the temperature arm", key = "TEMP", params = { VALUE = "inf", SCALE = "CELSIUS" } },
  {
    what = "an overflowing digit run on the temperature arm",
    key = "TEMP",
    params = { VALUE = string.rep("9", 400), SCALE = "CELSIUS" },
  },
  { what = "a NaN number on the temperature arm", key = "TEMP", params = { VALUE = NAN, SCALE = "CELSIUS" } },
  { what = "a NaN sent as CELSIUS", key = "TEMP", params = { CELSIUS = "nan" } },
  { what = "an overflowing exponent sent as CELSIUS", key = "TEMP", params = { CELSIUS = "1e999" } },
  { what = "a NaN sent as FAHRENHEIT", key = "TEMP", params = { FAHRENHEIT = "nan" } },
  { what = "an overflowing exponent sent as FAHRENHEIT", key = "TEMP", params = { FAHRENHEIT = "1e999" } },
  { what = "a NaN string on the humidity arm", key = "HUM", params = { VALUE = "nan" } },
  { what = "an infinity string on the humidity arm", key = "HUM", params = { VALUE = "inf" } },
}

for _, case in ipairs(AGGREGATOR_CASES) do
  local cached, recalcs = driveAggregator(case.key, case.params, false)
  T.eq(case.what .. " is not cached", cached.input_1, nil)
  T.eq(case.what .. " triggers no recalculation", recalcs, 0)

  -- Only the humidity arm is guarded by the driver, so only it has a revert.
  if case.key == "HUM" then
    local mutantCached = driveAggregator(case.key, case.params, true)
    T.check(
      case.what .. " IS cached once the fix is reverted",
      mutantCached.input_1 ~= nil,
      "the mutant rejected it too, so the case proves nothing"
    )
  end
end

local stillGuarded = driveAggregator("TEMP", { VALUE = "nan", SCALE = "CELSIUS" }, true)
T.eq("the temperature arm stays guarded with the driver's tofinite reverted", stillGuarded.input_1, nil)

T.section("sensor_aggregator: a finite reading still gets through")
local finiteCached, finiteRecalcs = driveAggregator("TEMP", { VALUE = "21.5", SCALE = "CELSIUS" }, false)
T.eq("a Celsius reading is cached", finiteCached.input_1, 21.5)
T.eq("and it recalculates", finiteRecalcs, 1)
local fahrenheitCached = driveAggregator("TEMP", { VALUE = "70.7", SCALE = "FAHRENHEIT" }, false)
T.eq("a Fahrenheit reading is converted, not discarded", fahrenheitCached.input_1, 21.5)
local humidityCached = driveAggregator("HUM", { VALUE = "48" }, false)
T.eq("a humidity reading is cached", humidityCached.input_1, 48)
local zeroCached = driveAggregator("TEMP", { VALUE = "0", SCALE = "CELSIUS" }, false)
T.eq("zero is a reading, not an absence", zeroCached.input_1, 0)

--------------------------------------------------------------------------------
T.section("sensor_multiplexer: a non-finite reading is never cached")
--------------------------------------------------------------------------------

--- Drive the multiplexer's VALUE_CHANGED input handler once.
--- @param sensorKey string INPUT_TEMP selects the temperature arm.
--- @param tParams table The params as received.
--- @param mutate boolean Revert the fix.
--- @return table cached, number updates
local function driveMultiplexer(sensorKey, tParams, mutate)
  local cached, updates = {}, 0
  local stubs = {
    log = LOG_STUB,
    RFP = {},
    OBC = {},
    INPUT_TEMP = "TEMP",
    setCachedInputValue = function(_name, key, value)
      cached[key] = value
    end,
    getActiveInput = function()
      return "input_1"
    end,
    updateOutputs = function()
      updates = updates + 1
    end,
  }
  local fn, env =
    loadCut(cut["local function registerNumericInputHandlers"], "registerNumericInputHandlers", stubs, mutate)
  fn({ bindingId = 9, key = "input_1" }, "input_1", sensorKey)
  env.RFP[9](9, "VALUE_CHANGED", tParams)
  return cached, updates
end

local MULTIPLEXER_CASES = {
  { what = "a NaN string on the temperature arm", key = "TEMP", params = { VALUE = "nan", SCALE = "CELSIUS" } },
  { what = "an infinity string on the temperature arm", key = "TEMP", params = { VALUE = "inf", SCALE = "CELSIUS" } },
  { what = "a NaN sent as CELSIUS", key = "TEMP", params = { CELSIUS = "nan" } },
  { what = "an overflowing exponent sent as FAHRENHEIT", key = "TEMP", params = { FAHRENHEIT = "1e999" } },
  { what = "a NaN string on the humidity arm", key = "HUM", params = { VALUE = "nan" } },
  { what = "an infinity string on the humidity arm", key = "HUM", params = { VALUE = "inf" } },
}

for _, case in ipairs(MULTIPLEXER_CASES) do
  local cached, updates = driveMultiplexer(case.key, case.params, false)
  T.eq(case.what .. " is not cached", cached[case.key], nil)
  T.eq(case.what .. " updates no output", updates, 0)

  -- Only the humidity arm is guarded by the driver, so only it has a revert.
  if case.key == "HUM" then
    local mutantCached = driveMultiplexer(case.key, case.params, true)
    T.check(
      case.what .. " IS cached once the fix is reverted",
      mutantCached[case.key] ~= nil,
      "the mutant rejected it too, so the case proves nothing"
    )
  end
end

local muxStillGuarded = driveMultiplexer("TEMP", { VALUE = "nan", SCALE = "CELSIUS" }, true)
T.eq("the temperature arm stays guarded with the driver's tofinite reverted", muxStillGuarded.TEMP, nil)

T.section("sensor_multiplexer: a finite reading still gets through")
local muxCached, muxUpdates = driveMultiplexer("TEMP", { VALUE = "21.5", SCALE = "CELSIUS" }, false)
T.eq("a Celsius reading is cached", muxCached.TEMP, 21.5)
T.eq("and it updates the outputs", muxUpdates, 1)
local muxHum = driveMultiplexer("HUM", { VALUE = "48" }, false)
T.eq("a humidity reading is cached", muxHum.HUM, 48)

--------------------------------------------------------------------------------
T.section("device_programmer: a non-finite command value is rejected")
--------------------------------------------------------------------------------

--- Drive one of the device_programmer command handlers once.
--- @param which string "Set_Temperature" or "Set_Humidity".
--- @param valueStr string The Value command parameter, as typed.
--- @param mutate boolean Revert the fix.
--- @return table persisted, table sent
local function driveProgrammer(which, valueStr, mutate)
  local persisted, sent = {}, {}
  local isTemperature = which == "Set_Temperature"
  local stubs = {
    EC = {},
    log = LOG_STUB,
    getTemperatureNames = function()
      return { "Outside" }
    end,
    getHumidityNames = function()
      return { "Outside" }
    end,
    nameExists = function(_names, name)
      return name == "Outside"
    end,
    normalizeScale = function()
      return "CELSIUS"
    end,
    getTemperatureScale = function()
      return "CELSIUS"
    end,
    convertTemperature = function(value)
      return value
    end,
    getTemperatureValues = function()
      return {}
    end,
    getHumidityValues = function()
      return {}
    end,
    PERSIST_TEMPERATURE_VALUES = "temps",
    PERSIST_HUMIDITY_VALUES = "hums",
    NS_TEMPERATURE = "temp",
    NS_HUMIDITY = "hum",
    persist = {
      set = function(_self, key, values)
        persisted[key] = values
      end,
    },
    bindings = {
      getDynamicBinding = function()
        return { bindingId = 300 }
      end,
    },
    sendTemperatureValue = function(_binding, value)
      table.insert(sent, value)
    end,
    sendHumidityValue = function(_binding, value)
      table.insert(sent, value)
    end,
  }
  local fn = loadCut(cut["function EC." .. which], "EC." .. which, stubs, mutate)
  fn({ Name = "Outside", Value = valueStr, Scale = "CELSIUS" })
  return persisted[isTemperature and "temps" or "hums"] or {}, sent
end

local PROGRAMMER_CASES = {
  { which = "Set_Temperature", what = "the word nan", value = "nan" },
  { which = "Set_Temperature", what = "the word inf", value = "inf" },
  { which = "Set_Temperature", what = "an exponent that overflows a double", value = "1e400" },
  { which = "Set_Humidity", what = "the word nan", value = "nan" },
  { which = "Set_Humidity", what = "an exponent that overflows a double", value = "1e400", clamped = true },
}

for _, case in ipairs(PROGRAMMER_CASES) do
  local persisted, sent = driveProgrammer(case.which, case.value, false)
  T.eq(case.which .. ": " .. case.what .. " persists nothing", persisted.Outside, nil)
  T.eq(case.which .. ": " .. case.what .. " sends nothing", #sent, 0)

  local mutantPersisted = driveProgrammer(case.which, case.value, true)
  local reverted = mutantPersisted.Outside
  if case.clamped then
    -- The clamp turns the reverted infinity into 100, which is still a value
    -- the user never typed.
    T.check(
      case.which .. ": " .. case.what .. " IS persisted once the fix is reverted",
      reverted ~= nil,
      "the mutant rejected it too, so the case proves nothing"
    )
  else
    T.check(
      case.which .. ": " .. case.what .. " IS persisted once the fix is reverted",
      reverted ~= nil and reverted ~= reverted or reverted == INF,
      "the mutant did not persist a non-finite value: " .. tostring(reverted)
    )
  end
end

T.section("device_programmer: a finite command value still works")
local tempPersisted, tempSent = driveProgrammer("Set_Temperature", "21.5", false)
T.eq("a real temperature is persisted", tempPersisted.Outside, 21.5)
T.eq("and sent to the binding", tempSent[1], 21.5)
local humPersisted = driveProgrammer("Set_Humidity", "48", false)
T.eq("a real humidity is persisted", humPersisted.Outside, 48)
local overPersisted = driveProgrammer("Set_Humidity", "150", false)
T.eq("an out-of-range humidity still clamps", overPersisted.Outside, 100)
local negativePersisted = driveProgrammer("Set_Temperature", "-40", false)
T.eq("a negative temperature is not mistaken for invalid", negativePersisted.Outside, -40)

--------------------------------------------------------------------------------
T.section("network_requests: a webhook body is bounded")
--------------------------------------------------------------------------------

--- Restore the single line this site had before the fix. Swapping `tofinite`
--- for `tonumber` does not revert it: the bound below rejects an infinity just
--- as readily as a large finite length, so the whole guard has to come out.
--- Anchored on the two surrounding statements rather than on the guard's own
--- text, so reformatting it does not quietly turn the mutant back into the fix.
local function revertWebhookGuard(src)
  local startPos = src:find("  local declaredLength", 1, true)
  local endPos = src:find("  local body = buffer:sub", 1, true)
  if startPos == nil or endPos == nil then
    return nil
  end
  return src:sub(1, startPos - 1)
    .. '  local contentLength = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0\n'
    .. src:sub(endPos)
end

--- Drive OnServerDataIn with one chunk of request bytes.
--- @param data string The bytes as received.
--- @param mutate boolean|function Revert the fix.
--- @return table buffers, table responses, table handled
local function driveWebhook(data, mutate)
  local responses, handled = {}, {}
  local stubs = {
    log = LOG_STUB,
    MAX_RESPONSE_BYTES = 8192,
    webhookBuffers = {},
    webhookRespond = function(_nHandle, code, reason)
      table.insert(responses, { code = code, reason = reason })
    end,
    handleWebhookRequest = function(_nHandle, method, rawPath, body)
      table.insert(handled, { method = method, path = rawPath, body = body })
    end,
  }
  local fn, env = loadCut(cut["function OnServerDataIn"], "OnServerDataIn", stubs, mutate)
  fn(1, data, "10.0.0.5")
  return env.webhookBuffers, responses, handled
end

local function request(lengthHeader, body)
  return "POST /hook HTTP/1.1\r\nHost: x\r\nContent-Length: " .. lengthHeader .. "\r\n\r\n" .. (body or "")
end

local WEBHOOK_CASES = {
  { what = "a Content-Length that overflows a double", header = string.rep("9", 400) },
  { what = "a Content-Length larger than the body bound", header = "99999999" },
}

-- Asserted once, so a source change that moves the anchors names itself here
-- rather than as a failure in every mutant arm below.
T.check(
  "the revert still finds the guard in the current source",
  revertWebhookGuard(cut["function OnServerDataIn"]) ~= nil,
  "the anchors no longer match, so the mutant arms cannot revert anything"
)

for _, case in ipairs(WEBHOOK_CASES) do
  local buffers, responses = driveWebhook(request(case.header, "hi"), false)
  T.eq(case.what .. " releases the connection buffer", buffers[1], nil)
  T.eq(case.what .. " is answered", responses[1] and responses[1].code, 413)

  -- pcall so that loadCut refusing a revert that matched nothing is reported as
  -- this case failing rather than aborting the file.
  local ok, mutantBuffers, mutantResponses = pcall(driveWebhook, request(case.header, "hi"), revertWebhookGuard)
  T.check(
    case.what .. " IS retained once the fix is reverted",
    ok and mutantBuffers[1] ~= nil and mutantResponses[1] == nil,
    ok and "the mutant released it too, so the case proves nothing" or tostring(mutantBuffers)
  )
end

T.section("network_requests: a normal webhook request is unaffected")
local okBuffers, okResponses, okHandled = driveWebhook(request("2", "hi"), false)
T.eq("the buffer is released", okBuffers[1], nil)
T.eq("no error response is sent", #okResponses, 0)
T.eq("the request is handled", okHandled[1] and okHandled[1].body, "hi")

local partialBuffers, partialResponses, partialHandled = driveWebhook(request("5", "hi"), false)
T.check("an incomplete body keeps buffering", partialBuffers[1] ~= nil)
T.eq("and is not answered yet", #partialResponses, 0)
T.eq("and is not handled yet", #partialHandled, 0)

local noLengthBuffers, noLengthResponses, noLengthHandled = driveWebhook("GET /hook HTTP/1.1\r\nHost: x\r\n\r\n", false)
T.eq("a request with no Content-Length is released", noLengthBuffers[1], nil)
T.eq("and is not rejected", #noLengthResponses, 0)
T.eq("and is handled with an empty body", noLengthHandled[1] and noLengthHandled[1].body, "")

-- The boundary itself, so the bound cannot drift without a failure.
local atBoundBuffers, atBoundResponses = driveWebhook(request("16384", "hi"), false)
T.check("a body declared exactly at the bound is accepted", atBoundResponses[1] == nil, atBoundResponses[1])
T.check("and keeps buffering", atBoundBuffers[1] ~= nil)
local overBoundResponses = select(2, driveWebhook(request("16385", "hi"), false))
T.eq("one byte over the bound is rejected", overBoundResponses[1] and overBoundResponses[1].code, 413)

T.finish()
