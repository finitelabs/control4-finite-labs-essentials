-- lib.ui.expression-tab: the expression editor's preview, answered as EVAL_RESULT with the page's id, in the modes the
-- driver allows, cut to its longest, held for what the driver refuses, with its own fields and behind its gate; and
-- lib.expressions' compileError, which a hold reads.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_ui_expression_tab.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.handlers")

local Expressions = require("lib.expressions")
local ExpressionTab = require("lib.ui.expression-tab")

ShimSetDevices({
  [100] = {
    deviceName = "Battery",
    roomName = "Garage",
    variables = {
      ["1001"] = { name = "LEVEL", value = "42", type = "NUMBER" },
      ["1002"] = { name = "STATE", value = "Charging", type = "STRING" },
      ["1003"] = { name = "NOTE", value = string.rep("\226\156\147", 20), type = "STRING" },
    },
  },
})

local sent = {}
function C4:SendDataToUI(command, params)
  sent[#sent + 1] = { command = command, data = JSON:decode(params.json) }
end

--- A command's DATA as lib/ui/page.js sends it.
local function page(params)
  return { DATA = C4:Base64Encode(JSON:encode(params)) }
end

--- Asks for a preview and returns what came back.
local function ask(params)
  sent = {}
  UIR._EVAL_EXPRESSION(page(params))
  T.eq("one answer for " .. tostring(params.expression), #sent, 1)
  T.eq("as EVAL_RESULT", sent[1] and sent[1].command, "EVAL_RESULT")
  return sent[1] and sent[1].data or {}
end

T.section("compileError")
T.eq("a template that compiles has none", Expressions.compileError("PARAM{100,1001} > 40"), nil)
T.eq("nor does one with a missing variable: values play no part", Expressions.compileError("PARAM{999,1} > 40"), nil)
T.contains(
  "one that doesn't has the compiler's words",
  Expressions.compileError("PARAM{100,1001} >"),
  "compile error: "
)
T.contains("worded as evaluate words it", Expressions.compileError("PARAM{100,1001} >"), "near '<eof>'")
T.contains("a lone = is one", Expressions.compileError("PARAM{100,1001} = 5"), "'<eof>' expected near '='")
T.eq("a token inside quotes stays text", Expressions.compileError('PARAM{100,1002} == "PARAM{100,1002}"'), nil)
T.eq("nothing at all compiles", Expressions.compileError(nil), nil)

T.section("serve, by default")
ExpressionTab.serve()
local reply = ask({ id = "x1-1", mode = "equation", expression = "PARAM{100,1001} + 1" })
T.eq("the page's id comes back", reply.id, "x1-1")
T.eq("with its references", reply.rendered, "[Garage > Battery > LEVEL] + 1")
T.eq("its current values", reply.substituted, "42 + 1")
T.eq("and the result as text", reply.result, "43")
T.eq("with no error", reply.error, "")
T.eq("and no hold", reply.hold, nil)
reply = ask({ id = "x1-2", mode = "condition", expression = 'PARAM{100,1002} == "Charging"' })
T.eq("a condition comes out true or false", reply.result, "true")
reply = ask({ id = "x1-3", mode = "string", expression = "Level PARAM{100,LEVEL}%" })
T.eq("a string is the text with its values", reply.result, "Level 42%")
reply = ask({ id = "x1-4", mode = "equation", expression = "PARAM{100,1002} + 1" })
T.contains("an error is the engine's", reply.error, "runtime error")
T.eq("with no result", reply.result, "")
reply = ask({ id = "x1-5", mode = "equation", expression = "PARAM{100,9999}" })
T.eq("a missing variable says so", reply.error, "variable 9999 not found on device 100")
T.eq("and its value reads as not found", reply.substituted, "ERROR_VARIABLE_NOT_FOUND")
reply = ask({ id = 7, mode = "nonsense", expression = "1 + 1" })
T.eq("a number id comes back as text", reply.id, "7")
T.eq("a mode it doesn't know is the first", reply.result, "2")
T.eq("a body that does not decode is still answered", ask({}).id, "")

T.section("serve, with a driver's options")
local holds, extras, gate = {}, {}, 0
ExpressionTab.serve({
  modes = { "condition", "string" },
  maxLength = 40,
  hold = function(expression, mode)
    holds[#holds + 1] = mode
    if expression:find("PARAM{200,", 1, true) then
      return "A look can't follow this button's own variables."
    end
    return mode == "condition" and Expressions.compileError(expression) or nil
  end,
  extra = function(evaluation, mode)
    extras[#extras + 1] = mode
    return { fitted = evaluation.result and tostring(evaluation.result):sub(1, 3) or nil, id = "stolen" }
  end,
  wrap = function(fn)
    return function(tParams)
      gate = gate + 1
      return fn(tParams)
    end
  end,
})
reply = ask({ id = "b1", mode = "equation", expression = "PARAM{100,1001} > 40" })
T.eq("the handler runs behind the driver's gate", gate, 1)
T.eq("a mode the driver doesn't allow is its first", holds[1], "condition")
T.eq("which evaluates it", reply.result, "true")
T.eq("the driver's fields are added", reply.fitted, "tru")
T.eq("but never over the kit's own", reply.id, "b1")
reply = ask({ id = "b2", mode = "condition", expression = "PARAM{100,1001} >" })
T.eq("a hold comes back as hold", reply.hold, true)
T.contains("with its reason as the error", reply.error, "compile error")
T.eq("and the references", reply.rendered, "[Garage > Battery > LEVEL] >")
T.eq("but no values: it isn't evaluated", reply.substituted, "")
T.eq("and no result", reply.result, "")
T.eq("the driver's fields still see it", extras[#extras], "condition")
reply = ask({ id = "b3", mode = "string", expression = "PARAM{200,1}" })
T.eq("a driver's own hold reason", reply.error, "A look can't follow this button's own variables.")
reply = ask({ id = "b4", mode = "string", expression = "Note: PARAM{100,NOTE} and the rest of a long text" })
T.eq("an expression past the longest is cut", reply.rendered, "Note: [Garage > Battery > NOTE] and the rest of a ")
reply = ask({ id = "b5", mode = "string", expression = "PARAM{100,NOTE}" })
T.eq("the values are cut to the longest too", #reply.substituted, 39)
T.eq("on a whole character", reply.substituted, string.rep("\226\156\147", 13))

T.finish()
