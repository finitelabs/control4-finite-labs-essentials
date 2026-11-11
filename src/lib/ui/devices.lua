--- The project's devices, agents and variables, for a web tab's variable browser: lib/ui/variables.js lists them,
--- the integrator searches them, and a pick inserts a `PARAM{device,variable}` token.
---
--- The browser speaks this once the driver calls `serve()`: it sends `_GET_DEVICES` and gets DEVICES_DATA,
--- `{ devices = list() }`; it sends `_GET_DEVICE_VARIABLES` with `{ deviceId }` and gets DEVICE_VARIABLES_DATA,
--- `{ deviceId, variables = variables(deviceId) }`.

require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("lib.utils")

local log = require("lib.logging")
local page = require("lib.ui.page")
local pageParams = require("lib.ui.page-params")

--- Agents Director exposes that no GetProjectItems filter lists, kept only when they resolve variables, so a dead id
--- leaves no entry.
--- @type table<integer, string>
local SYSTEM_AGENTS = { [100001] = "Variables" }

--- Devices before agents, so the browser's groups keep one order.
local SECTION_RANK = { Devices = 1, Agents = 2 }

--- @class DeviceEntry
--- @field id integer The entry's device: a driver stands for the proxies that restate it.
--- @field name string Its name, with ` (id)` when another entry in its room has the same one.
--- @field roomName string Its room, "" for none, or "Agents" for an agent.
--- @field section string "Devices" or "Agents".
--- @field hasVariables boolean Whether any of its members has a variable.
--- @field memberIds integer[] The driver and the proxies restating it, by id.

--- @class DeviceVariable
--- @field id integer
--- @field deviceId integer The member that owns it, which a token names.
--- @field section string "Device" for the entry's own, else the restating proxy's .c4i name.
--- @field order integer The member's place in the entry, its own first.
--- @field name string
--- @field type string
--- @field value any Its value, as text cut to `valueBytes` when that is given.

--- @class DevicesOptions
--- @field exclude? integer[] Entries left out of the list, by the id of any of their members.
--- @field withoutVariables? boolean Lists the entries that have no variable too, each with `hasVariables` false.
--- @field valueBytes? integer Cuts each variable's value to at most this many bytes, on a whole character.
--- @field wrap? fun(handler: function): function Wraps both of `serve`'s handlers, as a license gate needs.

local Devices = {}

--- Whether a proxy merely restates the device that declares it. A proxy named for itself, such as a security
--- panel's areas, stays its own entry.
--- @param proxy table|nil
--- @param owner table
--- @return boolean
local function isRestatedProxy(proxy, owner)
  return proxy ~= nil and tostring(proxy.deviceName) == tostring(owner.deviceName)
end

--- The heading a member's variables sit under, taken from the proxy's .c4i.
--- @param dev table|nil
--- @param isOwner boolean
--- @return string
local function proxySectionLabel(dev, isOwner)
  if isOwner then
    return "Device"
  end
  local file = tostring((dev or {}).driverFileName or "")
  local base = file:match("^(.*)%.c4i$") or file:match("^(.*)%.c4z$")
  return IsEmpty(base) and "Proxy" or base
end

--- @param id integer
--- @return boolean
local function hasVariables(id)
  local ok, variables = pcall(C4.GetDeviceVariables, C4, id)
  return ok and type(variables) == "table" and next(variables) ~= nil
end

--- @param ids integer[]|nil
--- @return table<integer, boolean>
local function idSet(ids)
  local set = {}
  for _, id in ipairs(ids or {}) do
    local number = tonumber(id)
    if number then
      set[number] = true
    end
  end
  return set
end

--- The project's agents, absent from C4:GetDevices(), read on each call so one added since shows at once.
--- @return table<integer, string> agents id -> name
local function projectAgents()
  local agents = {}
  for id, name in pairs(SYSTEM_AGENTS) do
    if hasVariables(id) then
      agents[id] = name
    end
  end
  -- Parsed, not pattern-matched: items nest, so a non-greedy <item>(.-)</item> ends at a child's close tag.
  local ok, items = pcall(function()
    return Select(ParseXml(C4:GetProjectItems("AGENTS")), "systemitems", "item")
  end)
  if not ok then
    log:warn("The project's agents could not be read: %s", items)
    return agents
  end
  if items ~= nil and not IsList(items) then
    items = { items }
  end
  for _, item in ipairs(items or {}) do
    local id = type(item) == "table" and tointeger(item.id) or nil
    if id and type(item.name) == "string" and item.name ~= "" then
      agents[id] = item.name
    end
  end
  return agents
end

--- Orders entries by section, then room and name ignoring case, then id.
--- @param a DeviceEntry
--- @param b DeviceEntry
--- @return boolean
local function before(a, b)
  local rankA, rankB = SECTION_RANK[a.section] or 9, SECTION_RANK[b.section] or 9
  if rankA ~= rankB then
    return rankA < rankB
  end
  local roomA, roomB = a.roomName:lower(), b.roomName:lower()
  if roomA ~= roomB then
    return roomA < roomB
  end
  local nameA, nameB = a.name:lower(), b.name:lower()
  if nameA ~= nameB then
    return nameA < nameB
  end
  return a.id < b.id
end

--- The project's devices and agents for a page to pick from. A driver and the proxies that restate it are separate
--- project items sharing a room and name, so they are one entry; a name still not unique in its room gets the id.
--- @param options? DevicesOptions
--- @return DeviceEntry[] devices Devices first, then agents, each by room and name.
function Devices.list(options)
  log:trace("Devices.list()")
  options = options or {}
  local excluded = idSet(options.exclude)
  local allDevices = C4:GetDevices() or {}

  -- Proxy id -> owning driver id, for proxies that only restate their owner.
  local ownerOf = {}
  for id, dev in pairs(allDevices) do
    for proxyId in pairs(dev.proxies or {}) do
      local pid = tonumber(proxyId) or proxyId
      if isRestatedProxy(allDevices[pid], dev) then
        ownerOf[pid] = id
      end
    end
  end

  -- Collapse chains so a proxy of a proxy still lands in an entry.
  local rootOf, membersOf = {}, {}
  for id in pairs(allDevices) do
    local root, seen = id, { [id] = true }
    while ownerOf[root] ~= nil and not seen[ownerOf[root]] do
      root = ownerOf[root]
      seen[root] = true
    end
    rootOf[id] = root
    membersOf[root] = membersOf[root] or {}
    table.insert(membersOf[root], id)
  end

  local devices, listed = {}, {}
  for id, dev in pairs(allDevices) do
    if rootOf[id] == id then
      local memberIds = membersOf[id]
      table.sort(memberIds)
      local kept, withVariables = true, false
      for _, memberId in ipairs(memberIds) do
        listed[memberId] = true
        kept = kept and not excluded[memberId]
      end
      for _, memberId in ipairs(kept and memberIds or {}) do
        if hasVariables(memberId) then
          withVariables = true
          break
        end
      end
      if kept and (withVariables or options.withoutVariables) then
        devices[#devices + 1] = {
          id = id,
          name = tostring(dev.deviceName or ("Device " .. id)),
          roomName = tostring(dev.roomName or ""),
          section = "Devices",
          hasVariables = withVariables,
          memberIds = memberIds,
        }
      end
    end
  end

  -- "Agents" stands in as their room, so the browser groups them as it groups a room.
  for id, name in pairs(projectAgents()) do
    if not listed[id] and not excluded[id] then
      local withVariables = hasVariables(id)
      if withVariables or options.withoutVariables then
        devices[#devices + 1] = {
          id = id,
          name = name,
          roomName = "Agents",
          section = "Agents",
          hasVariables = withVariables,
          memberIds = { id },
        }
      end
    end
  end

  local labelCounts = {}
  for _, d in ipairs(devices) do
    local label = d.section .. "\0" .. d.roomName .. "\0" .. d.name
    labelCounts[label] = (labelCounts[label] or 0) + 1
  end
  for _, d in ipairs(devices) do
    if labelCounts[d.section .. "\0" .. d.roomName .. "\0" .. d.name] > 1 then
      d.name = string.format("%s (%s)", d.name, d.id)
    end
  end
  table.sort(devices, before)
  return devices
end

--- An entry's variables for a page to pick from: its own first, then those of the proxies that restate it.
--- @param deviceId integer|string|nil The entry's id.
--- @param options? DevicesOptions
--- @return DeviceVariable[]|nil variables Nil when the id is not a number.
function Devices.variables(deviceId, options)
  log:trace("Devices.variables(%s)", deviceId)
  options = options or {}
  local devId = tonumber(deviceId)
  if not devId then
    return nil
  end

  local entry = (C4:GetDevices({ DeviceIds = tostring(devId) }) or {})[devId] or {}
  local members = { { id = devId, section = proxySectionLabel(entry, true), order = 1 } }
  local queue, seen = { { id = devId, dev = entry } }, { [devId] = true }
  while #queue > 0 do
    local cur = table.remove(queue, 1)
    -- pairs() over proxies has no defined order, and sections should not move between calls.
    local childIds = {}
    for proxyId in pairs((cur.dev or {}).proxies or {}) do
      childIds[#childIds + 1] = tonumber(proxyId) or proxyId
    end
    table.sort(childIds)
    for _, pid in ipairs(childIds) do
      local proxy = (C4:GetDevices({ DeviceIds = tostring(pid) }) or {})[pid]
      if not seen[pid] and isRestatedProxy(proxy, cur.dev) then
        seen[pid] = true
        members[#members + 1] = { id = pid, section = proxySectionLabel(proxy, false), order = #members + 1 }
        queue[#queue + 1] = { id = pid, dev = proxy }
      end
    end
  end

  local vars = {}
  for _, member in ipairs(members) do
    local ok, deviceVars = pcall(C4.GetDeviceVariables, C4, member.id)
    if ok and type(deviceVars) == "table" then
      for varId, varInfo in pairs(deviceVars) do
        local value = varInfo.value
        if options.valueBytes then
          value = page.cut(value == nil and "" or tostring(value), options.valueBytes)
        end
        vars[#vars + 1] = {
          id = tonumber(varId),
          deviceId = member.id,
          section = member.section,
          order = member.order,
          name = varInfo.name or ("var" .. varId),
          type = varInfo.type or "STRING",
          value = value,
        }
      end
    end
  end
  -- Order on the member's place, not its label: a proxy's .c4i can be named Device, and LuaJIT's table.sort does
  -- not reject the cycle that tie makes.
  table.sort(vars, function(a, b)
    if a.order ~= b.order then
      return a.order < b.order
    end
    return a.name < b.name
  end)
  return vars
end

--- Answers the variable browser's two commands, always, so the page never waits on a bad id. Call it once, as the
--- driver loads.
--- @param options? DevicesOptions Passed on to `list` and `variables`.
function Devices.serve(options)
  options = options or {}
  local wrap = options.wrap or function(handler)
    return handler
  end
  UIR._GET_DEVICES = wrap(function()
    log:trace("UIR._GET_DEVICES()")
    page.send("DEVICES_DATA", { devices = Devices.list(options) })
  end)
  UIR._GET_DEVICE_VARIABLES = wrap(function(tParams)
    log:trace("UIR._GET_DEVICE_VARIABLES()")
    local deviceId = tonumber(pageParams(tParams).deviceId)
    page.send("DEVICE_VARIABLES_DATA", {
      deviceId = deviceId and tostring(deviceId) or "",
      variables = Devices.variables(deviceId, options) or {},
    })
  end)
end

return Devices
