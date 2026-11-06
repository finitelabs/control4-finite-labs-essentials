-- Tests for lib/expressions.lua and lib/expression-sandbox.lua: PARAM{} tokens,
-- evaluation and its errors, what the sandbox reaches, debounced and ref-counted
-- watches, a device leaving the project, and waiting for a variable another driver
-- hasn't added yet.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_expressions.lua

local T = require("testlib")

require("c4_shim")

local Expressions = require("lib.expressions")
local sandbox = require("lib.expression-sandbox")

local listens, stops = {}, {}
local realListen, realStop = C4.RegisterVariableListener, C4.UnregisterVariableListener
function C4:RegisterVariableListener(deviceId, variableId)
  listens[#listens + 1] = deviceId .. ":" .. variableId
  return realListen(self, deviceId, variableId)
end
function C4:UnregisterVariableListener(deviceId, variableId)
  stops[#stops + 1] = deviceId .. ":" .. variableId
  return realStop(self, deviceId, variableId)
end

local function count(list, wanted)
  local n = 0
  for _, item in ipairs(list) do
    if item == wanted then
      n = n + 1
    end
  end
  return n
end

local function setDevices()
  ShimSetDevices({
    [100] = {
      deviceName = "Battery",
      roomName = "Garage",
      variables = {
        ["1001"] = { name = "LEVEL", value = "42", type = "NUMBER" },
        ["1002"] = { name = "STATE", value = "Charging", type = "STRING" },
      },
    },
    [200] = { deviceName = "Meter", roomName = "Garage", variables = { ["7"] = { name = "WATTS", value = "1500" } } },
    [300] = { deviceName = "Empty", roomName = "Attic" },
    [100001] = { variables = { ["2301"] = { name = "GLOBAL_LIMIT", value = "90" } } },
  })
end

--- An engine over a table of expressions, counting recomputes per name.
local function newEngine(expressions)
  local recomputed = {}
  return Expressions:new({
    getExpressions = function()
      return expressions
    end,
    recompute = function(name)
      recomputed[name] = (recomputed[name] or 0) + 1
    end,
  }),
    recomputed
end

setDevices()

T.section("Tokens")
local refs, missing = Expressions.references("PARAM{100,1001} + PARAM{ 100 , STATE } + PARAM{200,NOPE}")
T.eq("a numeric and a named token resolve", #refs, 2)
T.eq("the numeric one keeps its id", refs[1].variableId, 1001)
T.eq("the named one finds its id, spaces and all", refs[2].variableId, 1002)
T.eq("one by a name the device lacks is missing", #missing, 1)
T.eq("and names what it wanted", missing[1].variable, "NOPE")
T.eq("a token not listed yet has an id if it's numeric", #Expressions.references("PARAM{200,99}"), 1)
T.eq("and is still missing", #select(2, Expressions.references("PARAM{200,99}")), 1)

local text, problem = Expressions.substitute("PARAM{100,LEVEL}% and PARAM{100,1002}")
T.eq("values replace the tokens", text, "42% and Charging")
T.eq("with no problem", problem, nil)
T.contains("a token renders as its names", Expressions.render("PARAM{100,1001}"), "LEVEL]")

T.section("Evaluation")
T.eq("an equation gives a number", Expressions.evaluate("equation", "PARAM{100,LEVEL} * 2").result, 84)
T.eq("a condition gives true or false", Expressions.evaluate("condition", "PARAM{100,LEVEL} < 50").result, true)
T.eq("and false counts as a result", Expressions.evaluate("condition", "PARAM{100,LEVEL} > 50").result, false)
T.eq("a string is its substitution", Expressions.evaluate("string", "at PARAM{100,LEVEL}").result, "at 42")
T.eq("a global variable's agent reads too", Expressions.evaluate("equation", "PARAM{100001,GLOBAL_LIMIT}").result, 90)
T.eq("Essentials' helpers work", Expressions.evaluate("equation", "round(c2f(PARAM{100,LEVEL} - 42), 1)").result, 32)

local evaluation = Expressions.evaluate("equation", "PARAM{100,LEVEL} +")
T.contains("a syntax error says so", evaluation.error, "compile error")
T.eq("and has no result", evaluation.result, nil)
T.contains("a runtime error says so", Expressions.evaluate("equation", "nothing.here").error, "runtime error")
T.contains(
  "a missing device is named",
  Expressions.evaluate("equation", "PARAM{999,LEVEL} + 1").error,
  "device 999 not found"
)
T.contains(
  "a device with no such variable is told apart",
  Expressions.evaluate("equation", "PARAM{100,NOPE} + 1").error,
  "variable NOPE not found on device 100"
)
T.contains(
  "so is one on a device with no variables at all",
  Expressions.evaluate("equation", "PARAM{300,NOPE}").error,
  "variable NOPE not found on device 300"
)
T.contains(
  "a device that isn't a number is missing",
  Expressions.evaluate("string", "PARAM{abc,X}").error,
  "device abc"
)
T.contains(
  "the text marks what's missing",
  Expressions.evaluate("equation", "PARAM{999,LEVEL} + 1").substituted,
  "ERROR_VARIABLE_NOT_FOUND"
)
T.contains(
  "an equation that isn't a number says so",
  Expressions.evaluate("equation", '"text"').error,
  "not a number (got string)"
)
T.contains(
  "a condition that isn't true or false says so",
  Expressions.evaluate("condition", "1").error,
  "not a boolean (got number)"
)

T.section("A value can't become code")
-- A value that ran as code would hang here, not fail, so a hook turns that into an error.
local function guarded(fn)
  debug.sethook(function()
    error("a value ran as code")
  end, "", 50000000)
  local a, b = fn()
  debug.sethook()
  return a, b
end
local LOOP = '"..(function() while true do end end)().."'
local RUNS = "(function() return 1 end)()"
local valueDevices = {
  [800] = {
    deviceName = "Values",
    variables = {
      ["1"] = { name = "LOOP", value = LOOP },
      ["2"] = { name = "EXIT", value = "os.exit()" },
      ["3"] = { name = "OBRIEN", value = "O'Brien" },
      ["4"] = { name = "SLASH", value = 'a"b\\c' },
      ["5"] = { name = "TEXT", value = "On" },
      ["6"] = { name = "NUM", value = "7" },
      ["7"] = { name = "FLOAT", value = "2.5" },
      ["8"] = { name = "YES", value = "true" },
      ["9"] = { name = "NO", value = "false" },
      ["10"] = { name = "LINES", value = "one\ntwo\rthree" },
      ["11"] = { name = "CONTROL", value = "a\1b\0c" },
      ["12"] = { name = "BACKSLASH", value = "ends\\" },
      ["13"] = { name = "RUNS", value = RUNS },
      ["14"] = { name = "CLOSES", value = "a]]..os.exit()..[[b" },
      ["15"] = { name = "EMPTY", value = "" },
      ["16"] = { name = "NAN", value = "nan" },
      ["17"] = { name = "NANCAP", value = "NaN" },
      ["18"] = { name = "INF", value = "inf" },
      ["19"] = { name = "INFCAP", value = "INF" },
      ["20"] = { name = "INFINITY", value = "Infinity" },
      ["21"] = { name = "NEGINF", value = "-inf" },
    },
  },
}
ShimSetDevices(valueDevices)
local function condition(template)
  return guarded(function()
    local evaluated = Expressions.evaluate("condition", template)
    return evaluated.result, evaluated.error
  end)
end
for _, case in ipairs({
  { "a value that breaks out of a string, unquoted", "PARAM{800,LOOP} == '" .. LOOP .. "'" },
  { "and quoted", '"PARAM{800,LOOP}" == \'' .. LOOP .. "'" },
  { "and in single quotes", "'PARAM{800,LOOP}' == '" .. LOOP .. "'" },
  { "a value that calls os.exit, unquoted", 'PARAM{800,EXIT} == "os.exit()"' },
  { "and quoted", '"PARAM{800,EXIT}" == "os.exit()"' },
  { "a value with an apostrophe, unquoted", 'PARAM{800,OBRIEN} == "O\'Brien"' },
  { "and in double quotes", '"PARAM{800,OBRIEN}" == "O\'Brien"' },
  { "and in single quotes", "'PARAM{800,OBRIEN}' == \"O'Brien\"" },
  { "a value with a quote and a backslash, unquoted", [[PARAM{800,SLASH} == 'a"b\\c']] },
  { "and in double quotes", [["PARAM{800,SLASH}" == 'a"b\\c']] },
  { "and in single quotes", [['PARAM{800,SLASH}' == 'a"b\\c']] },
  { "a value that ends in a backslash stays inside its quotes", [["PARAM{800,BACKSLASH}" == 'ends\\']] },
  { "newlines stay in the text", [["PARAM{800,LINES}" == "one\ntwo\rthree"]] },
  { "and every other control character", [[#"PARAM{800,CONTROL}" == 5]] },
  { "an unquoted string compares with a literal", 'PARAM{800,TEXT} == "On"' },
  { "nan stays a word", 'PARAM{800,NAN} == "nan"' },
  { "in any case", 'PARAM{800,NANCAP} == "NaN"' },
  { "inf stays a word", 'PARAM{800,INF} == "inf"' },
  { "in any case", 'PARAM{800,INFCAP} == "INF"' },
  { "infinity stays a word", 'PARAM{800,INFINITY} == "Infinity"' },
  { "with a sign too", 'PARAM{800,NEGINF} == "-inf"' },
  { "a commented-out token isn't read", "PARAM{800,TEXT} == 'On' -- PARAM{800,NOPE}" },
  { "nor one in a block comment", "PARAM{800,TEXT} --[[ PARAM{800,NOPE} ]] == 'On'" },
  { "as does an empty one", 'PARAM{800,EMPTY} == ""' },
  { "a long string takes a value", '[[PARAM{800,TEXT}]] == "On"' },
  { "without its close letting one out", '[[PARAM{800,CLOSES}]] == "a]]..os.exit()..[[b"' },
  { "a comment ended by a lone CR leaves the next token in code", '1 -- x\r== 1 and PARAM{800,EXIT} == "os.exit()"' },
  { "and with a quote in the value", [==[ [[PARAM{800,SLASH}]] == 'a"b\\c' ]==] },
  { "an escaped quote doesn't end the string around a token", [["a\"PARAM{800,TEXT}" == 'a"On']] },
  { "an escaped backslash doesn't hide its closing quote", [["a\\" == 'a\\' and PARAM{800,NUM} == 7]] },
  { "a long string's own quote stays text beside a value", [==[ [[a"PARAM{800,TEXT}]] == 'a"On' ]==] },
  { "a long string with no token stays as it is", "[[a\"b]] == 'a\"b'" },
  { "numbers compare", "PARAM{800,NUM} > 5" },
  { "a number in quotes is its text", '"PARAM{800,NUM}" == "7"' },
  { "booleans compare", "PARAM{800,YES} == true" },
  { "and negate", "not PARAM{800,NO}" },
  { "two values in one expression", "PARAM{800,NUM} > PARAM{800,FLOAT}" },
  { "the same token twice", "PARAM{800,NUM} == PARAM{800,NUM}" },
  { "a token in a comment stays a comment", 'PARAM{800,TEXT} == "On" -- PARAM{800,LOOP}' },
}) do
  local result, err = condition(case[2])
  T.eq(case[1], result, true)
  T.eq("  " .. case[2], err, nil)
end

T.eq("arithmetic still works", Expressions.evaluate("equation", "PARAM{800,NUM} * 2 + PARAM{800,FLOAT}").result, 16.5)
T.eq("with the same token twice", Expressions.evaluate("equation", "PARAM{800,NUM} * PARAM{800,NUM}").result, 49)
T.contains(
  "arithmetic on text is an error, not code",
  Expressions.evaluate("equation", "PARAM{800,RUNS} + 1").error,
  "runtime error"
)
T.contains(
  "so is a string where a number belongs",
  Expressions.evaluate("equation", "PARAM{800,TEXT}").error,
  "not a number (got string)"
)
local afterComment = Expressions.evaluate("equation", "1 -- don't\n + PARAM{800,RUNS}")
T.eq("an apostrophe in a comment doesn't put a value in code", afterComment.result, nil)
T.contains("it stays data, so this is an error", afterComment.error, "runtime error")
T.eq("and the token after one still reads", Expressions.evaluate("equation", "1 -- don't\n + PARAM{800,NUM}").result, 8)
T.eq(
  "as does one after a block comment",
  Expressions.evaluate("equation", "1 --[[ don't ]] + PARAM{800,NUM}").result,
  8
)
local afterBlock = Expressions.evaluate("equation", "1 --[[ don't ]] + PARAM{800,RUNS}")
T.eq("nor does one in a block comment", afterBlock.result, nil)
T.contains("the same error", afterBlock.error, "runtime error")
local missed = Expressions.evaluate("condition", "PARAM{800,NOPE} == nil")
T.contains("a missing variable keeps its clear error", missed.error, "variable NOPE not found on device 800")
T.eq("and never evaluates", missed.result, nil)
local refsNow, missingNow = Expressions.references("PARAM{800,TEXT} -- PARAM{800,NOPE}")
T.eq("a commented-out token isn't a reference", #refsNow, 1)
T.eq("nor is it waited for", #missingNow, 0)
T.eq("a comment stays in the display text", Expressions.substitute("1 -- PARAM{800,NOPE}"), "1 -- PARAM{800,NOPE}")
T.eq(
  "text has no comments, so a token after -- substitutes",
  Expressions.substitute("a -- PARAM{800,TEXT}", "string"),
  "a -- On"
)
T.eq(
  "and evaluating it agrees",
  Expressions.evaluate("string", "Power -- PARAM{800,TEXT} [[PARAM{800,TEXT}]]").result,
  "Power -- On [[On]]"
)
local _, textMissing = Expressions.references("a -- PARAM{800,NOPE}", "string")
T.eq("and it's a reference there", #textMissing, 1)
local commented, commentedCounts = newEngine({
  code = { template = "PARAM{800,TEXT} -- PARAM{800,NOPE}", auto = true },
  text = { template = "a -- PARAM{800,TEXT}", mode = "string", auto = true },
})
commented:resubscribeAll()
T.eq("a commented-out token isn't watched", commented:watchedCount("code"), 1)
T.eq("a token after -- in text is", commented:watchedCount("text"), 1)
ShimFireTimers()
T.eq("nothing's waited for, so nothing recomputes", commentedCounts.code, nil)
commented:unsubscribeExpression("code")
commented:unsubscribeExpression("text")
local plain = Expressions.evaluate("string", "at PARAM{800,LOOP}")
T.eq("text that isn't evaluated is plain substitution", plain.result, "at " .. LOOP)

local realLoadstring = loadstring
local compiles = 0
loadstring = function(...) -- luacheck: ignore
  compiles = compiles + 1
  return realLoadstring(...)
end
for level = 1, 50 do
  valueDevices[800].variables["6"].value = tostring(level)
  T.eq("  value " .. level, Expressions.evaluate("equation", "PARAM{800,NUM} + 12345").result, level + 12345)
end
loadstring = realLoadstring -- luacheck: ignore
T.eq("the compile cache holds across values", compiles, 1)

T.section("Essentials' documented examples")
ShimSetDevices({
  [96] = {
    deviceName = "Sensor A",
    variables = {
      ["1001"] = { name = "Temperature", value = "70.5" },
      ["1002"] = { name = "Humidity", value = "52.5" },
    },
  },
  [97] = {
    deviceName = "Sensor B",
    variables = { ["1001"] = { name = "Temperature", value = "71" }, ["1002"] = { name = "Humidity", value = "44.9" } },
  },
  [98] = { deviceName = "Sensor C", variables = { ["1001"] = { name = "Temperature", value = "72.5" } } },
  [120] = {
    deviceName = "Pool",
    variables = { ["2001"] = { name = "Pool", value = "82" }, ["2002"] = { name = "Spa", value = "101" } },
  },
  [2795] = { deviceName = "Espresso", variables = { ["1017"] = { name = "Watts", value = "1343" } } },
  [2675] = { deviceName = "Meter", variables = { ["1003"] = { name = "Daily", value = "36" } } },
})
for _, case in ipairs({
  { "equation", "PARAM{96,1002} > 50 and 1 or 0", 1 },
  { "equation", "PARAM{96,Humidity} > 50 and 1 or 0", 1 },
  { "equation", "abs(PARAM{96,1002} - PARAM{97,1002})", 7.6 },
  { "equation", "round((PARAM{96,1001} + PARAM{97,1001} + PARAM{98,1001}) / 3, 1)", 71.3 },
  { "equation", "PARAM{2675,1003} / 24", 1.5 },
  { "string", "Pool PARAM{120,2001}F / Spa PARAM{120,2002}F", "Pool 82F / Spa 101F" },
  { "string", "Espresso: PARAM{2795,1017} W", "Espresso: 1343 W" },
}) do
  local got = Expressions.evaluate(case[1], case[2]).result
  if type(got) == "number" then
    got = round(got, 1)
  end
  T.eq(case[2], got, case[3])
end
setDevices()

T.section("What the sandbox reaches")
for _, name in ipairs({ "io", "os", "require", "loadstring", "load", "dofile", "getfenv", "setfenv", "_G", "debug" }) do
  local result = sandbox.eval(name)
  T.eq(name .. " isn't reachable", result, nil)
end
T.eq("string.dump isn't reachable", sandbox.eval("string.dump"), nil)
T.eq('and nor is it through a string, ("").dump', sandbox.eval('("").dump'), nil)
T.truthy("while the driver keeps its own", string.dump)
sandbox.eval("nothing.here")
T.truthy("and still does after an expression fails", string.dump)
local realFormat = string.format
local _, changing = sandbox.eval("(function() string.format = nil end)()")
T.contains("an expression can't change the string table", changing, "can't change")
T.eq("which stays whole", string.format, realFormat)
local realFloor = math.floor
local _, mathChange = sandbox.eval("(function() math.floor = nil end)()")
T.contains("nor the math table", mathChange, "can't change")
T.eq("which stays whole too", math.floor, realFloor)
T.eq("reading them still works", sandbox.eval('string.upper("a") .. math.floor(1.5)'), "A1")
local _, stay = sandbox.eval("(function() leaked = 1 end)()")
T.eq("a global an expression sets doesn't error", stay, nil)
T.eq("and doesn't reach the driver", leaked, nil) -- luacheck: ignore

T.section("Debounce")
local storm = { power = { template = "PARAM{200,WATTS}", auto = true } }
local engine, recomputed = newEngine(storm)
engine:subscribeExpression("power")
T.eq("a watch registers its variable's listener", count(listens, "200:7"), 1)
OnWatchedVariableChanged(200, 7, "1")
OnWatchedVariableChanged(200, 7, "2")
OnWatchedVariableChanged(200, 7, "3")
T.eq("a change only schedules work", recomputed.power, nil)
ShimFireTimers()
T.eq("a burst of changes is one recompute", recomputed.power, 1)
ShimFireTimers()
T.eq("and nothing is left over", recomputed.power, 1)
engine:unsubscribeExpression("power")

T.section("A failing recompute")
local failing = Expressions:new({
  getExpressions = function()
    return { bad = { template = "PARAM{200,WATTS}", auto = true } }
  end,
  recompute = function()
    error("nope")
  end,
})
failing:subscribeExpression("bad")
OnWatchedVariableChanged(200, 7, "1")
T.truthy(
  "stays inside the engine",
  pcall(function()
    ShimFireTimers()
  end)
)
failing:unsubscribeExpression("bad")

T.section("Ref counts")
listens, stops = {}, {}
local shared = {
  one = { template = "PARAM{100,LEVEL}", auto = true },
  two = { template = "PARAM{100,LEVEL} + PARAM{100,1001} + PARAM{200,WATTS}", auto = true },
  off = { template = "PARAM{300,1}", auto = false },
}
local counted, counts = newEngine(shared)
counted:resubscribeAll()
T.eq("two expressions share one listener", count(listens, "100:1001"), 1)
T.eq("a token used twice counts once", counted:watchedCount("two"), 2)
T.eq("one that isn't auto isn't watched", counted:watchedCount("off"), 0)
counted:subscribeExpression("gone")
T.eq("nor is one that doesn't exist", counted:watchedCount("gone"), 0)
OnWatchedVariableChanged(100, 1001, "1")
ShimFireTimers()
T.eq("a change recomputes the first", counts.one, 1)
T.eq("and the second", counts.two, 1)
local stopsBefore = count(stops, "100:1001")
counted:unsubscribeExpression("one")
T.eq("unwatching one keeps the shared listener", count(stops, "100:1001"), stopsBefore)
OnWatchedVariableChanged(100, 1001, "2")
ShimFireTimers()
T.eq("the other still recomputes", counts.two, 2)
T.eq("and the unwatched one doesn't", counts.one, 1)
counted:unsubscribeExpression("two")
T.eq("the last one out stops the listener", count(stops, "100:1001"), stopsBefore + 1)
OnWatchedVariableChanged(100, 1001, "3")
ShimFireTimers()
T.eq("after which a change does nothing", counts.two, 2)
counted:subscribeExpression("one")
T.eq("watching again listens again", counted:watchedCount("one"), 1)
shared.one.template = "PARAM{200,WATTS}"
counted:refreshExpression("one")
OnWatchedVariableChanged(200, 7, "9")
ShimFireTimers()
T.eq("an edit moves the watch", counts.one, 2)
counted:unsubscribeExpression("one")

T.section("A driver's own variables send no events")
local own, ownCounts = newEngine({
  writer = { template = "PARAM{200,WATTS}", auto = true },
  reader = { template = "PARAM{200,WATTS} + 1", auto = true },
})
own:resubscribeAll()
own:notifyVariableChanged(200, 7, "writer")
ShimFireTimers()
T.eq("the driver's notice reaches a reader", ownCounts.reader, 1)
T.eq("but not the expression that wrote it", ownCounts.writer, nil)
own:unsubscribeExpression("writer")
own:unsubscribeExpression("reader")

T.section("A device leaves the project")
ShimSetDevices({
  [400] = { deviceName = "Leaving", variables = { ["1"] = { name = "A", value = "1" } } },
  [500] = { deviceName = "Staying", variables = { ["2"] = { name = "B", value = "2" } } },
})
listens, stops = {}, {}
local leaving, leavingCounts = newEngine({
  uses = { template = "PARAM{400,A} + PARAM{500,B}", auto = true },
  other = { template = "PARAM{500,B}", auto = true },
})
leaving:resubscribeAll()
local affected = leaving:handleDeviceRemoved("400")
T.eq("it names the expressions that used it", table.concat(affected, ","), "uses")
-- One stop comes with the vendored register, which clears before it sets.
T.eq("and stops listening to it", count(stops, "400:1"), 2)
ShimFireTimers()
T.eq("they recompute", leavingCounts.uses, 1)
T.eq("others don't", leavingCounts.other, nil)
T.eq("what's left stays watched", leaving:watchedCount("uses"), 1)
T.contains(
  "evaluating gives an error result, even before Director forgets it",
  Expressions.evaluate("equation", "PARAM{400,A} + 1").error,
  "device 400 was removed from the project"
)
T.eq("the rest still evaluates", Expressions.evaluate("equation", "PARAM{500,B} + 1").result, 3)
local _, stillMissing = Expressions.references("PARAM{400,A}")
T.eq("and it isn't waited for", #stillMissing, 0)
leaving:unsubscribeExpression("uses")
leaving:unsubscribeExpression("other")

T.section("A variable another driver hasn't added yet")
ShimSetDevices({ [600] = { deviceName = "Late", variables = {} } })
listens, stops = {}, {}
local late, lateCounts = newEngine({ byName = { template = "PARAM{600,VALUE}", auto = true } })
late:subscribeExpression("byName")
T.eq("it can't be watched yet", late:watchedCount("byName"), 0)
ShimFireTimers()
T.eq("still can't after a try", late:watchedCount("byName"), 0)
T.eq("and nothing recomputes", lateCounts.byName, nil)
ShimSetDevices({ [600] = { deviceName = "Late", variables = { ["5"] = { name = "VALUE", value = "8" } } } })
ShimFireTimers()
T.eq("once it exists it's watched", late:watchedCount("byName"), 1)
T.eq("with a listener", count(listens, "600:5"), 1)
ShimFireTimers()
T.eq("and the expression catches up", lateCounts.byName, 1)
ShimFireTimers()
T.eq("the tries stop", lateCounts.byName, 1)
OnWatchedVariableChanged(600, 5, "9")
ShimFireTimers()
T.eq("and its changes recompute it", lateCounts.byName, 2)
late:unsubscribeExpression("byName")

ShimSetDevices({ [610] = { deviceName = "Late", variables = {} } })
listens, stops = {}, {}
local numeric, numericCounts = newEngine({ byId = { template = "PARAM{610,5}", auto = true } })
numeric:subscribeExpression("byId")
T.eq("a numeric id is watched at once, as it has an id", numeric:watchedCount("byId"), 1)
T.eq("with a listener", count(listens, "610:5"), 1)
ShimSetDevices({ [610] = { deviceName = "Late", variables = { ["5"] = { name = "VALUE", value = "8" } } } })
ShimFireTimers()
T.eq("once it exists the listener is set again", count(listens, "610:5"), 2)
ShimFireTimers()
T.eq("and the expression catches up", numericCounts.byId, 1)
numeric:unsubscribeExpression("byId")

ShimSetDevices({ [620] = { deviceName = "Never", variables = {} } })
local never, neverCounts = newEngine({ never = { template = "PARAM{620,VALUE}", auto = true } })
local arms, retryDelay = 0, nil
local realSetTimer = SetTimer
SetTimer = function(name, delay, ...) -- luacheck: ignore
  if tostring(name):find("ExprRetry", 1, true) then
    arms = arms + 1
    retryDelay = delay
  end
  return realSetTimer(name, delay, ...)
end
never:subscribeExpression("never")
T.eq("a try waits its interval", retryDelay, Expressions.RETRY_MS)
for _ = 1, Expressions.RETRY_ATTEMPTS + 5 do
  ShimFireTimers()
end
T.eq("one that never comes stops being tried", arms, Expressions.RETRY_ATTEMPTS)
T.eq("without recomputing", neverCounts.never, nil)
never:unsubscribeExpression("never")

arms = 0
local dropped = newEngine({ dropped = { template = "PARAM{620,VALUE}", auto = true } })
dropped:subscribeExpression("dropped")
dropped:unsubscribeExpression("dropped")
for _ = 1, 3 do
  ShimFireTimers()
end
T.eq("unwatching one ends its tries", arms, 1)

arms = 0
ShimSetDevices({ [630] = { deviceName = "Removed", variables = {} } })
local removedLate = newEngine({ removed = { template = "PARAM{630,VALUE}", auto = true } })
removedLate:subscribeExpression("removed")
removedLate:handleDeviceRemoved(630)
for _ = 1, 3 do
  ShimFireTimers()
end
T.eq("a device that left isn't tried for long", arms, 1)
removedLate:unsubscribeExpression("removed")
SetTimer = realSetTimer -- luacheck: ignore

T.section("The device browser")
ShimSetDevices({
  [700] = {
    deviceName = "Light",
    roomName = "Hall",
    proxies = { [701] = true },
    variables = { ["1"] = { name = "OWN" } },
  },
  [701] = {
    deviceName = "Light",
    roomName = "Hall",
    driverFileName = "light_v2.c4i",
    variables = { ["2"] = { name = "LEVEL" } },
  },
  [710] = { deviceName = "Lamp", roomName = "Attic", variables = { ["1"] = { name = "A" } } },
  [711] = { deviceName = "Lamp", roomName = "Attic", variables = { ["1"] = { name = "B" } } },
  [720] = { deviceName = "Nothing", roomName = "Attic" },
})
local devices = Expressions.devices()
T.eq("a driver and the proxy restating it are one entry, and the empty one is left out", #devices, 3)
T.eq("by room first", devices[1].roomName, "Attic")
T.eq("names that collide get their id", devices[1].name, "Lamp (710)")
T.eq("the proxy's owner stands for both", devices[3].id, 700)
local vars = Expressions.deviceVariables("700")
T.eq("a device's variables include its proxy's", #vars, 2)
T.eq("its own come first", vars[1].name, "OWN")
T.eq("under its own heading", vars[1].section, "Device")
T.eq("the proxy's name its .c4i", vars[2].section, "light_v2")
T.eq("a type is defaulted", vars[1].type, "STRING")
T.eq("an id that isn't a number gives nothing", Expressions.deviceVariables("x"), nil)

T.finish()
