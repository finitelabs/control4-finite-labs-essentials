-- The Properties card and tab bar of Network Requests' and Variable Expressions' web tabs: the properties a tab is
-- sent, a change made from it, the changes it is turned away from, a change made in Composer reaching it, and the bar
-- that shows only with two or more tabs.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_tab_properties.lua

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

local pushes = {}

--- Loads a driver with a fresh module and records what it pushes to the tab.
local function load(driver, answer, productId)
  package.loaded["lib.tab-properties"] = nil
  H.load(driver, answer or H.LICENSED, nil, productId)
  function C4:SendDataToUI(command, data)
    pushes[#pushes + 1] = { command = command, data = data }
  end
  pushes = {}
end

local function data(t)
  return { DATA = C4:Base64Encode(JSON:encode(t)) }
end

local function set(name, value)
  return JSON:decode(UIR._SET_PROPERTY(data({ property = name, value = value })))
end

local function shown(reply)
  return JSON:decode((reply or JSON:decode(UIR._GET_CONFIG())).properties)
end

local function property(name, reply)
  for _, p in ipairs(shown(reply)) do
    if p.name == name then
      return p
    end
  end
end

local function pushedValue(name)
  for i = #pushes, 1, -1 do
    if pushes[i].command == "CONFIG_DATA" then
      return property(name, pushes[i].data).value
    end
  end
end

-- The harness reads driver.xml unbuilt, so both builds' properties are here.
local COMMON = {
  "Cloud Status",
  "Automatic Updates",
  "Update Channel",
  "Driver Status",
  "Driver Version",
  "Log Level",
  "Log Mode",
  "Cloud Monitoring",
}

for driver, extra in pairs({ network_requests = { "Webhook Port", "Webhook URL" }, variable_expressions = {} }) do
  T.section(driver .. ": the properties the tab is sent")
  load(driver)
  local names = {}
  for _, p in ipairs(shown()) do
    table.insert(names, p.name)
  end
  local expected = {}
  for _, name in ipairs(COMMON) do
    table.insert(expected, name)
  end
  for _, name in ipairs(extra) do
    table.insert(expected, name)
  end
  T.eq("every property in driver.xml order, labels and the Support Code left out", names, expected)
  T.eq("each under the label above it", property("Log Level").group, "Driver Settings")
  T.eq("the cloud ones too", property("Automatic Updates").group, "Cloud Settings")
  T.eq("a list carries its choices", property("Log Mode").choices, { "Off", "Print", "Log", "Print and Log" })
  T.eq("and its value", property("Log Mode").value, "Off")
  T.eq("a status is read-only", property("Driver Status").readonly, true)
  T.eq("and has its value", property("Driver Status").value, "Ready")
  T.eq("a list is not read-only", property("Log Level").readonly, false)
  T.truthy("a description comes too", property("Cloud Monitoring").description:find("Finite Labs", 1, true))

  Properties["Support Code"] = "ABCDE-FGHIJ"
  T.falsy("the Support Code's value is never sent", UIR._GET_CONFIG():find("ABCDE", 1, true))
  Properties["Support Code"] = ""

  T.section(driver .. ": a change made in the tab")
  pushes = {}
  local reply = set("Log Level", "4 - Debug")
  T.eq("sets the property", Properties["Log Level"], "4 - Debug")
  T.eq("the reply is the tab's config", reply._command, "CONFIG_DATA")
  T.eq("with the new value", property("Log Level", reply).value, "4 - Debug")
  T.eq("and the socket hears it", pushedValue("Log Level"), "4 - Debug")

  T.section(driver .. ": changes the tab is turned away from")
  reply = set("Log Mode", "Loud")
  T.eq("a value the list lacks is refused", reply._command, "PROPERTY_ERROR")
  T.truthy("and says why", reply.error:find("Log Mode", 1, true))
  T.eq("naming the field it belongs under", reply.property, "Log Mode")
  T.eq("leaving the property as it was", Properties["Log Mode"], "Off")
  T.eq("a read-only property is refused", set("Driver Version", "1")._command, "PROPERTY_ERROR")
  T.neq("and keeps its value", Properties["Driver Version"], "1")
  T.eq("the Support Code cannot be set from the tab", set("Support Code", "not-a-code")._command, "PROPERTY_ERROR")
  T.eq("so no code is entered", Properties["Support Code"], "")
  T.eq("a change with no value is refused", set("Log Mode")._command, "PROPERTY_ERROR")
  T.eq("so is a property the driver lacks", set("Nothing", "x")._command, "PROPERTY_ERROR")

  T.section(driver .. ": a change made in Composer")
  for _, name in ipairs({ "Automatic Updates", "Update Channel", "Log Mode", "Log Level", "Cloud Monitoring" }) do
    local choices = property(name).choices
    local value = choices[1] == Properties[name] and choices[2] or choices[1]
    pushes = {}
    Properties[name] = value
    OnPropertyChanged(name)
    T.eq(name .. " reaches the tab", pushedValue(name), Properties[name])
  end

  T.section(driver .. ": without a license")
  load(driver, H.INVALID, 0)
  T.eq("the tab shows the driver stopped", property("Driver Status").value, "No active license")
  T.eq("and can still set its log level", set("Log Level", "4 - Debug")._command, "CONFIG_DATA")
  T.eq("which takes", Properties["Log Level"], "4 - Debug")
end

T.section("network_requests: Webhook Port from the tab")
load("network_requests")
T.eq("its range is sent", { property("Webhook Port").minimum, property("Webhook Port").maximum }, { 0, 65535 })
local reply = set("Webhook Port", "49301")
T.eq("a port in range is set", Properties["Webhook Port"], "49301")
T.truthy("the webhook URLs follow it", reply.webhookBase:find("49301", 1, true))
T.truthy("and so does the Webhook URL shown", property("Webhook URL", reply).value:find("49301", 1, true))
for _, bad in ipairs({ "70000", "-1", "12.5", "abc", "" }) do
  T.eq("'" .. bad .. "' is refused", set("Webhook Port", bad)._command, "PROPERTY_ERROR")
  T.eq("and leaves the port", Properties["Webhook Port"], "49301")
end
T.eq("Webhook URL is read-only", set("Webhook URL", "http://x/")._command, "PROPERTY_ERROR")

T.section("network_requests: the webhook server's status, in the order Director reports a port change")
local listening = "http://198.51.100.2:49301/<Webhook Name>"
pushes = {}
OnServerStatusChanged(49300, "OFFLINE")
T.eq("the port just closed going offline is no failure", Properties["Webhook URL"], listening)
OnServerStatusChanged(49301, "ONLINE")
T.eq("and the new port coming online keeps the URL", Properties["Webhook URL"], listening)
T.eq("which reaches the tab", pushedValue("Webhook URL"), listening)
OnServerStatusChanged(49301, "OFFLINE")
T.truthy(
  "the port in use going offline is a failure",
  Properties["Webhook URL"]:find("Failed to listen on port 49301", 1, true)
)
T.truthy("which reaches the tab too", pushedValue("Webhook URL"):find("Failed to listen", 1, true))
OnServerStatusChanged(49301, "ONLINE")
T.eq("and coming back online restores the URL", Properties["Webhook URL"], listening)

for driver, panel in pairs({ network_requests = "panel-list", variable_expressions = "panel-list" }) do
  T.section(driver .. ": the tab bar")
  local page = readFile("drivers/" .. driver .. "/www/html/index.html"):gsub("%s+", "")
  T.truthy("the bar starts hidden", page:find(".nav{display:none;", 1, true))
  T.truthy("and shows with the class the count sets", page:find(".nav.multi{display:flex;}", 1, true))
  T.truthy(
    "its one tab is a real tab naming its panel",
    page:find('class="nav-tabactive"data-panel="' .. panel .. '"', 1, true)
  )
  T.truthy("which exists", page:find('id="' .. panel .. '"', 1, true))
  T.truthy("the count sets the class", page:find("classList.toggle('multi',tabs.length>1)", 1, true))
  T.truthy("and a click shows a tab's panel", page:find("showTab(tab)", 1, true))
  T.truthy("a refusal draws even when the focus has moved on", page:find("renderProps(true)", 1, true))
  T.truthy(
    "the Properties card comes first in the panel",
    page:find('id="props-card"', 1, true) < page:find('<tableid="', 1, true)
  )
end

T.finish()
