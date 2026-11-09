-- A web tab's commands: the page breaks its base64 with newlines, and each driver takes them.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_page_commands.lua

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

--- A command's parameters as the page's sendCommand sends them.
local function asPageSends(t)
  local wrapped = C4:Base64Encode(JSON:encode(t)):gsub(string.rep(".", 76), "%0\n")
  return { DATA = wrapped }
end

local LONG = string.rep("A long request body. ", 500)

--- Text from every length of UTF-8, with what XML reads as markup.
local TEXT = "caf\195\169 \230\151\165\230\156\172 \240\159\146\161 <a&b>"

local function hasNode()
  local pipe = io.popen("command -v node 2>/dev/null")
  local found = pipe:read("*a") ~= ""
  pipe:close()
  return found
end

--- A command's parameters as the pages' sendCommand encodes them (lib/ui/page.js's encodeParams), run under node.
--- @param driver string
--- @param params table
--- @return table tParams
local function fromPage(driver, params)
  assert(readFile("drivers/" .. driver .. "/www/html/index.html"):find("src/lib/ui/page.js", 1, true), "no kit")
  local kit = readFile("src/lib/ui/page.js")
  local expression = assert(kit:match("function encodeParams%(params%) {\n  return (.-);\n}"), "no encodeParams")
  local path = os.tmpname()
  local file = assert(io.open(path, "w"))
  file:write("const params = ", JSON:encode(params), ";\nprocess.stdout.write(", expression, ");\n")
  file:close()
  local pipe = io.popen(string.format("node '%s' 2>/dev/null", path))
  local data = pipe:read("*a")
  pipe:close()
  os.remove(path)
  return { DATA = data }
end

T.section("Each page breaks its base64, and each driver reads only through its helper")
for _, driver in ipairs({ "network_requests", "variable_expressions" }) do
  local page = readFile("drivers/" .. driver .. "/www/html/index.html")
  local kit = readFile("src/lib/ui/page.js")
  local wraps = 'btoa(unescape(encodeURIComponent(JSON.stringify(params || {})))).replace(/.{76}/g, "$&\\n")'
  T.check(
    driver .. "'s page sends through lib/ui",
    page:find("<!-- #embed ../../../../src/lib/ui/page.js -->", 1, true) ~= nil
  )
  T.check("which wraps every 76 characters", kit:find(wraps, 1, true) ~= nil)
  local source = readFile("drivers/" .. driver .. "/driver.lua")
  T.check(driver .. "'s driver reads through its helper", not source:find("C4:Base64Decode(tParams.DATA", 1, true))
end

T.section("Network Requests saves a long body sent that way")
do
  H.load("network_requests", H.LICENSED)
  local config = JSON:decode(UIR._SAVE_REQUEST(asPageSends({
    name = "Long",
    type = "http",
    method = "POST",
    url = "http://198.51.100.20/",
    body = LONG,
  })))
  local requests = JSON:decode(config.requests)
  T.eq("it is saved", #requests, 1)
  T.eq("whole", requests[1].body, LONG)
end

T.section("Variable Expressions saves a long expression sent that way")
do
  H.load("variable_expressions", H.LICENSED)
  local config = JSON:decode(UIR._SAVE_EXPRESSION(asPageSends({ name = "Long", mode = "string", template = LONG })))
  local expressions = JSON:decode(config.expressions)
  T.eq("it is saved", #expressions, 1)
  T.eq("whole", expressions[1].template, LONG)
end

--- The entry of that name in a config's list.
local function named(list, name)
  for _, entry in ipairs(list) do
    if entry.name == name then
      return entry
    end
  end
  return {}
end

T.section("Text outside Latin-1, sent through the pages' encodeParams in lib/ui/page.js")
if hasNode() then
  H.load("network_requests", H.LICENSED)
  local request = fromPage("network_requests", {
    name = "Text",
    type = "http",
    method = "POST",
    url = "http://198.51.100.20/",
    body = TEXT,
  })
  T.check("the page encodes it", request.DATA ~= "")
  if request.DATA ~= "" then
    local config = JSON:decode(UIR._SAVE_REQUEST(request))
    T.eq("Network Requests stores it exactly", named(JSON:decode(config.requests), "Text").body, TEXT)
  end

  H.load("variable_expressions", H.LICENSED)
  local expression = fromPage("variable_expressions", { name = "Text", mode = "string", template = TEXT })
  T.check("the page encodes it", expression.DATA ~= "")
  if expression.DATA ~= "" then
    local config = JSON:decode(UIR._SAVE_EXPRESSION(expression))
    T.eq("Variable Expressions stores it exactly", named(JSON:decode(config.expressions), "Text").template, TEXT)
  end
else
  print("SKIP: node not installed; the pages' own line was not run")
end

T.finish()
