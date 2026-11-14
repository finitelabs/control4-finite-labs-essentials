-- Network Requests' TCP sends settle within the request's timeout, whether or not the host answers.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_network_requests_tcp.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")

local function data(t)
  return { DATA = C4:Base64Encode(JSON:encode(t)) }
end

local pushes = {}
function C4:SendDataToUI(command, params)
  pushes[#pushes + 1] = { command = command, params = params }
end

--- @class FakeTcpHost
--- @field connects boolean The host accepts the connection.
--- @field reply? string What it answers once a payload arrives.
--- @field clients table[] Every client the driver made.

--- Replaces C4:CreateTCPClient with clients that reach `host`.
--- @param host FakeTcpHost
local function useHost(host)
  host.clients = {}
  function C4:CreateTCPClient()
    local client = { written = {} }
    host.clients[#host.clients + 1] = client
    function client:OnConnect(fn)
      self.onConnect = fn
      return self
    end
    function client:OnRead(fn)
      self.onRead = fn
      return self
    end
    function client:OnDisconnect(fn)
      self.onDisconnect = fn
      return self
    end
    function client:OnError(fn)
      self.onError = fn
      return self
    end
    function client:Write(payload)
      self.written[#self.written + 1] = payload
      if host.reply and self.onRead then
        self.onRead(self, host.reply)
      end
    end
    function client:ReadUpTo() end
    function client:Close()
      self.closed = true
    end
    function client:Connect()
      if host.connects then
        self.onConnect(self)
      end
      return self
    end
    return client
  end
end

--- The request's entry in the tab's config, as the page reads it.
--- @param name string
--- @return table entry
local function result(name)
  pushes = {}
  UIRequest("_GET_CONFIG", {})
  for i = #pushes, 1, -1 do
    if pushes[i].command == "CONFIG_DATA" then
      for _, entry in ipairs(JSON:decode(pushes[i].params.json).requests) do
        if entry.name == name then
          return entry
        end
      end
    end
  end
  return {}
end

--- Loads the driver with one TCP request saved, and sends it.
--- @param host FakeTcpHost
--- @param request table Fields beyond the name, type, host, port and payload.
local function send(host, request)
  H.load("network_requests", H.LICENSED)
  useHost(host)
  local saved = {
    name = "Projector",
    originalName = "Projector",
    type = "tcp",
    host = "198.51.100.30",
    port = 4352,
    payload = "%1POWR 1\\r",
  }
  for k, v in pairs(request) do
    saved[k] = v
  end
  UIRequest("_SAVE_REQUEST", data(saved))
  ExecuteCommand("Send Request", { Request = "Projector" })
end

T.section("A host that never answers the connect fails the send at its timeout")
local silent = { connects = false }
send(silent, { waitResponse = false, timeout = 5 })
T.eq("the send is still open before the timeout", result("Projector").status, nil)
ShimFireTimers()
T.eq("then it fails", result("Projector").status, "error")
T.eq("and says why", result("Projector").detail, "no connection to 198.51.100.30:4352 within 5s")
T.check("the connection is closed", silent.clients[1].closed, "left open")

send(silent, { waitResponse = true, timeout = 12 })
ShimFireTimers()
T.eq(
  "a send waiting for a response fails at its own timeout",
  result("Projector").detail,
  "no connection to 198.51.100.30:4352 within 12s"
)

send(silent, { waitResponse = false, timeout = 5 })
ExecuteCommand("Send Request", { Request = "Projector" })
ShimFireTimers()
T.check(
  "a request sent again before the first send settles settles both",
  silent.clients[1].closed and silent.clients[2].closed,
  "a send was left open"
)

T.section("A host that connects")
local quiet = { connects = true }
send(quiet, { waitResponse = false, timeout = 5 })
T.eq("a send that doesn't wait succeeds at once", result("Projector").status, "ok")
ShimFireTimers()
T.eq("and the connect's timeout doesn't fail it after", result("Projector").status, "ok")

send(quiet, { waitResponse = true, timeout = 5 })
ShimFireTimers()
T.eq(
  "a send that waits and hears nothing fails on the response",
  result("Projector").detail,
  "no response from 198.51.100.30:4352 within 5s"
)

local answers = { connects = true, reply = "%1POWR=OK\r" }
send(answers, { waitResponse = true, timeout = 5 })
ShimFireTimers()
T.eq("a send that waits and hears back succeeds", result("Projector").status, "ok")
T.eq("with the response", result("Projector").response, "%1POWR=OK\r")

T.finish()
