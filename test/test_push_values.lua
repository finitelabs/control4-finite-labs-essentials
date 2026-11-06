-- What the tabs get pushed keeps its exact text: the socket reads a param like 12.50, 007 or false as a number or a
-- boolean, so results go as one JSON string.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_push_values.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

local ROOT = (debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./") .. "../"

local function readFile(path)
  local fh = assert(io.open(ROOT .. path, "r"))
  local body = fh:read("*a")
  fh:close()
  return body
end

local function data(t)
  return { DATA = C4:Base64Encode(JSON:encode(t)) }
end

local pushes = {}

--- Loads a driver and records what it pushes.
local function load(driver)
  H.load(driver, H.LICENSED)
  function C4:SendDataToUI(command, params)
    pushes[#pushes + 1] = { command = command, params = params }
  end
end

--- The last push of a command, decoded, checking it was one JSON string param.
local function pushed(command)
  for i = #pushes, 1, -1 do
    if pushes[i].command == command then
      local params = pushes[i].params
      T.eq(command .. " has only its JSON string", next(params, next(params)), nil)
      T.eq(command .. " sends it as a string", type(params.data), "string")
      return JSON:decode(params.data)
    end
  end
  T.check(command .. " was pushed", false)
  return {}
end

T.section("Network Requests")
do
  load("network_requests")
  urlDo = function(_, _, _, _, callback)
    callback(nil, 200, {}, "007", nil)
  end
  UIR._SAVE_REQUEST(data({ name = "123", type = "http", method = "GET", url = "http://198.51.100.7/" }))
  UIR._RUN_REQUEST(data({ name = "123" }))
  local result = pushed("REQUEST_RESULT")
  T.eq("a response like a number keeps its text", result.response, "007")
  T.eq("a name like a number keeps its text", result.name, "123")

  UIR._SAVE_WEBHOOK(data({ name = "456" }))
  OnServerDataIn(1, "POST /456 HTTP/1.1\r\nContent-Length: 5\r\n\r\n12.50", "198.51.100.9")
  local webhook = pushed("WEBHOOK_RESULT")
  T.eq("a payload like a number keeps its text", webhook.payload, "12.50")
  T.eq("a webhook's name keeps its text", webhook.name, "456")
end

T.section("Variable Expressions")
do
  load("variable_expressions")
  UIR._SAVE_EXPRESSION(data({ name = "007", mode = "string", template = "72.50" }))
  local result = pushed("EXPRESSION_RESULT")
  T.eq("a result like a number keeps its text", result.result, "72.50")
  T.eq("a name like a number keeps its text", result.name, "007")
  T.eq("what it renders keeps its text", result.rendered, "72.50")

  UIR._EVAL_EXPRESSION(data({ id = "1", mode = "string", template = "false" }))
  local preview = pushed("EVAL_RESULT")
  T.eq("a preview's result keeps its text", preview.result, "false")
  T.eq("and what it renders", preview.rendered, "false")
  T.eq("and what it substitutes", preview.substituted, "false")
end

T.section("Each page reads them that way")
do
  local requests = readFile("drivers/network_requests/www/html/index.html")
  T.check("REQUEST_RESULT", requests:find("onRequestResult(JSON.parse(params.data))", 1, true) ~= nil)
  T.check("WEBHOOK_RESULT", requests:find("onWebhookResult(JSON.parse(params.data))", 1, true) ~= nil)
  local expressions = readFile("drivers/variable_expressions/www/html/index.html")
  T.check("EXPRESSION_RESULT", expressions:find("onExpressionResult(JSON.parse(params.data))", 1, true) ~= nil)
  T.check("EVAL_RESULT", expressions:find("onEvalResult(JSON.parse(params.data))", 1, true) ~= nil)
end

T.finish()
