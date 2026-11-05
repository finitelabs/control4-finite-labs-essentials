-- A web tab's commands: the page breaks its base64 with newlines, since the broker's cost grows with the square of an
-- unbroken run, and each driver takes them.
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

T.section("Each page breaks its base64, and each driver reads only through its helper")
for _, driver in ipairs({ "network_requests", "variable_expressions" }) do
  local page = readFile("drivers/" .. driver .. "/www/html/index.html")
  local wraps = "btoa(JSON.stringify(params || {})).replace(/(.{76})/g, '$1\\n')"
  T.check(driver .. "'s page wraps every 76 characters", page:find(wraps, 1, true) ~= nil)
  local source = readFile("drivers/" .. driver .. "/driver.lua")
  T.check(driver .. "'s driver reads through its helper", not source:find("C4:Base64Decode(tParams.DATA", 1, true))
end

T.section("What the page sends has no long unbroken run")
do
  local longest = 0
  for run in asPageSends({ body = LONG }).DATA:gmatch("[^\n]+") do
    longest = math.max(longest, #run)
  end
  T.eq("its longest run is 76 characters", longest, 76)
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

T.finish()
