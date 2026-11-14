-- lib.ui.tab-properties: what a web tab is shown of driver.xml, the changes it may make and is refused, and the push
-- after a change made in Composer.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_ui_tab_properties.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.handlers")

local CONFIG = table.concat({
  "<properties>",
  "<property><name>Driver Version</name><type>STRING</type><readonly>true</readonly></property>",
  "<property><name>Log Level</name><type>DYNAMIC_LIST</type><items></items></property>",
  "<property><name>Offline Buffer &amp; Retry</name><type>LABEL</type><default>Offline Buffer &amp; Retry</default></property>",
  "<property><name>Mode</name><type>LIST</type><items><item>Auto</item><item>Fast &amp; loud</item><item>Off</item></items>",
  "<description>How it runs &amp; when.</description></property>",
  "<property><name>Retries</name><type>RANGED_INTEGER</type><minimum>0</minimum><maximum>10</maximum></property>",
  "<property><name>API Token</name><type>STRING</type><password>true</password></property>",
  "<property><name>Server</name><type>STRING</type></property>",
  "<property><name>Offset</name><type>RANGED_FLOAT</type><minimum>-1.5</minimum><maximum>1.5</maximum></property>",
  "</properties>",
})

function C4:GetDriverConfigInfo(section)
  if section == "config" then
    return CONFIG
  end
end

function C4:UpdateProperty(name, value)
  Properties[name] = value
end

Properties["Driver Version"], Properties["Log Level"], Properties.Mode = "20261109", "3 - Info", "Off"
Properties.Retries, Properties["API Token"], Properties.Server, Properties.Offset = "3", "secret-token", "", "0"

local log = require("lib.logging")
local tabProperties = require("lib.ui.tab-properties")

local function byName(list)
  local found = {}
  for _, property in ipairs(list) do
    found[property.name] = property
  end
  return found
end

T.section("list")
local list = tabProperties:list()
local shown = byName(list)
T.eq("shows each property the tab can show, in driver.xml order", #list, 5)
T.eq("first comes Driver Version", list[1].name, "Driver Version")
T.truthy("Driver Version is read-only", shown["Driver Version"].readonly)
T.eq("a property before the first label has no group", shown["Driver Version"].group, "")
T.eq("a label's & is decoded", shown.Mode.group, "Offline Buffer & Retry")
T.eq("a choice's & is decoded", shown.Mode.choices[2], "Fast & loud")
T.eq("a description's & is decoded", shown.Mode.description, "How it runs & when.")
T.eq("a list carries its current value", shown.Mode.value, "Off")
T.eq("a ranged integer carries its minimum", shown.Retries.minimum, 0)
T.eq("a ranged integer carries its maximum", shown.Retries.maximum, 10)
T.eq("Log Level's choices are the logger's", #shown["Log Level"].choices, #log:getLogLevelNames())
T.falsy("Log Level's own marker stays inside the library", shown["Log Level"].logLevels)
T.falsy("a password is left out", shown["API Token"])
T.falsy("a type the tab cannot edit is left out", shown.Offset)
for _, property in ipairs(list) do
  T.check(property.name .. " carries no password", property.value ~= "secret-token")
end

T.section("set")
local handled
OPC.Mode = function(value)
  handled = value
end
T.eq("a listed choice is accepted", tabProperties:set("Mode", "Auto"), nil)
T.eq("and is set", Properties.Mode, "Auto")
T.eq("and its handler runs", handled, "Auto")
T.eq("another choice is refused", tabProperties:set("Mode", "Slow"), "Mode has no choice Slow.")
T.eq("and leaves the value", Properties.Mode, "Auto")
T.eq("a whole number in range is accepted", tabProperties:set("Retries", "7"), nil)
T.eq("and is set", Properties.Retries, "7")
T.eq("4.0 is accepted", tabProperties:set("Retries", "4.0"), nil)
T.eq("and set as 4", Properties.Retries, "4")
T.eq(
  "a number past the maximum is refused",
  tabProperties:set("Retries", "11"),
  "Retries must be a whole number from 0 to 10."
)
T.eq("a fraction is refused", tabProperties:set("Retries", "2.5"), "Retries must be a whole number from 0 to 10.")
T.eq("text is refused", tabProperties:set("Retries", "many"), "Retries must be a whole number from 0 to 10.")
T.eq("Log Level takes one of the logger's levels", tabProperties:set("Log Level", log:getLogLevelNames()[1]), nil)
T.eq("and no other", tabProperties:set("Log Level", "9 - Everything"), "Log Level has no choice 9 - Everything.")
T.eq("a string takes any text", tabProperties:set("Server", "influx.example.invalid"), nil)
T.eq("a read-only property is refused", tabProperties:set("Driver Version", "1"), "The tab cannot set Driver Version.")
T.eq("a password is refused", tabProperties:set("API Token", "x"), "The tab cannot set API Token.")
T.eq("an unknown name is refused", tabProperties:set("Nope", "x"), "The tab cannot set Nope.")
T.eq("a value that is not a string is refused", tabProperties:set("Server", 5), "The tab cannot set Server.")

T.section("follow")
local pushed = 0
local order = {}
OPC.Mode = function(value)
  order[#order + 1] = "handler"
  return "kept"
end
tabProperties:follow(function()
  pushed = pushed + 1
  order[#order + 1] = "push"
end)
T.eq("a change made in Composer still returns its handler's result", OPC.Mode("Off"), "kept")
T.eq("its handler runs before the push", table.concat(order, ","), "handler,push")
OPC.Server("influx.example.invalid")
T.eq("a property with no handler of its own pushes too", pushed, 2)
OPC.Driver_Version("1")
T.eq("so does a read-only one, which only the driver changes", pushed, 3)
T.falsy("a password gets no push", OPC.API_Token)

T.section("serve")
local sent = {}
function C4:SendDataToUI(command, params)
  sent[#sent + 1] = { command = command, data = JSON:decode(params.json) }
end
--- A command's DATA as lib/ui/page.js sends it.
local function page(params)
  return { DATA = C4:Base64Encode(JSON:encode(params)) }
end
tabProperties:serve()
UIR._GET_PROPERTIES()
T.eq("the card's ask is answered with PROPERTIES", sent[1].command, "PROPERTIES")
T.eq("carrying the list, as one JSON parameter", #sent[1].data.properties, 5)
sent = {}
UIR._SET_PROPERTY(page({ property = "Mode", value = "Auto" }))
T.eq("a change it can make is made", Properties.Mode, "Auto")
T.eq("with nothing sent back", #sent, 0)
UIR._SET_PROPERTY(page({ property = "Mode", value = "Slow" }))
T.eq("a change it refuses goes back as PROPERTY_ERROR", sent[1].command, "PROPERTY_ERROR")
T.eq("naming the property", sent[1].data.property, "Mode")
T.eq("and why", sent[1].data.error, "Mode has no choice Slow.")
sent = {}
UIR._SET_PROPERTY({ DATA = "not base64 json" })
T.eq("a body that does not decode is refused as no property", sent[1].data.error, "The tab cannot set nil.")

T.section("The card follows the Support Code's window")
do
  -- No secret in a test build, so the window's change is told directly.
  local code = require("lib.support-code")
  sent = {}
  code:_tell(true)
  T.eq("opening it sends the card its list", sent[1] and sent[1].command, "PROPERTIES")
  sent = {}
  code:_tell(false)
  T.eq("and so does the hour's end", sent[1] and sent[1].command, "PROPERTIES")
end

T.finish()
