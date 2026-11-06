-- A driver's DriverCentral build under its license gate: the real cloud client answered by the fake Cloud driver in
-- dc_cloud.lua, every outward effect recorded, and the gate's reads driven by hand.
--
-- local H = require("license_harness")
-- H.load("light_relay", { AC = 1, AS = "License Activated" }, { ["Some Property"] = "value" })
-- H.acts("what", function() ... end) / H.blocked("what", function() ... end)
-- H.reads(n)   -- n rounds of 10 s: one ping, then one read by the gate
-- H.load(name, answer, properties, 0) loads it as a build with no product yet.

local T = require("testlib")
local cloud = require("dc_cloud")

local H = { cloud = cloud, effects = {}, rooms = {}, deviceVars = {} }

local ROOT = (debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./") .. "../"

local CLOUD_ID = 999

--- Runs `path` as the DriverCentral build compiles it: a line its directives leave out is blanked.
--- @param path string
local function dofileDriverCentral(path)
  local f = assert(io.open(path))
  local lines, stack, including = {}, {}, true
  for line in f:lines() do
    local ifdef, name = line:match("^%s*%-%-%s*#(ifn?def)%s+([%w_]+)%s*$")
    if ifdef then
      stack[#stack + 1] = including
      including = including and (name == "DRIVERCENTRAL") == (ifdef == "ifdef")
    elseif line:match("^%s*%-%-%s*#else%s*$") then
      including = stack[#stack] and not including
    elseif line:match("^%s*%-%-%s*#endif%s*$") then
      including = table.remove(stack)
    end
    lines[#lines + 1] = including and line or ""
  end
  f:close()
  assert(load(table.concat(lines, "\n"), "@" .. path))()
end

--- Properties as Director creates them from driver.xml's defaults, and the config sections the driver reads.
--- @param xmlPath string
--- @param overrides? table<string, string>
local function properties(xmlPath, overrides)
  local f = assert(io.open(xmlPath))
  local xml = f:read("*a")
  f:close()
  Properties = {}
  for block in xml:gmatch("<property>(.-)</property>") do
    Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
  end
  for k, v in pairs(overrides or {}) do
    Properties[k] = v
  end
  local config = {
    version = xml:match("<version>(.-)</version>") or "20261104",
    minimum_os_version = xml:match("<minimum_os_version>(.-)</minimum_os_version>") or "3.3.0",
    model = xml:match("<model>(.-)</model>") or "model",
    config = xml,
  }
  PropertyConfig = nil
  function C4:GetDriverConfigInfo(section)
    return config[section]
  end
  local propsXml = xml:match("<properties>(.-)</properties>") or ""
  function C4:GetDeviceData(id, key)
    if id == CLOUD_ID and key == "version" then
      return "1033"
    elseif tonumber(id) == tonumber(C4:GetDeviceID()) then
      if key == "properties" then
        return propsXml
      elseif key == "version" then
        return config.version
      elseif key == "name" then
        return "Test Device"
      end
    end
    return nil
  end
end

--- Records every outward effect: commands to proxies and devices, events, variables and network requests.
local function record()
  local function wrap(name, describe)
    local real = C4[name]
    C4[name] = function(self, ...)
      local line = describe(...)
      if line then
        H.effects[#H.effects + 1] = line
      end
      if real then
        return real(self, ...)
      end
    end
  end
  wrap("SendToProxy", function(id, cmd)
    return "proxy " .. tostring(id) .. " " .. tostring(cmd)
  end)
  wrap("SendToDevice", function(id, cmd)
    if id ~= CLOUD_ID then
      return "device " .. tostring(id) .. " " .. tostring(cmd)
    end
  end)
  wrap("FireEvent", function(name)
    return "event " .. tostring(name)
  end)
  wrap("FireEventByID", function(id)
    return "event " .. tostring(id)
  end)
  wrap("SetVariable", function(id, value)
    return "variable " .. tostring(id) .. "=" .. tostring(value)
  end)
  function C4:urlPost(url, _, _, _, callback)
    H.effects[#H.effects + 1] = "http POST " .. tostring(url)
    if callback then
      callback(1, "", 204, {}, nil)
    end
    return 1
  end
  function C4:UpdateProperty(k, v)
    Properties[k] = v
  end
end

local installed = false
--- The C4 calls the drivers make that the shim leaves out, once per process.
local function install()
  if installed then
    return
  end
  installed = true
  local cloudByName = C4.GetDevicesByC4iName
  function C4:GetDevicesByC4iName(name)
    if name == "driverCentral-Cloud.c4z" then
      return cloudByName(self, name)
    end
    return name == "roomdevice.c4i" and H.rooms or {}
  end
  C4.SendDataToUI = C4.SendDataToUI or function() end
  C4.CreateServer = C4.CreateServer or function() end
  C4.DestroyServer = C4.DestroyServer or function() end
  C4.ServerSend = C4.ServerSend or function() end
  C4.ServerCloseClient = C4.ServerCloseClient or function() end
  C4.GetControllerNetworkAddress = C4.GetControllerNetworkAddress or function()
    return "198.51.100.2"
  end
  function C4:GetProjectProperty(name)
    return name == "TemperatureScale" and "FAHRENHEIT" or ""
  end
  function C4:GetDeviceVariable(id, var)
    return (H.deviceVars[id] or {})[var]
  end
  record()
end

--- Loads `driver`'s DriverCentral build with a fresh client and gate, with the Cloud driver answering each ping with
--- `answer` (nil answers nothing), and runs its OnDriverInit and late init.
--- @param driver string The driver's folder under drivers/.
--- @param answer? table
--- @param overrides? table<string, string> Property values.
--- @param productId? integer The product id, 999 unless given.
function H.load(driver, answer, overrides, productId)
  install()
  if H.gate and H.gate._timer then
    H.gate._timer:Cancel()
  end
  package.loaded["cloud-client-byte"] = nil
  package.loaded["lib.drivercentral"] = nil
  cloud.ping, cloud.answer, cloud.silent, cloud.present = nil, answer, answer == nil, true
  DC_OnDriverStatus = nil
  properties(ROOT .. "drivers/" .. driver .. "/driver.xml", overrides)
  H.gate = require("lib.drivercentral")
  H.gate.PRODUCT_ID = productId or 999
  dofileDriverCentral(ROOT .. "drivers/" .. driver .. "/driver.lua")
  if urlDo then
    -- lib.http's transport: answered at once, so a driver's in-flight guard never holds the next request.
    urlDo = function(method, url, _, _, callback)
      H.effects[#H.effects + 1] = "http " .. tostring(method) .. " " .. tostring(url)
      if callback then
        callback(nil, 204, {}, "", nil, url)
      end
    end
  end
  OnDriverInit()
  ShimLateInit("DIT_STARTUP")
end

--- `n` rounds of 10 s: one ping, then one read by the gate.
--- @param n? integer
function H.reads(n)
  for _ = 1, n or 1 do
    if cloud.ping then
      cloud.poll(1)
    end
    H.gate:_check()
  end
end

--- What `fn` does to the outside world, as one string ("" for nothing).
--- @param fn function
--- @return string effects
function H.run(fn)
  local mark = #H.effects
  fn()
  local out = {}
  for i = mark + 1, #H.effects do
    out[#out + 1] = H.effects[i]
  end
  return table.concat(out, "; ")
end

function H.acts(what, fn)
  local effects = H.run(fn)
  T.check(what .. " acts", effects ~= "", "nothing reached a device, proxy, event, variable or the network")
end

function H.blocked(what, fn)
  local effects = H.run(fn)
  T.check(what .. " does nothing", effects == "", effects)
end

H.LICENSED = { AC = 1, AS = "License Activated" }
H.INVALID = { AC = 0, AS = "Invalid License" }

--- The checks every driver shares: a licensed load runs, an unlicensed one stops at the gate's 30th read and does
--- nothing, a purchase starts it at once (`onPurchase` sees what it sends), and a build with no product is stopped
--- from its load.
--- @param driver string
--- @param overrides? table<string, string>
--- @param entries table[] { what, fn } The driver's entry points.
--- @param ready string The Driver Status the driver shows while running.
--- @param onPurchase? fun(effects: string) Checks what the restart sent.
--- @param setup? function Runs after each load, before the checks.
function H.standardChecks(driver, overrides, entries, ready, onPurchase, setup)
  setup = setup or function() end
  T.section(driver .. ": a licensed load runs")
  H.load(driver, H.LICENSED, overrides)
  setup()
  H.reads(40)
  T.eq("Driver Status", Properties["Driver Status"], ready)
  for _, e in ipairs(entries) do
    H.acts(e[1], e[2])
  end

  T.section(driver .. ": without a license it runs five minutes, then stops and does nothing")
  H.load(driver, H.INVALID, overrides)
  setup()
  H.reads(29)
  T.eq("29 reads of 0: still running", Properties["Driver Status"], ready)
  H.reads()
  T.eq("the 30th read stops it", Properties["Driver Status"], "No active license")
  for _, e in ipairs(entries) do
    H.blocked(e[1], e[2])
  end

  T.section(driver .. ": a purchase starts it at once")
  local sent = H.run(function()
    cloud.say(H.LICENSED)
  end)
  T.eq("Driver Status", Properties["Driver Status"], ready)
  if onPurchase then
    onPurchase(sent)
  end
  for _, e in ipairs(entries) do
    H.acts(e[1], e[2])
  end

  T.section(driver .. ": a build with no product yet is stopped from its load")
  H.load(driver, H.LICENSED, overrides, 0)
  setup()
  T.eq("Cloud Status", Properties["Cloud Status"], "No DriverCentral product")
  T.eq("Driver Status", Properties["Driver Status"], "No active license")
  for _, e in ipairs(entries) do
    H.blocked(e[1], e[2])
  end
  H.reads(40)
  T.eq("and stays stopped", Properties["Driver Status"], "No active license")

  if H.gate and H.gate._timer then
    H.gate._timer:Cancel()
  end
end

return H
