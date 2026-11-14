-- Network Requests answers a webhook call with the webhook's response body, built from variables as the call arrives.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_network_requests_webhook_response.lua

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

--- @class Answer
--- @field code string The status code.
--- @field type string The Content-Type header.
--- @field length number The Content-Length header.
--- @field body string

--- @type Answer[]
local answers = {}
local closed = 0
function C4:ServerSend(_, response)
  local head, body = response:match("^(.-)\r\n\r\n(.*)$")
  answers[#answers + 1] = {
    code = head:match("^HTTP/1%.1 (%d+)"),
    type = head:match("Content%-Type: ([^\r]*)"),
    length = tonumber(head:match("Content%-Length: (%d+)")),
    body = body,
  }
end
function C4:ServerCloseClient()
  closed = closed + 1
end

--- Every C4:GetVariable read, as "device:variable".
local reads = {}
local shimGetVariable = C4.GetVariable
function C4:GetVariable(deviceId, variableId)
  reads[#reads + 1] = tostring(deviceId) .. ":" .. tostring(variableId)
  return shimGetVariable(self, deviceId, variableId)
end

local handle = 0
--- Calls a webhook as an external system would.
--- @param target string The path and query, after the leading slash.
--- @param body? string A body makes it a POST.
--- @return Answer answer
local function call(target, body)
  handle = handle + 1
  reads = {}
  local request = body and string.format("POST /%s HTTP/1.1\r\nContent-Length: %d\r\n\r\n%s", target, #body, body)
    or string.format("GET /%s HTTP/1.1\r\n\r\n", target)
  OnServerDataIn(handle, request, "198.51.100.9")
  return answers[#answers]
end

--- The tab's config, as the page reads it.
--- @return table config
local function config()
  pushes = {}
  UIRequest("_GET_CONFIG", {})
  for i = #pushes, 1, -1 do
    if pushes[i].command == "CONFIG_DATA" then
      return JSON:decode(pushes[i].params.json)
    end
  end
  return {}
end

--- A webhook's entry in the tab's config.
--- @param name string
--- @return table entry
local function hook(name)
  for _, entry in ipairs(config().webhooks or {}) do
    if entry.name == name then
      return entry
    end
  end
  return {}
end

--- The last SAVE_RESULT pushed since `fn` ran, or nil when the save was accepted.
--- @param fn function
--- @return table|nil refusal
local function refusal(fn)
  pushes = {}
  fn()
  for i = #pushes, 1, -1 do
    if pushes[i].command == "SAVE_RESULT" then
      return JSON:decode(pushes[i].params.json)
    end
  end
  return nil
end

--- Saves a webhook as the page's editor does.
--- @param fields table
local function save(fields)
  UIRequest("_SAVE_WEBHOOK", data(fields))
end

--- The device a test's tokens name, with one variable.
--- @param value? string Nil leaves the device with no variable.
local function sensor(value)
  ShimSetDevices({
    [4242] = { variables = value and { ["7"] = { name = "TEMPERATURE", value = value } } or {} },
  })
end

H.load("network_requests", H.LICENSED)

--- Names of the events the driver has fired, in order.
local fired = {}
local fireEventByID = C4.FireEventByID
function C4:FireEventByID(idEvent)
  fired[#fired + 1] = (ShimEvents()[idEvent] or {}).name
  return fireEventByID(self, idEvent)
end

--- An answer's JSON body as a table.
--- @param answer Answer
--- @return table
local function json(answer)
  return JSON:decode(answer.body)
end
sensor("71.5")

T.section("A webhook with no response answers as it always has")
save({ name = "Plain" })
local plain = call("Plain", "hi")
T.eq("with a 200", plain.code, "200")
T.eq("as JSON", plain.type, "application/json")
T.eq("saying ok", plain.body, '{"ok":true}')
T.eq("and reads no variable", #reads, 0)
T.eq("the config shows it has no response", hook("Plain").response, "")
T.eq("and an automatic content type", hook("Plain").contentType, "auto")

T.section("A response is sent with each token's value as the call arrives")
save({ name = "Temp", response = '{"temperature": PARAM{4242,7}}' })
local first = call("Temp")
T.eq("the caller gets a 200", first.code, "200")
T.eq("the value in the body", first.body, '{"temperature": 71.5}')
T.eq("the body's own length", first.length, #first.body)
T.check("and the connection is closed", closed == handle, "left open")
sensor("68")
T.eq("the next call reads the variable again", call("Temp").body, '{"temperature": 68}')
T.eq("a variable can be named", (save({ name = "Named", response = "PARAM{4242,TEMPERATURE}" })), nil)
T.eq("and is read by that name", call("Named").body, "68")
T.eq("the config returns the response as typed", hook("Temp").response, '{"temperature": PARAM{4242,7}}')

T.section("The content type follows the rendered body unless the webhook sets one")
T.eq("a JSON object is JSON", call("Temp").type, "application/json")
save({ name = "List", response = "[PARAM{4242,7}]" })
T.eq("a JSON array is JSON", call("List").type, "application/json")
T.eq("a bare value is text", call("Named").type, "text/plain; charset=utf-8")
save({ name = "Broken", response = '{"temperature": PARAM{4242,7}' })
T.eq("a body that only starts like JSON is text", call("Broken").type, "text/plain; charset=utf-8")
save({ name = "Named", originalName = "Named", response = "PARAM{4242,TEMPERATURE}", contentType = "json" })
T.eq("JSON can be set for a bare value", call("Named").type, "application/json")
T.eq("the config keeps the choice", hook("Named").contentType, "json")
save({ name = "Temp", originalName = "Temp", response = '{"temperature": PARAM{4242,7}}', contentType = "text" })
T.eq("and text for a JSON body", call("Temp").type, "text/plain; charset=utf-8")
save({ name = "Temp", originalName = "Temp", response = '{"temperature": PARAM{4242,7}}', contentType = "xml" })
T.eq("an unknown choice is automatic", hook("Temp").contentType, "auto")

T.section("A refused call reads no variable")
save({ name = "Keyed", key = "s3", response = "PARAM{4242,7}" })
local noKey = call("Keyed")
T.eq("a call without the key is a 403", noKey.code, "403")
T.eq("saying why", json(noKey).error, "missing or bad key")
T.eq("and nothing is read", #reads, 0)
T.eq("a wrong key is a 403", call("Keyed?key=nope").code, "403")
T.eq("and nothing is read", #reads, 0)
local keyed = call("Keyed?key=s3")
T.eq("the right key gets the response", keyed.body, "68")
T.eq("an unknown webhook is a 404", call("Nobody").code, "404")
T.eq("and nothing is read", #reads, 0)

T.section("A variable that cannot be found is a 500, not a placeholder")
sensor(nil)
fired = {}
local missing = call("Temp", "ping")
T.eq("the caller gets a 500", missing.code, "500")
T.eq("as JSON", missing.type, "application/json")
T.eq("saying why", json(missing).error, "unresolved variable reference")
T.eq("and that it failed", json(missing).ok, false)
T.eq("the call's payload is still published", Variables["Temp Payload"], "ping")
T.eq("its event still fires", table.concat(fired, ","), "Temp Received")
T.eq("and the tab shows the error", hook("Temp").error, "unresolved variable reference")
sensor("70")
T.eq("the next good call answers", call("Temp").code, "200")
T.eq("and clears the error", hook("Temp").error, nil)

T.section("A response can return the payload of the call it answers")
save({ name = "Echo", response = string.format("got PARAM{%d,Echo Payload}", C4:GetDeviceID()) })
T.eq("a first call returns its own payload", call("Echo", "one").body, "got one")
T.eq("and a second its own", call("Echo", "two").body, "got two")
T.eq("a call without a body returns its query string", call("Echo?zone=porch").body, "got zone=porch")

T.section("A rendered response over 16 KB is a 500")
sensor(string.rep("x", 9000))
save({ name = "Big", response = "PARAM{4242,7}PARAM{4242,7}" })
local big = call("Big")
T.eq("the caller gets a 500", big.code, "500")
T.eq("saying why", json(big).error, "response too large")
save({ name = "Fits", response = "PARAM{4242,7}" })
T.eq("9 KB is sent whole", #call("Fits").body, 9000)
sensor("70")

T.section("Saving a webhook")
T.eq(
  "a response over 16 KB is refused",
  refusal(function()
    save({ name = "Long", response = string.rep("x", 16385) })
  end).error,
  "Response is longer than 16 KB"
)
T.eq("and not saved", hook("Long").name, nil)
T.eq(
  "a new webhook cannot take a name in use",
  refusal(function()
    save({ name = "Temp", response = "other" })
  end).error,
  "A webhook named 'Temp' already exists"
)
T.eq("the one in use keeps its response", hook("Temp").response, '{"temperature": PARAM{4242,7}}')
T.eq(
  "a webhook cannot be renamed",
  refusal(function()
    save({ name = "Temperature", originalName = "Temp", response = "other" })
  end).error,
  "Webhooks cannot be renamed. Create a new webhook and delete this one."
)
T.eq("a webhook saved before responses existed answers ok", call("Plain").body, '{"ok":true}')

T.section("A response survives a driver reload")
H.load("network_requests", H.LICENSED)
T.eq("the webhook answers with it", call("Temp").body, '{"temperature": 70}')

ShimResetDevices()
T.finish()
