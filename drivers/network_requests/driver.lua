--- Network Requests Driver
--#ifdef DRIVERCENTRAL
DC_PID = nil
DC_X = nil
DC_FILENAME = "network_requests.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-finite-labs-essentials"
DRIVER_FILENAMES = { "network_requests.c4z" }
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

JSON = require("JSON")

local deferred = require("deferred")
local log = require("lib.logging")
local persist = require("lib.persist")
local values = require("lib.values")
local events = require("lib.events")
local http = require("lib.http")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Namespace for dynamic per-request events.
local NS_REQUEST = "Request"

--- Namespace for dynamic per-webhook events.
local NS_WEBHOOK = "Webhook"

--- Suffix appended to a request name to form its response variable.
local RESPONSE_SUFFIX = " Response"

--- Suffix appended to a webhook name to form its payload variable.
local PAYLOAD_SUFFIX = " Payload"

--- Persist keys for named requests and their last results.
local PERSIST_REQUESTS = "Requests"
local PERSIST_RESULTS = "RequestResults"

--- Persist keys for named webhooks and their last results.
local PERSIST_WEBHOOKS = "Webhooks"
local PERSIST_WEBHOOK_RESULTS = "WebhookResults"

--- Placeholder emitted when a PARAM{} token references a missing variable.
local ERROR_VARIABLE_NOT_FOUND = "ERROR_VARIABLE_NOT_FOUND"

--- Default and maximum response wait for TCP requests, seconds.
local DEFAULT_TCP_TIMEOUT = 5
local MAX_TCP_TIMEOUT = 60

--- Cap stored responses so a chatty endpoint cannot bloat persist or the UI.
local MAX_RESPONSE_BYTES = 8192

--- Dynamic network binding range used for UDP sends. Each send rotates through
--- the range so overlapping sends do not clobber one another's binding.
local UDP_BINDING_FIRST = 6101
local UDP_BINDING_COUNT = 50

--------------------------------------------------------------------------------
-- Token Substitution
--------------------------------------------------------------------------------

--- Lua pattern matching a PARAM{device,variable} token, capturing the two ids
--- with surrounding whitespace trimmed.
local PARAM_PATTERN = "PARAM%s*{%s*(.-)%s*,%s*(.-)%s*}"

--- Resolve a variable reference on a device to its numeric id and name.
--- C4:GetVariable requires a numeric variable id, so a name is looked up against
--- the device's variables. A numeric reference is mapped back to its name for
--- display purposes.
--- @param deviceId integer The numeric device id.
--- @param variable string The variable id or name.
--- @return integer|nil variableId The numeric id, or nil if it cannot be resolved.
--- @return string name The variable name, falling back to the raw reference.
local function resolveVariable(deviceId, variable)
  local ok, vars = pcall(function()
    return C4:GetDeviceVariables(deviceId)
  end)
  vars = (ok and type(vars) == "table") and vars or {}
  local asId = tonumber(variable)
  if asId then
    for id, v in pairs(vars) do
      if tonumber(id) == asId and type(v) == "table" then
        return asId, v.name or variable
      end
    end
    return asId, variable
  end
  for id, v in pairs(vars) do
    if type(v) == "table" and v.name == variable then
      return tonumber(id), variable
    end
  end
  return nil, variable
end

--- Read a Control4 variable referenced by a PARAM{} token. The device must be a
--- numeric id; the variable may be a numeric id or a name. Wrapped in pcall so a
--- malformed reference yields nil rather than aborting the whole send.
--- @param device string The device id.
--- @param variable string The variable id or name.
--- @return any|nil value
local function readVariable(device, variable)
  local deviceId = tonumber(device)
  if not deviceId then
    return nil
  end
  local variableId = resolveVariable(deviceId, variable)
  if not variableId then
    return nil
  end
  local ok, value = pcall(function()
    return C4:GetVariable(deviceId, variableId)
  end)
  if not ok then
    return nil
  end
  return value
end

--- Replace every `PARAM{device,variable}` token with the referenced variable's
--- current value. Whitespace around the ids is tolerated. Missing references are
--- replaced with ERROR_VARIABLE_NOT_FOUND and flagged.
--- @param template string The template string.
--- @return string result The substituted string.
--- @return boolean missing True if any referenced variable was not found.
local function substituteTokens(template)
  local missing = false
  local result = template:gsub(PARAM_PATTERN, function(device, variable)
    local value = readVariable(device, variable)
    if value == nil then
      log:warn("Variable not found: device='%s' variable='%s'", device, variable)
      missing = true
      return ERROR_VARIABLE_NOT_FOUND
    end
    return tostring(value)
  end)
  return result, missing
end

--------------------------------------------------------------------------------
-- Payload Encoding
--------------------------------------------------------------------------------

--- Decode backslash escapes in a text payload: \r \n \t \0 \\ and \xNN. Escapes
--- are decoded before PARAM{} substitution so escape-like sequences inside
--- variable values pass through untouched.
--- @param s string
--- @return string decoded
local function decodeEscapes(s)
  local out = {}
  local i = 1
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" and i < n then
      local nextChar = s:sub(i + 1, i + 1)
      if nextChar == "x" and i + 3 <= n and s:sub(i + 2, i + 3):match("^%x%x$") then
        out[#out + 1] = string.char(tonumber(s:sub(i + 2, i + 3), 16))
        i = i + 4
      elseif nextChar == "r" then
        out[#out + 1] = "\r"
        i = i + 2
      elseif nextChar == "n" then
        out[#out + 1] = "\n"
        i = i + 2
      elseif nextChar == "t" then
        out[#out + 1] = "\t"
        i = i + 2
      elseif nextChar == "0" then
        out[#out + 1] = "\0"
        i = i + 2
      elseif nextChar == "\\" then
        out[#out + 1] = "\\"
        i = i + 2
      else
        out[#out + 1] = c
        i = i + 1
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Convert a hex payload ("00 11 22", "0x00,0x11" or "001122") to binary.
--- @param s string
--- @return string|nil binary
--- @return string? err
local function decodeHex(s)
  local cleaned = tostring(s or ""):gsub("0[xX]", ""):gsub("[%s:,]", "")
  if IsEmpty(cleaned) then
    return nil, "hex payload is empty"
  end
  if #cleaned % 2 ~= 0 then
    return nil, "hex payload has an odd number of digits"
  end
  if cleaned:match("%X") then
    return nil, "hex payload contains non-hex characters"
  end
  local out = {}
  for byte in cleaned:gmatch("%x%x") do
    out[#out + 1] = string.char(tonumber(byte, 16))
  end
  return table.concat(out)
end

--- Build the wire payload for a tcp/udp request config: escape decoding and
--- PARAM substitution for text payloads, hex decoding for hex payloads.
--- @param config table
--- @return string|nil payload
--- @return string? err
local function buildPayload(config)
  if config.encoding == "hex" then
    return decodeHex(config.payload)
  end
  local substituted, missing = substituteTokens(decodeEscapes(tostring(config.payload or "")))
  if missing then
    return nil, "unresolved variable reference"
  end
  return substituted
end

--- Truncate a response for storage and UI display.
--- @param s string
--- @return string
local function clampResponse(s)
  s = tostring(s or "")
  if #s > MAX_RESPONSE_BYTES then
    return s:sub(1, MAX_RESPONSE_BYTES)
  end
  return s
end

--------------------------------------------------------------------------------
-- Named Requests
--------------------------------------------------------------------------------

--- Get the configured requests.
--- @return table<string, table> requests Map of name -> config.
local function getRequests()
  return persist:get(PERSIST_REQUESTS, {}) or {}
end

--- Save the configured requests.
--- @param requests table<string, table>
local function saveRequests(requests)
  persist:set(PERSIST_REQUESTS, not IsEmpty(requests) and requests or nil)
end

--- Get the last results per request.
--- @return table<string, table> results Map of name -> { status, detail, code?, response?, ts }.
local function getResults()
  return persist:get(PERSIST_RESULTS, {}) or {}
end

--- Save a single request result entry and push it to the tab UI.
--- @param name string
--- @param entry table
local function setResult(name, entry)
  local results = getResults()
  results[name] = entry
  persist:set(PERSIST_RESULTS, results)
  C4:SendDataToUI("REQUEST_RESULT", {
    name = name,
    status = entry.status or "",
    detail = entry.detail or "",
    code = entry.code ~= nil and tostring(entry.code) or "",
    response = entry.response or "",
    ts = entry.ts or os.time(),
  })
end

--- Response variable name for a request.
--- @param name string
--- @return string
local function responseVariableName(name)
  return name .. RESPONSE_SUFFIX
end

--- Whether a request config captures a response.
--- @param config table
--- @return boolean
local function capturesResponse(config)
  return config.type == "http" or (config.type == "tcp" and toboolean(config.waitResponse))
end

--- Event key for a request's sent event. Request names are immutable, so
--- name-based keys are stable for the life of the request.
--- @param name string
--- @return string
local function sentEventKey(name)
  return name .. " Sent"
end

--- Event key for a request's failed event.
--- @param name string
--- @return string
local function failedEventKey(name)
  return name .. " Failed"
end

--- Ensure the dynamic events for a request exist.
--- @param name string
local function ensureRequestEvents(name)
  events:getOrAddEvent(
    NS_REQUEST,
    sentEventKey(name),
    sentEventKey(name),
    string.format("Fires after request '%s' is sent successfully.", name)
  )
  events:getOrAddEvent(
    NS_REQUEST,
    failedEventKey(name),
    failedEventKey(name),
    string.format("Fires when request '%s' fails to send.", name)
  )
end

--- Remove a request's events, variable, and stored result.
--- @param name string
local function removeRequestOutputs(name)
  events:deleteEvent(NS_REQUEST, sentEventKey(name))
  events:deleteEvent(NS_REQUEST, failedEventKey(name))
  values:delete(responseVariableName(name))
  local results = getResults()
  results[name] = nil
  persist:set(PERSIST_RESULTS, results)
end

--------------------------------------------------------------------------------
-- Senders
--------------------------------------------------------------------------------

--- Send an HTTP request.
--- @param config table
--- @return Deferred d Resolves { detail, code, response } or rejects an error string.
local function sendHttp(config)
  local d = deferred.new()
  local url, urlMissing = substituteTokens(tostring(config.url or ""))
  if urlMissing then
    return d:reject("unresolved variable reference in URL")
  end
  local body, bodyMissing = substituteTokens(tostring(config.body or ""))
  if bodyMissing then
    return d:reject("unresolved variable reference in body")
  end
  local headers = {}
  for _, header in ipairs(config.headers or {}) do
    local headerName = tostring(header.name or "")
    if not IsEmpty(headerName) then
      local value, headerMissing = substituteTokens(tostring(header.value or ""))
      if headerMissing then
        return d:reject("unresolved variable reference in header '" .. headerName .. "'")
      end
      headers[headerName] = value
    end
  end
  local method = tostring(config.method or "GET"):upper()
  -- LAN devices commonly present self-signed certificates, so TLS validation
  -- is opt-in per request.
  local options = {
    ssl_verify_host = toboolean(config.tlsVerify),
    ssl_verify_peer = toboolean(config.tlsVerify),
  }
  http:request(method, url, not IsEmpty(body) and body or nil, headers, options):next(function(response)
    d:resolve({
      detail = string.format("HTTP %s %s", tostring(response.code), method),
      code = response.code,
      response = clampResponse(
        type(response.body) == "table" and JSON:encode(response.body) or tostring(response.body or "")
      ),
    })
  end, function(err)
    local code = Select(err, "code")
    if tointeger(code) and tointeger(code) > 0 then
      -- The endpoint answered with an error status; capture it like a response.
      local body = Select(err, "body")
      d:resolve({
        detail = string.format("HTTP %s %s", tostring(code), method),
        code = code,
        response = clampResponse(type(body) == "table" and JSON:encode(body) or tostring(body or "")),
      })
    else
      d:reject(tostring(Select(err, "error") or "request failed"))
    end
  end)
  return d
end

--- Send a raw TCP payload, optionally waiting for the first response data.
--- @param config table
--- @return Deferred d Resolves { detail, response? } or rejects an error string.
local function sendTcp(config)
  local d = deferred.new()
  local payload, err = buildPayload(config)
  if not payload then
    return d:reject(err)
  end
  local host = tostring(config.host or "")
  local port = tointeger(config.port) or 0
  if IsEmpty(host) or port < 1 or port > 65535 then
    return d:reject("invalid host or port")
  end

  local wait = toboolean(config.waitResponse)
  local timeoutSeconds = InRange(tointeger(config.timeout) or DEFAULT_TCP_TIMEOUT, 1, MAX_TCP_TIMEOUT)
  local timerName = "TcpTimeout::" .. tostring(config.name)
  local sentDetail = nil
  local buffer = ""
  local settled = false

  local client
  local function settle(ok, result)
    if settled then
      return
    end
    settled = true
    CancelTimer(timerName)
    pcall(function()
      client:Close()
    end)
    if ok then
      d:resolve(result)
    else
      d:reject(result)
    end
  end

  client = C4:CreateTCPClient()
    :OnConnect(function(c)
      c:Write(payload)
      sentDetail = string.format("sent %d byte(s) to %s:%d", #payload, host, port)
      if not wait then
        return settle(true, { detail = sentDetail })
      end
      c:ReadUpTo(4096)
      SetTimer(timerName, timeoutSeconds * ONE_SECOND, function()
        if IsEmpty(buffer) then
          return settle(false, string.format("no response from %s:%d within %ds", host, port, timeoutSeconds))
        end
        settle(true, { detail = sentDetail, response = clampResponse(buffer) })
      end)
    end)
    :OnRead(function(c, data)
      buffer = buffer .. tostring(data or "")
      if #buffer >= MAX_RESPONSE_BYTES then
        return settle(true, { detail = sentDetail, response = clampResponse(buffer) })
      end
      -- Linger briefly after data arrives so multi-packet responses coalesce.
      SetTimer(timerName, 250, function()
        settle(true, { detail = sentDetail, response = clampResponse(buffer) })
      end)
      c:ReadUpTo(4096)
    end)
    :OnDisconnect(function()
      if wait and not IsEmpty(buffer) then
        return settle(true, { detail = sentDetail, response = clampResponse(buffer) })
      end
      settle(false, string.format("disconnected from %s:%d before a response", host, port))
    end)
    :OnError(function(_, errCode, errMsg)
      settle(false, string.format("%s (%s)", tostring(errMsg), tostring(errCode)))
    end)

  if client:Connect(host, port) == nil then
    settle(false, string.format("failed to connect to %s:%d", host, port))
  end
  return d
end

--- Rotating dynamic binding offset for UDP sends.
local udpBindingOffset = 0

--- Send a UDP datagram, fire and forget.
--- @param config table
--- @param overrides table? { host, port, payload } used by the WOL sender.
--- @return Deferred d Resolves { detail } or rejects an error string.
local function sendUdp(config, overrides)
  local d = deferred.new()
  local payload, err
  if overrides then
    payload = overrides.payload
  else
    payload, err = buildPayload(config)
  end
  if not payload then
    return d:reject(err)
  end
  local host = tostring(Select(overrides or {}, "host") or config.host or "")
  local port = tointeger(Select(overrides or {}, "port") or config.port) or 0
  if IsEmpty(host) or port < 1 or port > 65535 then
    return d:reject("invalid host or port")
  end

  local binding = UDP_BINDING_FIRST + udpBindingOffset
  udpBindingOffset = (udpBindingOffset + 1) % UDP_BINDING_COUNT

  local ok, sendErr = pcall(function()
    C4:CreateNetworkConnection(binding, host, "UDP")
    C4:NetPortOptions(binding, port, "UDP", {
      -- Use an ephemeral source port: mirroring the destination port can
      -- collide with other drivers listening on well-known ports.
      MIRROR_UDP_PORT = false,
    })
    C4:NetConnect(binding, port, "UDP")
    C4:SendToNetwork(binding, port, payload)
    SetTimer("UdpClose::" .. tostring(binding), 2 * ONE_SECOND, function()
      pcall(function()
        C4:NetDisconnect(binding, port)
        C4:DestroyNetworkConnection(binding)
      end)
    end)
  end)
  if not ok then
    return d:reject(tostring(sendErr))
  end
  return d:resolve({ detail = string.format("sent %d byte(s) to %s:%d", #payload, host, port) })
end

--- Send a Wake-on-LAN magic packet for a MAC address.
--- @param config table
--- @return Deferred d Resolves { detail } or rejects an error string.
local function sendWol(config)
  local d = deferred.new()
  local mac = tostring(config.mac or ""):gsub("[%s:%-%.]", "")
  if #mac ~= 12 or mac:match("%X") then
    return d:reject("invalid MAC address")
  end
  local macBinary = {}
  for byte in mac:gmatch("%x%x") do
    macBinary[#macBinary + 1] = string.char(tonumber(byte, 16))
  end
  local packet = string.rep(string.char(255), 6) .. string.rep(table.concat(macBinary), 16)
  sendUdp(config, { host = "255.255.255.255", port = 9, payload = packet }):next(function()
    d:resolve({ detail = string.format("sent magic packet for %s", tostring(config.mac)) })
  end, function(err)
    d:reject(err)
  end)
  return d
end

--- Send a named request: dispatch on type, publish outputs, fire events, and
--- push the result to the tab UI.
--- @param name string
--- @return Deferred|nil d Resolves the stored result entry, or nil if not configured.
local function sendRequest(name)
  log:trace("sendRequest('%s')", name)
  local config = getRequests()[name]
  if not config then
    log:warn("Send Request: unknown request '%s'", tostring(name))
    return nil
  end

  local sender
  if config.type == "http" then
    sender = sendHttp
  elseif config.type == "tcp" then
    sender = sendTcp
  elseif config.type == "udp" then
    sender = sendUdp
  elseif config.type == "wol" then
    sender = sendWol
  else
    sender = function()
      return deferred.new():reject("unknown request type '" .. tostring(config.type) .. "'")
    end
  end

  ensureRequestEvents(name)
  return sender(config):next(function(result)
    local entry = {
      status = "ok",
      detail = result.detail or "sent",
      code = result.code,
      response = result.response,
      ts = os.time(),
    }
    if capturesResponse(config) then
      values:update(responseVariableName(name), result.response or "", "STRING")
    end
    events:fire(NS_REQUEST, sentEventKey(name))
    log:info("Request '%s': %s", name, entry.detail)
    setResult(name, entry)
    return entry
  end, function(err)
    local entry = {
      status = "error",
      detail = tostring(err),
      ts = os.time(),
      -- Keep the last good response visible alongside the error state
      response = Select(getResults(), name, "response"),
    }
    events:fire(NS_REQUEST, failedEventKey(name))
    log:warn("Request '%s' failed: %s", name, entry.detail)
    setResult(name, entry)
    return entry
  end)
end

--------------------------------------------------------------------------------
-- Webhooks
--------------------------------------------------------------------------------

--- Get the configured webhooks.
--- @return table<string, table> webhooks Map of name -> { name, key }.
local function getWebhooks()
  return persist:get(PERSIST_WEBHOOKS, {}) or {}
end

--- Save the configured webhooks.
--- @param webhooks table<string, table>
local function saveWebhooks(webhooks)
  persist:set(PERSIST_WEBHOOKS, not IsEmpty(webhooks) and webhooks or nil)
end

--- Get the last received entry per webhook.
--- @return table<string, table> results Map of name -> { from, payload, ts }.
local function getWebhookResults()
  return persist:get(PERSIST_WEBHOOK_RESULTS, {}) or {}
end

--- Save a single webhook result entry and push it to the tab UI.
--- @param name string
--- @param entry table
local function setWebhookResult(name, entry)
  local results = getWebhookResults()
  results[name] = entry
  persist:set(PERSIST_WEBHOOK_RESULTS, results)
  C4:SendDataToUI("WEBHOOK_RESULT", {
    name = name,
    from = entry.from or "",
    payload = entry.payload or "",
    ts = entry.ts or os.time(),
  })
end

--- Payload variable name for a webhook.
--- @param name string
--- @return string
local function payloadVariableName(name)
  return name .. PAYLOAD_SUFFIX
end

--- Event key for a webhook's received event.
--- @param name string
--- @return string
local function receivedEventKey(name)
  return name .. " Received"
end

--- Ensure the dynamic event for a webhook exists.
--- @param name string
local function ensureWebhookEvents(name)
  events:getOrAddEvent(
    NS_WEBHOOK,
    receivedEventKey(name),
    receivedEventKey(name),
    string.format("Fires when webhook '%s' receives a call.", name)
  )
end

--- Remove a webhook's event, variable, and stored result.
--- @param name string
local function removeWebhookOutputs(name)
  events:deleteEvent(NS_WEBHOOK, receivedEventKey(name))
  values:delete(payloadVariableName(name))
  local results = getWebhookResults()
  results[name] = nil
  persist:set(PERSIST_WEBHOOK_RESULTS, results)
end

--- Decode %XX escapes and + in a URL component.
--- @param s string
--- @return string
local function urlDecode(s)
  return (
    tostring(s or ""):gsub("%+", " "):gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end)
  )
end

--- The base URL the webhook server is reachable at, or nil when disabled.
--- @return string|nil
local function webhookBaseUrl()
  local port = tointeger(Properties["Webhook Port"]) or 0
  if port < 1 then
    return nil
  end
  return string.format("http://%s:%d/", tostring(C4:GetControllerNetworkAddress()), port)
end

--- Per-connection receive buffers for the webhook server.
--- @type table<number, string>
local webhookBuffers = {}

--- Send an HTTP response on a server connection and close it.
--- @param nHandle number
--- @param code number
--- @param reason string
--- @param bodyTable table JSON-encodable response body.
local function webhookRespond(nHandle, code, reason, bodyTable)
  local body = JSON:encode(bodyTable)
  local response = string.format(
    "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
    code,
    reason,
    #body,
    body
  )
  pcall(function()
    C4:ServerSend(nHandle, response)
    C4:ServerCloseClient(nHandle)
  end)
end

--- Route a parsed webhook HTTP request: fire the matching webhook's event,
--- publish its payload variable, and answer the caller.
--- @param nHandle number
--- @param method string
--- @param rawPath string Path with optional query string, still URL-encoded.
--- @param body string
--- @param clientAddress string
local function handleWebhookRequest(nHandle, method, rawPath, body, clientAddress)
  local path, query = rawPath:match("^([^?]*)%??(.*)$")
  local name = urlDecode(tostring(path or ""):gsub("^/", ""):gsub("/$", ""))
  log:debug("Webhook call: %s '%s' from %s", method, name, clientAddress)

  local config = getWebhooks()[name]
  if not config then
    return webhookRespond(nHandle, 404, "Not Found", { ok = false, error = "unknown webhook" })
  end
  if not IsEmpty(config.key) then
    local key = tostring(query or ""):match("[?&]?key=([^&]*)")
    if urlDecode(key or "") ~= config.key then
      log:warn("Webhook '%s': rejected call with a missing or bad key from %s", name, clientAddress)
      return webhookRespond(nHandle, 403, "Forbidden", { ok = false, error = "missing or bad key" })
    end
  end

  local payload = not IsEmpty(body) and body or tostring(query or "")
  values:update(payloadVariableName(name), clampResponse(payload), "STRING")
  ensureWebhookEvents(name)
  events:fire(NS_WEBHOOK, receivedEventKey(name))
  log:info("Webhook '%s' received from %s (%d payload byte(s))", name, clientAddress, #payload)
  setWebhookResult(name, { from = clientAddress, payload = clampResponse(payload), ts = os.time() })
  return webhookRespond(nHandle, 200, "OK", { ok = true })
end

--- Start (or restart) the webhook HTTP server from the Webhook Port property.
local function startWebhookServer()
  webhookBuffers = {}
  pcall(function()
    C4:DestroyServer()
  end)
  local port = tointeger(Properties["Webhook Port"]) or 0
  if port < 1 then
    UpdateProperty("Webhook URL", "Disabled")
    return
  end
  C4:CreateServer(port, "", false)
  UpdateProperty("Webhook URL", webhookBaseUrl() .. "<Webhook Name>")
  log:info("Webhook server listening on port %d", port)
end

function OnServerStatusChanged(nPort, strStatus)
  log:debug("OnServerStatusChanged(%s, %s)", nPort, strStatus)
  if strStatus ~= "ONLINE" then
    UpdateProperty(
      "Webhook URL",
      string.format("Failed to listen on port %s (%s)", tostring(nPort), tostring(strStatus))
    )
  end
end

function OnServerConnectionStatusChanged(nHandle, nPort, strStatus)
  log:trace("OnServerConnectionStatusChanged(%s, %s, %s)", nHandle, nPort, strStatus)
  if strStatus ~= "ONLINE" then
    webhookBuffers[nHandle] = nil
  end
end

function OnServerDataIn(nHandle, strData, strClientAddress)
  log:trace("OnServerDataIn(%s, %d byte(s), %s)", nHandle, #tostring(strData or ""), tostring(strClientAddress))
  local buffer = (webhookBuffers[nHandle] or "") .. tostring(strData or "")
  webhookBuffers[nHandle] = buffer

  -- Wait for complete headers, then for the complete body per Content-Length.
  local headerEnd = buffer:find("\r\n\r\n", 1, true)
  if not headerEnd then
    if #buffer > MAX_RESPONSE_BYTES * 2 then
      webhookBuffers[nHandle] = nil
      webhookRespond(nHandle, 431, "Request Header Fields Too Large", { ok = false })
    end
    return
  end
  local head = buffer:sub(1, headerEnd - 1)
  local method, rawPath = head:match("^(%u+)%s+(%S+)")
  if not method then
    webhookBuffers[nHandle] = nil
    return webhookRespond(nHandle, 400, "Bad Request", { ok = false })
  end
  local contentLength = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
  local body = buffer:sub(headerEnd + 4)
  if #body < contentLength then
    return
  end

  webhookBuffers[nHandle] = nil
  handleWebhookRequest(nHandle, method, rawPath, body:sub(1, contentLength), tostring(strClientAddress))
end

--------------------------------------------------------------------------------
-- Multi-instance helpers
--------------------------------------------------------------------------------

--#ifndef DRIVERCENTRAL
--- Get all device IDs for instances of this driver, sorted ascending.
--- @return integer[]
local function getDriverIds()
  local drivers = C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}
  local ids = {}
  for id, _ in pairs(drivers) do
    table.insert(ids, tointeger(id))
  end
  table.sort(ids)
  return ids
end

--- Sync a property value to all other instances of this driver.
--- Only syncs if the other instance has a different value (avoids infinite loops).
--- @param propertyName string
--- @param propertyValue string
local function syncPropertyToOtherInstances(propertyName, propertyValue)
  local ids = getDriverIds()
  local myId = C4:GetDeviceID()
  for _, deviceId in ipairs(ids) do
    if deviceId ~= myId then
      log:info("Syncing property '%s' = '%s' to device %d", propertyName, propertyValue, deviceId)
      SetDeviceProperties(deviceId, { [propertyName] = propertyValue }, true)
    end
  end
end
--#endif

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  -- Restore per-request response variables here: programming attached to
  -- variables added after OnDriverInit may not work after a Director restart.
  values:restoreValues()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")

  C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")

  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Restore dynamic per-request events
  events:restoreEvents()

  -- Fire OnPropertyChanged for all properties to set initial global state
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  -- One-time cleanup of the retired id-based event keys and persist entries
  -- from pre-release builds; request events are keyed by name.
  for key in pairs(Select(events:getEvents(), NS_REQUEST) or {}) do
    if key:match("^request:%d+:") then
      events:deleteEvent(NS_REQUEST, key)
    end
  end
  persist:set("RequestAliases", nil)
  persist:set("NextRequestId", nil)

  -- Make sure every configured request and webhook has its events registered.
  for name in pairs(getRequests()) do
    ensureRequestEvents(name)
  end
  for name in pairs(getWebhooks()) do
    ensureWebhookEvents(name)
  end

  startWebhookServer()

  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    -- Recompute leader each cycle in case the previous leader was removed
    local isLeaderInstance = Select(getDriverIds(), 1) == C4:GetDeviceID()
    if isLeaderInstance and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      UpdateDrivers()
    end
  end, true)
  --#endif

  gInitialized = true
  UpdateProperty("Driver Status", "Ready")
end

--------------------------------------------------------------------------------
-- OPC Handlers
--------------------------------------------------------------------------------

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
    return
  end
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    UpdateProperty("Log Level", "3 - Info", true)
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
  OnPropertyChanged("Log Level")
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
    DEBUG_WEBSOCKET = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
    DEBUG_WEBSOCKET = false
  end
end

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  --#ifndef DRIVERCENTRAL
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Automatic Updates", propertyValue)
  --#endif
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Update Channel", propertyValue)
end
--#endif

function OPC.Webhook_Port(propertyValue)
  log:trace("OPC.Webhook_Port('%s')", propertyValue)
  if not gInitialized then
    return
  end
  startWebhookServer()
end

--------------------------------------------------------------------------------
-- Web UI Request Handlers (UIR)
--------------------------------------------------------------------------------

--- Send a response to the web UI via both return value (for REST) and
--- SendDataToUI (for socket push). Returns JSON for REST callers.
--- @param command string The response command name.
--- @param data table The response data.
--- @return string JSON response for REST callers.
local function uiRespond(command, data)
  -- C4:SendDataToUI cannot serialize boolean values (Director throws a
  -- basic_string construction error), so send them as strings on the socket
  -- push. The REST return keeps real booleans via JSON encoding.
  local safe = {}
  for k, v in pairs(data) do
    safe[k] = type(v) == "boolean" and tostring(v) or v
  end
  C4:SendDataToUI(command, safe)
  data._command = command
  return JSON:encode(data)
end

--- Send the full request configuration and last results to the web UI.
function UIR._GET_CONFIG()
  log:trace("UIR.GET_CONFIG()")
  local results = getResults()
  local requests = {}
  for name, config in pairs(getRequests()) do
    local entry = results[name] or {}
    requests[#requests + 1] = {
      name = name,
      type = config.type or "http",
      method = config.method or "",
      url = config.url or "",
      body = config.body or "",
      headers = config.headers or {},
      host = config.host or "",
      port = config.port or "",
      payload = config.payload or "",
      encoding = config.encoding or "text",
      tlsVerify = toboolean(config.tlsVerify),
      waitResponse = toboolean(config.waitResponse),
      timeout = config.timeout or DEFAULT_TCP_TIMEOUT,
      mac = config.mac or "",
      status = entry.status,
      detail = entry.detail,
      code = entry.code,
      response = entry.response,
      ts = entry.ts,
    }
  end
  table.sort(requests, function(a, b)
    return (a.name or "") < (b.name or "")
  end)
  local webhookResults = getWebhookResults()
  local webhooks = {}
  for name, config in pairs(getWebhooks()) do
    local entry = webhookResults[name] or {}
    webhooks[#webhooks + 1] = {
      name = name,
      key = config.key or "",
      from = entry.from,
      payload = entry.payload,
      ts = entry.ts,
    }
  end
  table.sort(webhooks, function(a, b)
    return (a.name or "") < (b.name or "")
  end)
  return uiRespond("CONFIG_DATA", {
    requests = JSON:encode(requests),
    webhooks = JSON:encode(webhooks),
    webhookBase = webhookBaseUrl() or "",
  })
end

--- Create or update a named webhook.
--- @param tParams table
function UIR._SAVE_WEBHOOK(tParams)
  log:trace("UIR.SAVE_WEBHOOK()")
  local params = JSON:decode(C4:Base64Decode(tParams.DATA or "e30="))
  local name = tostring(params.name or ""):match("^%s*(.-)%s*$")
  if IsEmpty(name) then
    return uiRespond("SAVE_RESULT", { ok = false, error = "Name is required" })
  end
  local webhooks = getWebhooks()
  webhooks[name] = { name = name, key = tostring(params.key or "") }
  saveWebhooks(webhooks)
  ensureWebhookEvents(name)
  return UIR._GET_CONFIG()
end

--- Delete a named webhook and its outputs.
--- @param tParams table
function UIR._DELETE_WEBHOOK(tParams)
  log:trace("UIR.DELETE_WEBHOOK()")
  local params = JSON:decode(C4:Base64Decode(tParams.DATA or "e30="))
  local name = tostring(params.name or "")
  local webhooks = getWebhooks()
  if webhooks[name] then
    removeWebhookOutputs(name)
    webhooks[name] = nil
    saveWebhooks(webhooks)
  end
  return UIR._GET_CONFIG()
end

--- Create or update a named request.
--- @param tParams table
function UIR._SAVE_REQUEST(tParams)
  log:trace("UIR.SAVE_REQUEST()")
  local params = JSON:decode(C4:Base64Decode(tParams.DATA or "e30="))
  local name = tostring(params.name or ""):match("^%s*(.-)%s*$")
  local originalName = tostring(params.originalName or ""):match("^%s*(.-)%s*$")

  if IsEmpty(name) then
    return uiRespond("SAVE_RESULT", { ok = false, error = "Name is required" })
  end
  local requestType = tostring(params.type or "")
  if requestType ~= "http" and requestType ~= "tcp" and requestType ~= "udp" and requestType ~= "wol" then
    return uiRespond("SAVE_RESULT", { ok = false, error = "Unknown request type" })
  end
  if requestType == "http" and IsEmpty(tostring(params.url or "")) then
    return uiRespond("SAVE_RESULT", { ok = false, error = "URL is required" })
  end
  if (requestType == "tcp" or requestType == "udp") and IsEmpty(tostring(params.host or "")) then
    return uiRespond("SAVE_RESULT", { ok = false, error = "Host is required" })
  end
  if requestType == "wol" and IsEmpty(tostring(params.mac or "")) then
    return uiRespond("SAVE_RESULT", { ok = false, error = "MAC address is required" })
  end

  local headers = {}
  for _, header in ipairs(params.headers or {}) do
    if not IsEmpty(tostring(Select(header, "name") or "")) then
      headers[#headers + 1] = { name = tostring(header.name), value = tostring(header.value or "") }
    end
  end

  local requests = getRequests()
  if not IsEmpty(originalName) and originalName ~= name then
    return uiRespond("SAVE_RESULT", {
      ok = false,
      error = "Requests cannot be renamed. Create a new request and delete this one.",
    })
  end
  if IsEmpty(originalName) and requests[name] ~= nil then
    return uiRespond("SAVE_RESULT", { ok = false, error = "A request named '" .. name .. "' already exists" })
  end

  local config = {
    name = name,
    type = requestType,
    method = tostring(params.method or "GET"):upper(),
    url = tostring(params.url or ""),
    body = tostring(params.body or ""),
    headers = headers,
    host = tostring(params.host or ""),
    port = tointeger(params.port) or 0,
    payload = tostring(params.payload or ""),
    encoding = params.encoding == "hex" and "hex" or "text",
    tlsVerify = toboolean(params.tlsVerify),
    waitResponse = toboolean(params.waitResponse),
    timeout = InRange(tointeger(params.timeout) or DEFAULT_TCP_TIMEOUT, 1, MAX_TCP_TIMEOUT),
    mac = tostring(params.mac or ""),
  }

  requests[name] = config
  saveRequests(requests)
  ensureRequestEvents(name)
  return UIR._GET_CONFIG()
end

--- Delete a named request and its outputs.
--- @param tParams table
function UIR._DELETE_REQUEST(tParams)
  log:trace("UIR.DELETE_REQUEST()")
  local params = JSON:decode(C4:Base64Decode(tParams.DATA or "e30="))
  local name = tostring(params.name or "")
  local requests = getRequests()
  if requests[name] then
    removeRequestOutputs(name)
    requests[name] = nil
    saveRequests(requests)
  end
  return UIR._GET_CONFIG()
end

--- Send a named request now. The result lands asynchronously via the
--- REQUEST_RESULT push.
--- @param tParams table
function UIR._RUN_REQUEST(tParams)
  log:trace("UIR.RUN_REQUEST()")
  local params = JSON:decode(C4:Base64Decode(tParams.DATA or "e30="))
  sendRequest(tostring(params.name or ""))
  return UIR._GET_CONFIG()
end

--- Send the device list to the web UI with display names (Room > Device).
function UIR._GET_DEVICES()
  log:trace("UIR.GET_DEVICES()")
  local devices = {}
  local allDevices = C4:GetDevices() or {}
  for id, dev in pairs(allDevices) do
    local name = dev.deviceName or ("Device " .. id)
    devices[#devices + 1] = {
      id = id,
      name = name,
      roomName = dev.roomName or "",
    }
  end
  table.sort(devices, function(a, b)
    if (a.roomName or "") ~= (b.roomName or "") then
      return (a.roomName or "") < (b.roomName or "")
    end
    return (a.name or "") < (b.name or "")
  end)
  return uiRespond("DEVICES_DATA", { devices = JSON:encode(devices) })
end

--- Send variables for a specific device to the web UI.
--- @param tParams table
function UIR._GET_DEVICE_VARIABLES(tParams)
  log:trace("UIR.GET_DEVICE_VARIABLES()")
  local params = JSON:decode(C4:Base64Decode(tParams.DATA or "e30="))
  local devId = tonumber(params.deviceId)
  if not devId then
    return
  end
  local vars = {}
  local ok, deviceVars = pcall(C4.GetDeviceVariables, C4, devId)
  if ok and deviceVars then
    for varId, varInfo in pairs(deviceVars) do
      vars[#vars + 1] = {
        id = tonumber(varId),
        name = varInfo.name or ("var" .. varId),
        type = varInfo.type or "STRING",
        value = varInfo.value,
      }
    end
  end
  table.sort(vars, function(a, b)
    return (a.name or "") < (b.name or "")
  end)
  return uiRespond("DEVICE_VARIABLES_DATA", {
    deviceId = tostring(devId),
    variables = JSON:encode(vars),
  })
end

--------------------------------------------------------------------------------
-- Programming Command Handlers (EC)
--------------------------------------------------------------------------------

--- Send Request command handler: send a named request.
--- @param params table Command parameters: Request.
function EC.Send_Request(params)
  log:trace("EC.Send_Request(%s)", params)
  local name = Select(params, "Request")
  if IsEmpty(name) or not getRequests()[name] then
    log:warn("Send Request: unknown request '%s'", tostring(name))
    return
  end
  sendRequest(name)
end

--------------------------------------------------------------------------------
-- GCPL Handlers (Dynamic List Population)
--------------------------------------------------------------------------------

--- Populate the Request dropdown for the Send Request command.
--- @param paramName string The parameter name being requested.
--- @return string[] list Sorted request names.
function GCPL.Send_Request(paramName)
  log:trace("GCPL.Send_Request(%s)", paramName)
  if paramName ~= "Request" then
    return {}
  end
  local names = {}
  for name in pairs(getRequests()) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--------------------------------------------------------------------------------
-- Reset Handler
--------------------------------------------------------------------------------

--- Reset driver to initial state.
function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")

  values:reset()
  events:reset()
  persist:reset({ PERSIST_REQUESTS, PERSIST_RESULTS, PERSIST_WEBHOOKS, PERSIST_WEBHOOK_RESULTS })

  local resetValues = GetPropertyResetValues({})
  for propName, defaultValue in pairs(resetValues) do
    UpdateProperty(propName, defaultValue, true)
  end
  startWebhookServer()
end

--#ifndef DRIVERCENTRAL
--------------------------------------------------------------------------------
-- Update Drivers
--------------------------------------------------------------------------------

--- Action: Update Drivers
function EC.Update_Drivers()
  log:trace("EC.Update_Drivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end

--- Update the driver from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if the driver is up to date (optional).
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if not IsEmpty(updatedDrivers) then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      else
        log:info("No driver updates available")
      end
    end, function(error)
      log:error("An error occurred updating drivers: %s", error)
    end)
end
--#endif
