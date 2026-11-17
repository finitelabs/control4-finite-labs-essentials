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

--- How many Source slots driver.xml has.
--- @type integer
local SLOTS = 8

--- A room writes its variables one at a time, and Control4's default volumes land after the source does. The room
--- is read once it has been quiet this long.
--- @type integer
local SETTLE_MS = 2 * ONE_SECOND

local PERSIST_STATE = "VolumeState"

local EVENT_FIXED = "Fixed Volume Set"
local EVENT_RESTORED = "Volume Restored"

local VAR_ACTIVE = "Fixed Volume Active"
local VAR_SAVED = "Saved Volume"

--- The settings Reset Driver returns to their defaults.
--- @type table<string, string>
local SETTING_DEFAULTS = { ["Volume Control"] = "Enabled" }
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

--------------------------------------------------------------------------------
-- Settings and the Room
--------------------------------------------------------------------------------

--- The time, in seconds.
--- @return number now
local function now()
  return os.time()
end

--- The source a slot holds, read from its "Name (id)" option; nil while it holds none.
--- @param slot integer
--- @return integer|nil
local function slotSource(slot)
  return tointeger(string.match(Properties["Source " .. slot] or "", "%((%d+)%)$"))
end

--- The tracker's settings as the properties give them. A source picked in two slots keeps its first level.
--- @return SourceVolumeSettings settings
local function settings()
  local sources = {}
  for slot = 1, SLOTS do
    local id = slotSource(slot)
    if id and id > 0 and sources[id] == nil then
      sources[id] = tointeger(Properties["Source " .. slot .. " Volume"]) or 50
    end
  end
  return { enabled = Properties["Volume Control"] ~= "Disabled", sources = sources }
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

--- Show each Source slot once the one before it is filled. A hidden slot keeps its value.
local function showSlots()
  local previousFilled = true
  for slot = 1, SLOTS do
    local filled = slotSource(slot) ~= nil
    local shown = previousFilled or filled
    local attrib = shown and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY
    C4:SetPropertyAttribs("Source " .. slot, attrib)
    C4:SetPropertyAttribs("Source " .. slot .. " Volume", attrib)
    previousFilled = filled
  end
end

--- The room's watch and listen sources, each once. Like the room's own lists, less the special audio entries,
--- the digital audio clients and the music library drivers, which are never a source that plays.
--- @param room integer
--- @return { id: integer, name: string }[]
local function roomSources(room)
  local found, seen = {}, {}
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
          table.insert(found, { id = id, name = device.deviceName })
        end
      end
    end
  end
  return found
end

--- Fill each Source slot's list with the room's sources. A slot keeps a pick the room no longer lists.
local function updateSourceLists()
  local options = { constants.SELECT_OPTION }
  local listed = {}
  for _, source in ipairs(roomSources(watchedRoom)) do
    -- A comma would split the option in two.
    local option = string.format("%s (%d)", (tostring(source.name):gsub(",", "")), source.id)
    table.insert(options, option)
    listed[option] = true
  end
  for slot = 1, SLOTS do
    local name = "Source " .. slot
    local current = slotSource(slot) and Properties[name] or constants.SELECT_OPTION
    local list = table.concat(options, ",")
    if not listed[current] and current ~= constants.SELECT_OPTION then
      list = list .. "," .. current
    end
    C4:UpdatePropertyList(name, list, current)
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
    -- A source added to the room shows in the lists once the room's source next changes.
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
  watchedRoom = nil
  notice = nil
  lastSource = nil

  createVariables()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")

  if not CheckMinimumVersion("Driver Status") then
    return
  end

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
  -- Watched before the license check, so the Source lists fill in either way.
  watchRoom()
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

for slot = 1, SLOTS do
  OPC["Source_" .. slot] = function(propertyValue)
    log:trace("OPC.Source_%d('%s')", slot, propertyValue)
    showSlots()
    evaluate()
  end
  OPC["Source_" .. slot .. "_Volume"] = function(propertyValue)
    log:trace("OPC.Source_%d_Volume('%s')", slot, propertyValue)
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
  showSlots()
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
