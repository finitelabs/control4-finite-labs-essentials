-- Network Requests' DriverCentral license gate, with the real cloud client (license_harness.lua).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_network_requests.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

local function data(t)
  return { DATA = C4:Base64Encode(JSON:encode(t)) }
end

local responses = {}
function C4:ServerSend(_, response)
  responses[#responses + 1] = response:match("^HTTP/1%.1 (%d+)")
end
function C4:ServerCloseClient() end

local handle = 0
local function webhook()
  handle = handle + 1
  OnServerDataIn(handle, "POST /Doorbell HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi", "198.51.100.9")
end

H.standardChecks(
  "network_requests",
  {},
  {
    {
      "Send Request",
      function()
        ExecuteCommand("Send Request", { Request = "Ping" })
      end,
    },
    {
      "the web tab's Run",
      function()
        UIRequest("_RUN_REQUEST", data({ name = "Ping" }))
      end,
    },
    { "a webhook", webhook },
  },
  "Ready",
  nil,
  function()
    UIRequest("_SAVE_REQUEST", data({ name = "Ping", type = "http", method = "GET", url = "http://198.51.100.7/ping" }))
    UIRequest("_SAVE_WEBHOOK", data({ name = "Doorbell" }))
  end
)

T.section("network_requests: a webhook to a stopped driver is answered 503")
H.load("network_requests", H.INVALID)
H.reads(30)
webhook()
T.eq("the caller hears why", responses[#responses], "503")

T.finish()
