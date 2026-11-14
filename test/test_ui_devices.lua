-- lib.ui.devices: the variable browser's driver side. A driver and the proxies restating it as one entry, names made
-- unique in their room, the project's agents, entries left out, the order, a device's variables and their values cut
-- on a whole character, and the two commands serve answers.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_ui_devices.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.handlers")

local agentsXml = "<systemitems></systemitems>"
function C4:GetProjectItems(filter)
  if filter == "AGENTS" then
    return agentsXml
  end
  return ""
end

local sent = {}
function C4:SendDataToUI(command, params)
  sent[#sent + 1] = { command = command, data = JSON:decode(params.json) }
end

local log = require("lib.logging")
local Devices = require("lib.ui.devices")

--- A command's DATA as lib/ui/page.js sends it.
local function pageBody(params)
  return { DATA = C4:Base64Encode(JSON:encode(params)) }
end

--- @param devices table[]
--- @return string[] names Each entry's room, a ">", and its name.
local function labels(devices)
  local out = {}
  for _, d in ipairs(devices) do
    out[#out + 1] = d.roomName .. " > " .. d.name
  end
  return out
end

local function byId(devices, id)
  for _, d in ipairs(devices) do
    if d.id == id then
      return d
    end
  end
end

ShimSetDevices({
  [700] = {
    deviceName = "Light",
    roomName = "Hall",
    proxies = { [701] = true },
    variables = { ["1"] = { name = "OWN" } },
  },
  [701] = {
    deviceName = "Light",
    roomName = "Hall",
    driverFileName = "light_v2.c4i",
    proxies = { [702] = true },
    variables = { ["2"] = { name = "LEVEL", value = "40", type = "NUMBER" } },
  },
  [702] = {
    deviceName = "Light",
    roomName = "Hall",
    driverFileName = "button.c4i",
    variables = { ["3"] = { name = "X" } },
  },
  [710] = { deviceName = "Lamp", roomName = "attic", variables = { ["1"] = { name = "A" } } },
  [711] = { deviceName = "Lamp", roomName = "Attic", variables = { ["1"] = { name = "B" } } },
  [712] = { deviceName = "Lamp", roomName = "attic", variables = { ["1"] = { name = "C" } } },
  [713] = { deviceName = "lamp", roomName = "Attic", variables = { ["1"] = { name = "D" } } },
  [720] = { deviceName = "Nothing", roomName = "Attic" },
  [730] = {
    deviceName = "Panel",
    roomName = "Hall",
    proxies = { [731] = true },
    variables = { ["1"] = { name = "ARMED" } },
  },
  [731] = { deviceName = "Area 1", roomName = "Hall", variables = { ["1"] = { name = "STATE" } } },
  [740] = { deviceName = "zebra", roomName = "Hall", variables = { ["1"] = { name = "Z" } } },
  [741] = { deviceName = "Apple", roomName = "Hall", variables = { ["1"] = { name = "A" } } },
  [750] = { roomName = "Hall", variables = { ["9"] = { name = "N" } } },
})

T.section("list: entries")
local devices = Devices.list()
local light = byId(devices, 700)
T.truthy("a driver and the proxies restating it are one entry", light)
T.falsy("so the proxy has none of its own", byId(devices, 701))
T.falsy("nor does a proxy of that proxy", byId(devices, 702))
T.eq("the entry's members, by id", light.memberIds, { 700, 701, 702 })
T.truthy("and it has variables", light.hasVariables)
T.eq("an entry is in the Devices section", light.section, "Devices")
T.truthy("a proxy named for itself stays its own entry", byId(devices, 731))
T.eq("so its owner keeps only itself", byId(devices, 730).memberIds, { 730 })
T.falsy("a device without variables is left out", byId(devices, 720))
T.eq("a device without a name gets one", byId(devices, 750).name, "Device 750")

T.section("list: names and order")
T.eq("names that collide in a room get their id", byId(devices, 710).name, "Lamp (710)")
T.eq("in the same room only", byId(devices, 711).name, "Lamp")
T.eq("by room, then name, ignoring case, id breaking a tie", labels(devices), {
  "Attic > Lamp",
  "Attic > lamp",
  "attic > Lamp (710)",
  "attic > Lamp (712)",
  "Hall > Apple",
  "Hall > Area 1",
  "Hall > Device 750",
  "Hall > Light",
  "Hall > Panel",
  "Hall > zebra",
})

T.section("list: options")
local all = Devices.list({ withoutVariables = true })
T.eq("withoutVariables lists a device without variables too", byId(all, 720).hasVariables, false)
T.eq("among the rest", #all, #devices + 1)
local left = Devices.list({ exclude = { 740, 701 } })
T.falsy("exclude leaves an entry out by its id", byId(left, 740))
T.falsy("or by any member's id", byId(left, 700))
T.eq("and keeps the rest", #left, #devices - 2)
T.eq("an id given as text counts", #Devices.list({ exclude = { "740" } }), #devices - 1)

T.section("list: agents")
ShimSetDevices({
  [100] = { deviceName = "Lamp", roomName = "Office", variables = { ["1"] = { name = "A" } } },
  [100001] = { variables = { ["2301"] = { name = "GLOBAL_LIMIT", value = "90" } } },
})
-- 100001 is in the shim's GetDevices, so take it out of the project's devices and leave it to the agent lookup.
local realGetDevices = C4.GetDevices
function C4:GetDevices(filter)
  local found = realGetDevices(self, filter)
  found[100001] = nil
  return found
end
agentsXml = table.concat({
  "<systemitems>",
  "<item><id>100002</id><name>Scheduler</name><type>9</type>",
  "<subitems><item><id>9</id><name>A child</name></item></subitems></item>",
  "<item><id>100003</id><name>Announcements</name><type>9</type></item>",
  "<item><id>100004</id><name></name></item>",
  "</systemitems>",
})
local shimVariables = C4.GetDeviceVariables
function C4:GetDeviceVariables(deviceId)
  if tonumber(deviceId) == 100002 then
    return { ["1"] = { name = "NEXT_EVENT", value = "07:00" } }
  end
  return shimVariables(self, deviceId)
end
devices = Devices.list()
T.eq("agents follow the devices, in their own section", labels(devices), {
  "Office > Lamp",
  "Agents > Scheduler",
  "Agents > Variables",
})
T.eq("an agent's section is Agents", devices[2].section, "Agents")
T.eq("an agent is its own only member", devices[2].memberIds, { 100002 })
T.falsy("a child item is no agent", byId(devices, 9))
T.falsy("an agent without variables is left out", byId(devices, 100003))
all = Devices.list({ withoutVariables = true })
T.eq("unless asked for", byId(all, 100003).hasVariables, false)
T.falsy("an agent without a name is no agent", byId(all, 100004))
agentsXml = "<systemitems><item><id>100002</id><name>Scheduler</name></item></systemitems>"
T.truthy("one agent alone is read too", byId(Devices.list(), 100002))
T.eq(
  "an agent left out by exclude",
  labels(Devices.list({ exclude = { 100002 } })),
  { "Office > Lamp", "Agents > Variables" }
)
ShimSetDevices({ [100] = { deviceName = "Lamp", roomName = "Office", variables = { ["1"] = { name = "A" } } } })
T.falsy("Variables is listed only while it has variables", byId(Devices.list({ withoutVariables = true }), 100001))
ShimSetDevices({
  [100] = { deviceName = "Lamp", roomName = "Office", variables = { ["1"] = { name = "A" } } },
  [100001] = { variables = { ["2301"] = { name = "GLOBAL_LIMIT", value = "90" } } },
})
C4.GetDevices = realGetDevices
devices = Devices.list()
T.eq("an agent the project already lists as a device is not listed twice", byId(devices, 100001).section, "Devices")
T.eq("once", #devices, 3)
local warned = 0
log.warn = function()
  warned = warned + 1
end
function C4:GetProjectItems()
  error("no project")
end
T.eq("agents that cannot be read leave the devices", labels(Devices.list()), { " > Device 100001", "Office > Lamp" })
T.eq("with a warning", warned, 1)
log.warn = nil
C4.GetDeviceVariables = shimVariables

T.section("variables")
ShimSetDevices({
  [700] = {
    deviceName = "Light",
    roomName = "Hall",
    proxies = { [701] = true },
    variables = {
      ["5"] = { name = "OWN", value = "on" },
      ["4"] = { name = "BRIGHT", value = "café", type = "STRING" },
    },
  },
  [701] = {
    deviceName = "Light",
    roomName = "Hall",
    driverFileName = "light_v2.c4i",
    variables = { ["2"] = { name = "LEVEL", value = "40", type = "NUMBER" }, ["3"] = { name = "EMPTY" } },
  },
})
local vars = Devices.variables("700")
T.eq(
  "its own first, by name, then its proxy's",
  { vars[1].name, vars[2].name, vars[3].name, vars[4].name },
  { "BRIGHT", "OWN", "EMPTY", "LEVEL" }
)
T.eq("its own under Device", vars[1].section, "Device")
T.eq("a proxy's under its .c4i", vars[3].section, "light_v2")
T.eq("each names the member owning it", { vars[1].deviceId, vars[3].deviceId }, { 700, 701 })
T.eq("with a numeric id", vars[4].id, 2)
T.eq("a type is defaulted", vars[3].type, "STRING")
T.eq("a value is kept as it is", vars[4].value, "40")
T.eq("and a missing one stays missing", vars[3].value, nil)
T.eq("an id that is not a number gives nothing", Devices.variables("x"), nil)
T.eq("nor does none", Devices.variables(nil), nil)
T.eq("an id not in the project gives no variables", Devices.variables(999), {})

T.section("variables: values cut on a whole character")
local cut = Devices.variables(700, { valueBytes = 4 })
T.eq("a value that fits is kept", cut[2].value, "on")
T.eq("a missing value is empty text", cut[3].value, "")
T.eq("a character the cut splits is dropped", cut[1].value, "caf")
local function cutTo(value, bytes)
  ShimSetDevices({ [1] = { deviceName = "T", variables = { ["1"] = { name = "V", value = value } } } })
  return Devices.variables(1, { valueBytes = bytes })[1].value
end
T.eq("a two-byte character split is dropped", cutTo("café!", 4), "caf")
T.eq("and kept when it ends the cut", cutTo("café!", 5), "café")
T.eq("a three-byte one split after one byte", cutTo("a日b", 2), "a")
T.eq("or after two", cutTo("a日b", 3), "a")
T.eq("kept whole", cutTo("a日b", 4), "a日")
T.eq("a four-byte one split after three", cutTo("a💡b", 4), "a")
T.eq("kept whole", cutTo("a💡b", 5), "a💡")
T.eq("a number becomes text", cutTo(12345, 3), "123")

T.section("serve")
ShimSetDevices({
  [700] = {
    deviceName = "Light",
    roomName = "Hall",
    proxies = { [701] = true },
    variables = { ["1"] = { name = "OWN" } },
  },
  [701] = {
    deviceName = "Light",
    roomName = "Hall",
    driverFileName = "light_v2.c4i",
    variables = { ["2"] = { name = "LEVEL", value = "a long value" } },
  },
  [800] = { deviceName = "Self", roomName = "Hall", variables = { ["1"] = { name = "LOOK" } } },
})
function C4:GetProjectItems()
  return "<systemitems></systemitems>"
end
Devices.serve({ exclude = { 800 }, valueBytes = 6 })
UIR._GET_DEVICES()
T.eq("the list goes as DEVICES_DATA", sent[1].command, "DEVICES_DATA")
T.eq("with the options applied", #sent[1].data.devices, 1)
T.eq("each entry whole", sent[1].data.devices[1].memberIds, { 700, 701 })
sent = {}
UIR._GET_DEVICE_VARIABLES(pageBody({ deviceId = 700 }))
T.eq("variables go as DEVICE_VARIABLES_DATA", sent[1].command, "DEVICE_VARIABLES_DATA")
T.eq("naming the device as text", sent[1].data.deviceId, "700")
T.eq("with its variables", #sent[1].data.variables, 2)
T.eq("cut to the options' length", sent[1].data.variables[2].value, "a long")
sent = {}
UIR._GET_DEVICE_VARIABLES(pageBody({ deviceId = "nope" }))
T.eq("an id that is not a number is still answered", sent[1].command, "DEVICE_VARIABLES_DATA")
T.eq("with no device", sent[1].data.deviceId, "")
T.eq("and no variables", sent[1].data.variables, {})
sent = {}
UIR._GET_DEVICE_VARIABLES({ DATA = "not base64 json" })
T.eq("so is a body that does not decode", sent[1].data.deviceId, "")
sent = {}
UIR._GET_DEVICE_VARIABLES(pageBody({ deviceId = 999 }))
T.eq("an id not in the project gets no variables", sent[1].data.variables, {})

T.section("serve: wrap")
local licensed, wrapped = false, 0
Devices.serve({
  wrap = function(handler)
    wrapped = wrapped + 1
    return function(...)
      if licensed then
        return handler(...)
      end
    end
  end,
})
T.eq("wrap is given both handlers", wrapped, 2)
sent = {}
UIR._GET_DEVICES()
UIR._GET_DEVICE_VARIABLES(pageBody({ deviceId = 700 }))
T.eq("and stands in front of them", #sent, 0)
licensed = true
UIR._GET_DEVICES()
UIR._GET_DEVICE_VARIABLES(pageBody({ deviceId = 700 }))
T.eq(
  "passing them on when it lets them",
  { sent[1].command, sent[2].command },
  { "DEVICES_DATA", "DEVICE_VARIABLES_DATA" }
)
T.eq("without the other options", #sent[1].data.devices, 2)

T.section("page.cut keeps every whole character that fits")
local cut = require("lib.ui.page").cut
T.eq("a two-byte character that fits stays", cut("a\195\169b", 3), "a\195\169")
T.eq("a three-byte one too", cut("ab\226\130\172c", 5), "ab\226\130\172")
T.eq("one cut through goes", cut("ab\226\130\172c", 4), "ab")
T.eq("no limit, no cut", cut("abc", nil), "abc")

T.finish()
