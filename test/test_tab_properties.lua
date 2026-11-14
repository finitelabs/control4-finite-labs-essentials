-- The Properties card and tab bar of Network Requests' and Variable Expressions' web tabs: the properties a tab is
-- sent, a change made from it, the changes it is turned away from, a change made in Composer reaching it, and the bar
-- that shows only with two or more tabs. lib.ui.tab-properties answers the card; the card asks again on each connect
-- and after each property change, wherever it was made.
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
  package.loaded["lib.ui.tab-properties"] = nil
  package.loaded["lib.support-code"] = nil
  H.load(driver, answer or H.LICENSED, nil, productId)
  function C4:SendDataToUI(command, data)
    pushes[#pushes + 1] = { command = command, data = data }
  end
  pushes = {}
end

local function data(t)
  return { DATA = C4:Base64Encode(JSON:encode(t)) }
end

--- The last push of a command since `from`, decoded, or nil.
local function pushed(command, from)
  for i = #pushes, from or 1, -1 do
    if pushes[i].command == command then
      return JSON:decode(pushes[i].data.json)
    end
  end
end

--- Sets a property from the tab: the refusal it gets, or nil when it was set.
local function set(name, value)
  local from = #pushes + 1
  UIR._SET_PROPERTY(data({ property = name, value = value }))
  return pushed("PROPERTY_ERROR", from)
end

--- The properties the card is sent when it asks, or those of a push.
local function shown(reply)
  if not reply then
    UIR._GET_PROPERTIES()
    reply = pushed("PROPERTIES")
  end
  return reply.properties
end

local function property(name, reply)
  for _, p in ipairs(shown(reply)) do
    if p.name == name then
      return p
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
  UIR._GET_PROPERTIES()
  T.falsy("the Support Code's value is never sent", pushes[#pushes].data.json:find("ABCDE", 1, true))
  Properties["Support Code"] = ""

  T.section(driver .. ": a change made in the tab")
  pushes = {}
  T.eq("is not refused", set("Log Level", "4 - Debug"), nil)
  T.eq("sets the property", Properties["Log Level"], "4 - Debug")
  T.eq("and the card's next ask shows it", property("Log Level").value, "4 - Debug")
  T.eq("the driver pushes no config of its own for it", pushed("CONFIG_DATA"), nil)

  T.section(driver .. ": changes the tab is turned away from")
  local refused = set("Log Mode", "Loud")
  T.truthy("a value the list lacks is refused, saying why", ((refused or {}).error or ""):find("Log Mode", 1, true))
  T.eq("naming the field it belongs under", (refused or {}).property, "Log Mode")
  T.eq("leaving the property as it was", Properties["Log Mode"], "Off")
  T.truthy("a read-only property is refused", set("Driver Version", "1"))
  T.neq("and keeps its value", Properties["Driver Version"], "1")
  T.truthy("the Support Code cannot be set from the tab", set("Support Code", "not-a-code"))
  T.eq("so no code is entered", Properties["Support Code"], "")
  T.truthy("a change with no value is refused", set("Log Mode"))
  T.truthy("so is a property the driver lacks", set("Nothing", "x"))

  T.section(driver .. ": Log Level offers the logger's levels")
  local log = require("lib.logging")
  log:allowTraceAndUltra(false)
  T.eq(
    "a DriverCentral build's tab stops at Debug",
    property("Log Level").choices,
    { "0 - Fatal", "1 - Error", "2 - Warning", "3 - Info", "4 - Debug" }
  )
  T.truthy("and turns Trace away", set("Log Level", "5 - Trace"))
  log:allowTraceAndUltra(true)
  T.eq("a Support Code hour adds Trace and Ultra", property("Log Level").choices[7], "6 - Ultra")
  T.eq("which the tab can set", set("Log Level", "6 - Ultra"), nil)
  T.eq("so the property shows it", Properties["Log Level"], "6 - Ultra")
  set("Log Level", "4 - Debug")
  local supportCode = require("lib.support-code")
  log:allowTraceAndUltra(false)
  pushes = {}
  log:allowTraceAndUltra(true)
  supportCode:_tell(true)
  local opened = pushed("PROPERTIES")
  T.truthy("opening the hour pushes the card, which no property change would ask", opened)
  T.eq("with Ultra on offer", property("Log Level", opened or { properties = {} }).choices[7], "6 - Ultra")

  T.section(driver .. ": a change made in Composer")
  for _, name in ipairs({ "Automatic Updates", "Update Channel", "Log Mode", "Log Level", "Cloud Monitoring" }) do
    local choices = property(name).choices
    local value = choices[1] == Properties[name] and choices[2] or choices[1]
    Properties[name] = value
    OnPropertyChanged(name)
    T.eq(name .. " shows in the card's next ask", property(name).value, Properties[name])
  end

  T.section(driver .. ": without a license")
  load(driver, H.INVALID, 0)
  T.eq("the tab shows the driver stopped", property("Driver Status").value, "No active license")
  T.eq("and can still set its log level", set("Log Level", "4 - Debug"), nil)
  T.eq("which takes", Properties["Log Level"], "4 - Debug")
end

T.section("network_requests: Webhook Port from the tab")
load("network_requests")
T.eq("its range is sent", { property("Webhook Port").minimum, property("Webhook Port").maximum }, { 0, 65535 })
pushes = {}
T.eq("a port in range is not refused", set("Webhook Port", "49301"), nil)
T.eq("and is set", Properties["Webhook Port"], "49301")
T.truthy("the tab's webhook URLs follow it", (pushed("CONFIG_DATA") or {}).webhookBase:find("49301", 1, true))
T.truthy("and so does the Webhook URL shown", property("Webhook URL").value:find("49301", 1, true))
for _, bad in ipairs({ "70000", "-1", "12.5", "abc", "" }) do
  T.truthy("'" .. bad .. "' is refused", set("Webhook Port", bad))
  T.eq("and leaves the port", Properties["Webhook Port"], "49301")
end
T.truthy("Webhook URL is read-only", set("Webhook URL", "http://x/"))

T.section("network_requests: the webhook server's status, in the order Director reports a port change")
local listening = "http://198.51.100.2:49301/<Webhook Name>"
OnServerStatusChanged(49300, "OFFLINE")
T.eq("the port just closed going offline is no failure", Properties["Webhook URL"], listening)
OnServerStatusChanged(49301, "ONLINE")
T.eq("and the new port coming online keeps the URL", Properties["Webhook URL"], listening)
T.eq("which the card's next ask shows", property("Webhook URL").value, listening)
OnServerStatusChanged(49301, "OFFLINE")
T.truthy(
  "the port in use going offline is a failure",
  Properties["Webhook URL"]:find("Failed to listen on port 49301", 1, true)
)
T.truthy("which the card shows too", property("Webhook URL").value:find("Failed to listen", 1, true))
OnServerStatusChanged(49301, "ONLINE")
T.eq("and coming back online restores the URL", Properties["Webhook URL"], listening)

-- The tab bar, the Properties card and the link to the driver come from lib/ui, which its own tests cover; these check
-- each page is wired to it.
for _, driver in ipairs({ "network_requests", "variable_expressions" }) do
  T.section(driver .. ": the page on lib/ui")
  local page = readFile("drivers/" .. driver .. "/www/html/index.html"):gsub("%s+", "")
  T.truthy("it embeds the kit's stylesheet", page:find("<!--#embed../../../../src/lib/ui/style.css-->", 1, true))
  T.truthy("and its script", page:find("<!--#embed../../../../src/lib/ui/page.js-->", 1, true))
  T.truthy("its one tab is a real tab naming its panel", page:find('class="nav-tabactive"data-panel="list"', 1, true))
  T.truthy("which exists", page:find('id="panel-list"', 1, true))
  T.truthy("the kit runs the tab bar", page:find("initTabs(closeEditor)", 1, true))
  T.truthy("and the Properties card", page:find("initPropertiesCard(document.getElementById('props'))", 1, true))
  T.truthy("which stays hidden until there is something to show", page:find('id="props-card"hidden', 1, true))
  T.truthy(
    "the Properties card comes first in the panel",
    page:find('id="props-card"', 1, true) < page:find('<tableid="', 1, true)
  )
end

T.finish()
