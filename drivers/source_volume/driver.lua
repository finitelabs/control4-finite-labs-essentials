--- Source Volume Driver
--#ifndef DRIVERCENTRAL
DRIVER_GITHUB_REPO = "finitelabs/control4-finite-labs-essentials"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local values = require("lib.values")
local persist = require("lib.persist")
local constants = require("constants")
local Tracker = require("source_volume.tracker")
local updateSettings = require("lib.update-settings")
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

--- Whether the driver may act: a DriverCentral build stops while it has no license, and an OSS build never does.
--- @return boolean
local function licensed()
  local ok = true
  --#ifdef DRIVERCENTRAL
  ok = drivercentral:licensed()
  --#endif
  return ok
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- The room variables the driver watches.
local VAR_SELECTED_DEVICE = 1000
local VAR_POWER_STATE = 1010
local VAR_CURRENT_VOLUME = 1011
local VAR_VOLUME_DEVICE = 1015
local VAR_HAS_DISCRETE_VOLUME = 1016
local VAR_USE_DEFAULT_VOLUMES = 1020

--- @type integer[]
local ROOM_VARIABLES = {
  VAR_SELECTED_DEVICE,
  VAR_POWER_STATE,
  VAR_CURRENT_VOLUME,
  VAR_VOLUME_DEVICE,
  VAR_HAS_DISCRETE_VOLUME,
  VAR_USE_DEFAULT_VOLUMES,
}

--- How many volume groups driver.xml has: one for each of the old Source slots, so their picks always move whole.
--- @type integer
local GROUPS = 8

--- How many hidden Source slots driver.xml keeps from earlier builds. Director drops a property's value once
--- driver.xml no longer has it, so they stay until every install has moved its picks into the groups.
--- @type integer
local SLOTS = 8

--- A room writes its variables one at a time, and Control4's default volumes land after the source does. The room
--- is read once it has been quiet this long.
--- @type integer
local SETTLE_MS = 2 * ONE_SECOND

local PERSIST_STATE = "VolumeState"
local PERSIST_GROUPS = "VolumeGroups"

local CHECKED = "[X] "
local UNCHECKED = "[  ] "

local EVENT_FIXED = "Fixed Volume Set"
local EVENT_RESTORED = "Volume Restored"

local VAR_ACTIVE = "Fixed Volume Active"
local VAR_SAVED = "Saved Volume"

--- The settings Reset Driver returns to their defaults.
--- @type table<string, string>
local SETTING_DEFAULTS = { ["Volume Control"] = "Enabled" }
for group = 1, GROUPS do
  SETTING_DEFAULTS["Group " .. group .. " Volume"] = "50"
end
for slot = 1, SLOTS do
  SETTING_DEFAULTS["Source " .. slot] = constants.SELECT_OPTION
  SETTING_DEFAULTS["Source " .. slot .. " Volume"] = "50"
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

--- The tracker's state, stored whole.
--- @type table
local state = Tracker.new()

--- The room whose variables are watched, nil before the first watch.
--- @type integer|nil
local watchedRoom = nil

--- A problem the last changes reported, shown in Room Status until the room's source changes.
--- @type string|nil
local notice = nil

--- The source the room showed at the last read.
--- @type integer|nil
local lastSource = nil

--- The stored state as last written, to skip writing it again unchanged.
--- @type string|nil
local lastStored = nil

--- Each group's checked sources, in the order they were checked. A source is in one group at most.
--- @type integer[][]
local groups = {}

--------------------------------------------------------------------------------
-- Settings and the Room
--------------------------------------------------------------------------------

--- The time, in seconds.
--- @return number now
local function now()
  return os.time()
end

--- The source a "Name (id)" option names; nil for any other value.
--- @param option string|nil
--- @return integer|nil
local function optionSource(option)
  return tointeger(string.match(option or "", "%((%d+)%)$"))
end

--- The groups with no source checked.
--- @return integer[][]
local function emptyGroups()
  local empty = {}
  for group = 1, GROUPS do
    empty[group] = {}
  end
  return empty
end

--- Write the groups.
local function saveGroups()
  persist:set(PERSIST_GROUPS, groups)
end

--- The group a source is checked in, nil when it is in none.
--- @param id integer
--- @return integer|nil
local function groupOf(id)
  for group = 1, GROUPS do
    for _, checked in ipairs(groups[group]) do
      if checked == id then
        return group
      end
    end
  end
  return nil
end

--- The tracker's settings: each checked source at its group's volume.
--- @return SourceVolumeSettings settings
local function settings()
  local sources = {}
  for group = 1, GROUPS do
    local level = tointeger(Properties["Group " .. group .. " Volume"]) or 50
    for _, id in ipairs(groups[group]) do
      sources[id] = level
    end
  end
  return { enabled = Properties["Volume Control"] ~= "Disabled", sources = sources }
end

--- Move the picks of earlier builds' Source slots into the groups, once: one group for each level, in slot order. The
--- slots are cleared, and the groups are stored even when empty, so this never runs again.
local function migrateSlots()
  if persist:get(PERSIST_GROUPS) ~= nil then
    return
  end
  groups = emptyGroups()
  local levels, used = {}, 0
  for slot = 1, SLOTS do
    local id = optionSource(Properties["Source " .. slot])
    if id and id > 0 and groupOf(id) == nil then
      local level = tointeger(Properties["Source " .. slot .. " Volume"]) or 50
      local group = levels[level]
      if group == nil then
        used = used + 1
        group = used
        levels[level] = group
        UpdateProperty("Group " .. group .. " Volume", tostring(level))
      end
      table.insert(groups[group], id)
      log:info("Moved Source %d, %s at %d, into Group %d", slot, GetDeviceDisplayNameOrId(id), level, group)
    end
    UpdateProperty("Source " .. slot, constants.SELECT_OPTION)
    UpdateProperty("Source " .. slot .. " Volume", "50")
  end
  saveGroups()
end

--- A room variable, nil when the room has none.
--- @param id integer
--- @return string|nil
local function roomVariable(id)
  return C4:GetDeviceVariable(watchedRoom, id)
end

--- The room as its variables show it now.
--- @return SourceVolumeRoom room
local function readRoom()
  return {
    source = tointeger(roomVariable(VAR_SELECTED_DEVICE)) or 0,
    power = toboolean(roomVariable(VAR_POWER_STATE)),
    volume = tointeger(roomVariable(VAR_CURRENT_VOLUME)) or -1,
    volumeDevice = tointeger(roomVariable(VAR_VOLUME_DEVICE)) or 0,
    discrete = toboolean(roomVariable(VAR_HAS_DISCRETE_VOLUME)),
    useDefaults = toboolean(roomVariable(VAR_USE_DEFAULT_VOLUMES)),
  }
end

--- A device's name for the status and the log.
--- @param id integer|nil
--- @return string
local function deviceName(id)
  return GetDeviceDisplayNameOrId(id)
end

--- Write the state, when it changed.
local function saveState()
  local stored = JSON:encode(state)
  if stored ~= lastStored then
    persist:set(PERSIST_STATE, state)
    lastStored = stored
  end
end

--------------------------------------------------------------------------------
-- Status
--------------------------------------------------------------------------------

--- Show what the driver is doing in Room Status and its variables.
--- @param room SourceVolumeRoom|nil
local function showStatus(room)
  local current = settings()
  local saved = room and Tracker.savedLevel(state, room) or -1
  local status
  if not current.enabled then
    status = "Disabled"
  elseif IsEmpty(current.sources) then
    status = "No sources picked"
  elseif notice then
    status = notice
  elseif room == nil or not room.power or room.source == 0 then
    status = "Room is off"
    if saved >= 0 then
      status = status .. string.format(", will restore %d", saved)
    end
  elseif Tracker.isActive(state) then
    local fixed = current.sources[room.source]
    status = string.format("Holding %d for %s", fixed or room.volume, deviceName(room.source))
    if saved >= 0 then
      status = status .. string.format(", will restore %d", saved)
    end
  else
    status = "Not holding: " .. deviceName(room.source) .. " is not picked"
  end
  UpdateProperty("Room Status", status, true)
  values:update(VAR_ACTIVE, Tracker.isActive(state), "BOOL")
  values:update(VAR_SAVED, saved, "NUMBER")
end

--- Show each group once the one before it has a source, and never the old Source slots.
local function showGroups()
  local previousFilled = true
  for group = 1, GROUPS do
    local filled = not IsEmpty(groups[group])
    local attrib = (previousFilled or filled) and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY
    C4:SetPropertyAttribs("Group " .. group .. " Sources", attrib)
    C4:SetPropertyAttribs("Group " .. group .. " Volume", attrib)
    previousFilled = filled
  end
  for slot = 1, SLOTS do
    C4:SetPropertyAttribs("Source " .. slot, constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Source " .. slot .. " Volume", constants.HIDE_PROPERTY)
  end
end

--- @class SourceVolumeSource
--- @field id integer
--- @field name string
--- @field room string|nil The device's own room.

--- Add a room's watch and listen sources not yet seen. Like the room's own lists, less the special audio entries,
--- the digital audio clients and the music library drivers, which are never a source that plays.
--- @param room integer
--- @param found SourceVolumeSource[]
--- @param seen table<integer, boolean>
local function addRoomSources(room, found, seen)
  for _, command in ipairs({ "GET_WATCH_DEVICES", "GET_LISTEN_DEVICES" }) do
    local sources = Select(ParseXml(SendToDevice(room, command, {})), "sources", "source")
    if not IsList(sources) then
      sources = { sources }
    end
    for _, source in ipairs(sources) do
      local id = tointeger(Select(source, "id"))
      local kind = Select(source, "type")
      local device = id and not seen[id] and GetDevice(id)
      if device and kind ~= "SPECIAL_AUDIO" and kind ~= "DIGITAL_AUDIO_CLIENT" then
        local library = false
        for _, protocol in pairs(device.protocol or {}) do
          library = library or protocol.driverFileName == "AddMusic.c4z" or protocol.driverFileName == "MyMusic.c4z"
        end
        if not library then
          seen[id] = true
          table.insert(found, { id = id, name = tostring(device.deviceName), room = device.roomName })
        end
      end
    end
  end
end

--- Every room's sources, each once: the watched room's own first, in its order, then the rest by room and name. A room that
--- joins another room's session plays that room's source, which its own lists may not hold.
--- @return SourceVolumeSource[]
local function projectSources()
  local found, seen = {}, {}
  addRoomSources(watchedRoom, found, seen)
  local others = {}
  for id in pairs(C4:GetDevicesByC4iName("roomdevice.c4i") or {}) do
    id = tointeger(id)
    if id and id ~= watchedRoom then
      addRoomSources(id, others, seen)
    end
  end
  table.sort(others, function(a, b)
    if (a.room or "") ~= (b.room or "") then
      return (a.room or "") < (b.room or "")
    end
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.id < b.id
  end)
  for _, source in ipairs(others) do
    table.insert(found, source)
  end
  return found
end

--- The group lists as last filled, to skip filling them again unchanged.
--- @type string|nil
local lastLists = nil

--- Fill each group's list with every room's sources as Room > Name, checked where the group holds them. A checked
--- source no room lists any more stays, so it can still be unchecked.
--- @param force boolean|nil Fill the lists even when unchanged, to put a picked option back to (Select).
local function updateSourceLists(force)
  local sources = projectSources()
  local listed = {}
  for _, source in ipairs(sources) do
    listed[source.id] = true
  end
  for group = 1, GROUPS do
    for _, id in ipairs(groups[group]) do
      if not listed[id] then
        listed[id] = true
        table.insert(sources, { id = id, name = GetDeviceDisplayNameOrId(id) })
      end
    end
  end
  local labels = {}
  for i, source in ipairs(sources) do
    local label = IsEmpty(source.room) and source.name or (source.room .. " > " .. source.name)
    -- A comma would split the option in two.
    labels[i] = string.format("%s (%d)", (label:gsub(",", "")), source.id)
  end
  local lists = {}
  for group = 1, GROUPS do
    local options = { constants.SELECT_OPTION, constants.REFRESH_LIST_OPTION }
    for i, source in ipairs(sources) do
      table.insert(options, (groupOf(source.id) == group and CHECKED or UNCHECKED) .. labels[i])
    end
    lists[group] = table.concat(options, ",")
  end
  local filled = table.concat(lists, "|")
  if filled == lastLists and not force then
    return
  end
  lastLists = filled
  for group = 1, GROUPS do
    C4:UpdatePropertyList("Group " .. group .. " Sources", lists[group], constants.SELECT_OPTION)
  end
end

--------------------------------------------------------------------------------
-- Acting on the Room
--------------------------------------------------------------------------------

local evaluate

--- Send, fire and report what the tracker changed.
--- @param changes SourceVolumeChange[]
--- @param room SourceVolumeRoom
local function apply(changes, room)
  for _, change in ipairs(changes) do
    if change.type == Tracker.Change.SET then
      log:info("Setting %s's volume to %d", deviceName(watchedRoom), change.level)
      SendToDevice(watchedRoom, "SET_VOLUME_LEVEL", { LEVEL = tostring(change.level) })
    elseif change.type == Tracker.Change.FIXED then
      notice = nil
      C4:FireEvent(EVENT_FIXED)
    elseif change.type == Tracker.Change.RESTORED then
      notice = nil
      C4:FireEvent(EVENT_RESTORED)
    elseif change.type == Tracker.Change.UNSETTABLE then
      notice = "This room's volume can't be set to a level"
      log:warn("%s: %s, so %s is left alone", deviceName(watchedRoom), notice, deviceName(change.source))
    elseif change.type == Tracker.Change.MISSED then
      notice = string.format("Volume %d was sent but didn't arrive", change.level)
      log:warn("%s: %s", deviceName(watchedRoom), notice)
    end
  end
  if state.sent then
    -- Nothing may change in the room when a level is lost, so the tracker is asked again once the wait is over.
    SetTimer("Follow", (Tracker.CONFIRM_SECONDS + 1) * ONE_SECOND, function()
      evaluate()
    end)
  end
  saveState()
  showStatus(room)
end

--- Watch the room the driver is in. A move to another room forgets what the old room had saved.
local function watchRoom()
  local room = C4:RoomGetId()
  if room == watchedRoom then
    return
  end
  if watchedRoom ~= nil then
    for _, id in ipairs(ROOM_VARIABLES) do
      UnregisterVariableListener(watchedRoom, id)
    end
    Tracker.forget(state)
    saveState()
  end
  watchedRoom = room
  for _, id in ipairs(ROOM_VARIABLES) do
    RegisterVariableListener(room, id, function()
      SetTimer("Settle", SETTLE_MS, function()
        evaluate()
      end)
    end)
  end
  updateSourceLists()
end

--- Read the room and act on it.
evaluate = function()
  if not gInitialized or not licensed() then
    return
  end
  watchRoom()
  local room = readRoom()
  if room.source ~= lastSource then
    notice = nil
    lastSource = room.source
    -- A source added to any room since the last read shows in the lists at once.
    updateSourceLists()
  end
  apply(Tracker.update(state, settings(), room, now()), room)
end

--- Create the variables, in their fixed order, with what the state holds.
local function createVariables()
  values:update(VAR_ACTIVE, Tracker.isActive(state), "BOOL")
  -- A restored level stands until the room is read, so a start tells programming nothing new.
  if values:getValue(VAR_SAVED) == nil then
    values:update(VAR_SAVED, -1, "NUMBER")
  end
end

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
--#endif

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  drivercentral:startClient()
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  values:restoreValues()

  local stored = persist:get(PERSIST_STATE)
  state = Tracker.new()
  if type(stored) == "table" then
    for key, value in pairs(stored) do
      state[key] = value
    end
  end
  lastStored = JSON:encode(state)
  groups = emptyGroups()
  local storedGroups = persist:get(PERSIST_GROUPS)
  for group = 1, GROUPS do
    for _, id in ipairs(Select(storedGroups, group) or {}) do
      table.insert(groups[group], tointeger(id))
    end
  end
  watchedRoom = nil
  notice = nil
  lastSource = nil
  lastLists = nil

  createVariables()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")

  if not CheckMinimumVersion("Driver Status") then
    return
  end

  migrateSlots()

  -- The router runs each handler in its own xpcall and reports its error, so the rest still run.
  for p, _ in pairs(Properties) do
    OnPropertyChanged(p)
  end

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
  -- Watched before the license check, so the group lists fill in either way.
  watchRoom()
  showGroups()
  UpdateProperty("Driver Status", "Ready")
  -- Acts on the room at once; the values the new listeners deliver start one more read once the room is quiet.
  evaluate()

  --#ifdef DRIVERCENTRAL
  drivercentral:startGate(function(active)
    if not active then
      CancelTimer("Settle")
      CancelTimer("Follow")
      UpdateProperty("Driver Status", drivercentral.UNLICENSED_STATUS)
      return
    end
    UpdateProperty("Driver Status", "Ready")
    evaluate()
  end)
  --#endif
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

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
end

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  if not gInitialized then
    return
  end
  updateSettings:share("Automatic Updates", propertyValue, { "source_volume.c4z" })
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if not gInitialized then
    return
  end
  updateSettings:share("Update Channel", propertyValue, { "source_volume.c4z" })
end
--#endif

--- An update setting changed on another item.
function EC.SET_UPDATE_SETTING(params)
  log:trace("EC.SET_UPDATE_SETTING(%s)", params)
  updateSettings:take(params)
end

--#ifdef DRIVERCENTRAL
--- Not logged: the value is the code.
function OPC.Support_Code(propertyValue)
  supportCode:enter(propertyValue)
end

--- Turns Cloud Monitoring on or off.
--- @param propertyValue string
function OPC.Cloud_Monitoring(propertyValue)
  diagnostics:setEnabled(propertyValue == "Enabled")
end

--- Prints a diagnostics report, and sends it while Cloud Monitoring is on.
function EC.DiagnosticsSnapshot()
  diagnostics:dumpSnapshot()
end
--#endif

function OPC.Volume_Control(propertyValue)
  log:trace("OPC.Volume_Control('%s')", propertyValue)
  notice = nil
  evaluate()
end

for group = 1, GROUPS do
  --- Check or uncheck the picked source in this group. A source checked here leaves any other group.
  OPC["Group_" .. group .. "_Sources"] = function(propertyValue)
    log:trace("OPC.Group_%d_Sources('%s')", group, propertyValue)
    -- A start replays the stored value, which must not toggle a source again.
    if not gInitialized then
      return
    end
    local id = optionSource(propertyValue)
    if id ~= nil then
      local wasHere = groupOf(id) == group
      for other = 1, GROUPS do
        for i = #groups[other], 1, -1 do
          if groups[other][i] == id then
            table.remove(groups[other], i)
          end
        end
      end
      if not wasHere then
        table.insert(groups[group], id)
      end
      saveGroups()
      showGroups()
    end
    if id ~= nil or propertyValue == constants.REFRESH_LIST_OPTION then
      updateSourceLists(true)
      evaluate()
    end
  end
  OPC["Group_" .. group .. "_Volume"] = function(propertyValue)
    log:trace("OPC.Group_%d_Volume('%s')", group, propertyValue)
    evaluate()
  end
end

--------------------------------------------------------------------------------
-- TC Handlers
--------------------------------------------------------------------------------

function TC.FIXED_VOLUME_ACTIVE(_strConditionName, tParams)
  local test = Select(tParams, "VALUE") == "Active"
  if Select(tParams, "LOGIC") == "NOT_EQUAL" then
    return test ~= Tracker.isActive(state)
  end
  return test == Tracker.isActive(state)
end

--------------------------------------------------------------------------------
-- EC Handlers
--------------------------------------------------------------------------------

--- Turn volume control on: the Volume Control property's twin.
function EC.Enable_Volume_Control(params)
  log:trace("EC.Enable_Volume_Control(%s)", params)
  UpdateProperty("Volume Control", "Enabled", true)
end

--- Turn volume control off: the Volume Control property's twin.
function EC.Disable_Volume_Control(params)
  log:trace("EC.Disable_Volume_Control(%s)", params)
  UpdateProperty("Volume Control", "Disabled", true)
end

--- Reset driver to initial state
function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")

  CancelTimer("Settle")
  CancelTimer("Follow")
  values:reset()
  persist:set(PERSIST_STATE, nil)
  state = Tracker.new()
  lastStored = nil
  notice = nil
  lastSource = nil
  lastLists = nil
  groups = emptyGroups()
  saveGroups()

  local resetValues = GetPropertyResetValues({})
  for propName, defaultValue in pairs(resetValues) do
    UpdateProperty(propName, defaultValue, true)
  end
  for propName, defaultValue in pairs(SETTING_DEFAULTS) do
    UpdateProperty(propName, defaultValue)
  end
  --#ifdef DRIVERCENTRAL
  UpdateProperty("Cloud Monitoring", "Enabled", true)
  --#endif

  createVariables()
  showGroups()
  evaluate()
end

--#ifndef DRIVERCENTRAL
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
    :updateAll(DRIVER_GITHUB_REPO, { "source_volume.c4z" }, Properties["Update Channel"] == "Prerelease", forceUpdate)
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
