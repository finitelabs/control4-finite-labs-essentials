-- Variable Expressions reads a variable's value as data: a value can't break an expression or run as part of one, the
-- documentation's examples give what they say, and the driver's device browser and own-variable watches keep working.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_expression_values.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

local ROOT = (debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./") .. "../"

local function data(t)
  return { DATA = C4:Base64Encode(JSON:encode(t)) }
end

H.load("variable_expressions", H.LICENSED)

--- The project's variables: device 96 and 97 hold numbers, 98 a temperature, 120 a pool and a spa, and 200 whatever
--- text a test gives it.
local function project(title, humidity)
  ShimSetDevices({
    [96] = {
      deviceName = "Bath Sensor",
      roomName = "Bath",
      variables = {
        ["1001"] = { name = "Temperature", value = "70" },
        ["1002"] = { name = "Humidity", value = humidity or "60" },
      },
    },
    [97] = {
      deviceName = "Hall Sensor",
      roomName = "Hall",
      variables = {
        ["1001"] = { name = "Temperature", value = "71" },
        ["1002"] = { name = "Humidity", value = "45" },
      },
    },
    [98] = {
      deviceName = "Attic Sensor",
      roomName = "Attic",
      variables = { ["1001"] = { name = "Temperature", value = "73" } },
    },
    [120] = {
      deviceName = "Pool",
      roomName = "Yard",
      variables = { ["2001"] = { name = "Pool", value = "82" }, ["2002"] = { name = "Spa", value = "101" } },
    },
    [200] = { deviceName = "Player", roomName = "Den", variables = { ["1"] = { name = "Title", value = title or "" } } },
  })
end

--- What the editor's preview gets for a draft, stopping any loop instead of hanging the test.
local function eval(mode, template)
  debug.sethook(function()
    error("ran too long")
  end, "", 2000000)
  local answer = JSON:decode(UIR._EVAL_EXPRESSION(data({ id = "1", mode = mode, template = template })))
  debug.sethook()
  return answer
end

project()

T.section("The documentation's examples")
do
  T.eq("a comparison, over 50", eval("equation", "PARAM{96,1002} > 50 and 1 or 0").result, "1")
  T.eq("a comparison, under 50", eval("equation", "PARAM{97,1002} > 50 and 1 or 0").result, "0")
  T.eq("a difference", eval("equation", "abs(PARAM{96,1002} - PARAM{97,1002})").result, "15")
  T.eq(
    "an average",
    eval("equation", "round((PARAM{96,1001} + PARAM{97,1001} + PARAM{98,1001}) / 3, 1)").result,
    "71.3"
  )
  T.eq("a string", eval("string", "Pool PARAM{120,2001}F / Spa PARAM{120,2002}F").result, "Pool 82F / Spa 101F")
  T.eq("a variable by name", eval("equation", "PARAM{96,Humidity} + 1").result, "61")
  T.eq("spaces in a token", eval("equation", "PARAM{ 96 , 1002 } + 1").result, "61")
  T.eq("the math library", eval("equation", "math.floor(PARAM{96,1001} / 3)").result, "23")
  T.eq("the string library", eval("equation", 'tonumber(string.format("%.1f", PARAM{96,1001} / 3))').result, "23.3")
  T.eq("a preview shows the values", eval("equation", "PARAM{96,1002} + 1").substituted, "60 + 1")
end

T.section("A value holding a quote doesn't break an expression")
do
  project('He said "hi" & it\'s')
  local answer = eval("equation", "PARAM{200,Title} ~= '' and 1 or 0")
  T.eq("a token reads it", answer.result, "1")
  T.eq("with no error", answer.error, "")
  T.eq(
    "the same text compares equal",
    eval("equation", [[PARAM{200,Title} == 'He said "hi" & it\'s' and 1 or 0]]).result,
    "1"
  )
  T.eq("a token inside a string reads it", eval("equation", [["PARAM{200,Title}" ~= "" and 1 or 0]]).result, "1")
  T.eq("string mode keeps it as it is", eval("string", "Now: PARAM{200,Title}").result, 'Now: He said "hi" & it\'s')
end

T.section("A value holding code doesn't run")
do
  project("1+1")
  T.eq("it stays its text", eval("equation", 'PARAM{200,Title} == "1+1" and 1 or 0').result, "1")
  project('"end" .. string.rep("x", 3)')
  T.eq(
    "a call in it stays text",
    eval("equation", [[#PARAM{200,Title}]]).result,
    tostring(#'"end" .. string.rep("x", 3)')
  )
  project("math.huge")
  T.eq("a name in it stays text", eval("equation", 'PARAM{200,Title} == "math.huge" and 1 or 0').result, "1")
end

T.section("A loop passed as a value doesn't hang the driver")
do
  project("(function() while true do end end)()")
  local answer = eval("equation", 'PARAM{200,Title} == "x" and 1 or 0')
  T.eq("it's text, compared and done", answer.result, "0")
  T.eq("with no error", answer.error, "")
end

T.section("Text compares as text")
do
  project("On")
  T.eq("a match", eval("equation", 'PARAM{200,Title} == "On" and 1 or 0').result, "1")
  project("Off")
  T.eq("no match", eval("equation", 'PARAM{200,Title} == "On" and 1 or 0').result, "0")
  project("true")
  T.eq("true reads as a boolean", eval("equation", "PARAM{200,Title} and 1 or 0").result, "1")
  project("false")
  T.eq("false reads as a boolean", eval("equation", "PARAM{200,Title} and 1 or 0").result, "0")
end

T.section("A saved expression gets the same")
do
  project('a "quoted" title')
  UIR._SAVE_EXPRESSION(data({ name = "Is Set", mode = "equation", template = "PARAM{200,Title} ~= '' and 1 or 0" }))
  T.eq("its result variable", Variables["Is Set Result"], "1")
  local config = JSON:decode(UIR._GET_CONFIG())
  local row = JSON:decode(config.expressions)[1]
  T.eq("its row has no error", row.error, nil)
  T.eq("its row names the variable", row.rendered:find("Title", 1, true) ~= nil, true)
  UIR._DELETE_EXPRESSION(data({ name = "Is Set" }))
end

T.section("A missing variable reads as an unresolved reference")
do
  project()
  local answer = eval("equation", "PARAM{96,1999} + 1")
  T.eq("no result", answer.result, "")
  T.check("the error says what's missing", answer.error:find("not found", 1, true) ~= nil, answer.error)
  local file = assert(io.open(ROOT .. "drivers/variable_expressions/www/html/index.html"))
  local page = file:read("*a")
  file:close()
  T.check("and the page's row labels that", page:find("/unresolved|not found/.test(err)", 1, true) ~= nil)
end

T.section("An expression over another's result recomputes when that result changes")
do
  project()
  UIR._SAVE_EXPRESSION(data({ name = "First", mode = "equation", template = "PARAM{96,1002} + 1", auto = true }))
  local firstId
  for id, variable in pairs(C4:GetDeviceVariables(C4:GetDeviceID())) do
    if variable.name == "First Result" then
      firstId = id
    end
  end
  T.neq("the result is a variable", firstId, nil)
  UIR._SAVE_EXPRESSION(data({
    name = "Second",
    mode = "equation",
    template = string.format("PARAM{%d,%s} * 2", C4:GetDeviceID(), firstId),
    auto = true,
  }))
  T.eq("the second reads the first", Variables["Second Result"], "122")
  T.eq("the first watches a variable", JSON:decode(JSON:decode(UIR._GET_CONFIG()).expressions)[1].watched, 1)
  project(nil, "70")
  UIR._RUN_EXPRESSION(data({ name = "First" }))
  T.eq("the first recalculates", Variables["First Result"], "71")
  T.eq("the second waits for its debounce", Variables["Second Result"], "122")
  ShimFireTimers()
  T.eq("then follows it", Variables["Second Result"], "142")
  UIR._DELETE_EXPRESSION(data({ name = "Second" }))
  UIR._DELETE_EXPRESSION(data({ name = "First" }))
end

T.section("A removed device shows on its expression's row")
do
  project()
  UIR._SAVE_EXPRESSION(data({ name = "Gone", mode = "equation", template = "PARAM{97,1002} + 1", auto = true }))
  OnDeviceRemovedFromProject(97)
  ShimFireTimers()
  local row = JSON:decode(JSON:decode(UIR._GET_CONFIG()).expressions)[1]
  T.check("it names the removal", tostring(row.error):find("removed", 1, true) ~= nil, row.error)
  T.eq("and keeps its last result", row.result, "46")
  UIR._DELETE_EXPRESSION(data({ name = "Gone" }))
end

T.section("The device browser")
do
  project()
  local answer = JSON:decode(UIR._GET_DEVICES())
  local devices = JSON:decode(answer.devices)
  T.eq("it lists devices with variables", devices[1].name, "Attic Sensor")
  local variables = JSON:decode(UIR._GET_DEVICE_VARIABLES(data({ deviceId = 96 })))
  T.eq("it answers for the device", variables.deviceId, "96")
  T.eq("with its variables", #JSON:decode(variables.variables), 2)
  T.eq("a device with no id answers nothing", UIR._GET_DEVICE_VARIABLES(data({})), nil)
end

T.finish()
