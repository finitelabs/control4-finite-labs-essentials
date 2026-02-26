--- Light Relay Driver
--#ifdef DRIVERCENTRAL
DC_PID = nil
DC_X = nil
DC_FILENAME = "light_relay.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-finite-labs-essentials"
DRIVER_FILENAMES = { "light_relay.c4z" }
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local bindings = require("lib.bindings")
local persist = require("lib.persist")
local constants = require("constants")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Namespace for relay output bindings
local NS_RELAY = "Convert Lights To Relays"

--- Persist key for converted light device IDs
local PERSIST_CONVERTED_LIGHTS = "ConvertedLights"

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

  -- Restore persisted state
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Fire OnPropertyChanged for all properties
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    if toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver updates")
      UpdateDrivers()
    end
  end, true)
  --#endif

  gInitialized = true
  UpdateProperty("Driver Status", "Ready")
end

--------------------------------------------------------------------------------
-- Standard OPC Handlers
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
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
end
--#endif

--------------------------------------------------------------------------------
-- Light Relay Logic
--------------------------------------------------------------------------------

function OPC.Convert_Lights_To_Relays(propertyValue)
  log:trace("OPC.Convert_Lights_To_Relays('%s')", propertyValue)

  -- Get all previously configured light devices
  local previousLights = {}
  for deviceIdStr in string.gmatch(persist:get(PERSIST_CONVERTED_LIGHTS, ""), "(%d+)") do
    local deviceId = tointeger(deviceIdStr)
    previousLights[deviceId] = GetDevice(deviceId)
      or {
        deviceId = deviceId,
        deviceName = "Unknown Device " .. deviceId,
        displayName = "Unknown Device " .. deviceId,
      }
  end

  local currentLights = ParseDeviceIdPropertyList("Convert Lights To Relays", function(deviceId, device)
    -- Remove any lights that are still present in the list, leaving us with only deleted lights.
    previousLights[deviceId] = nil
    return device
  end)
  if IsEmpty(currentLights) then
    persist:set(PERSIST_CONVERTED_LIGHTS, nil)
  else
    persist:set(PERSIST_CONVERTED_LIGHTS, table.concat(TableKeys(currentLights), ","))
  end

  -- Delete all removed lights
  for previousLightDeviceId, previousLightDevice in pairs(previousLights) do
    log:info("Removing relay connection for light %s", previousLightDevice.displayName)
    bindings:deleteBinding(NS_RELAY, previousLightDeviceId)
    UnregisterVariableListener(previousLightDeviceId, 1000)
  end

  -- Configure relay for all selected lights
  for lightDeviceId, lightDevice in pairs(currentLights) do
    log:info("Configuring relay connection for light %s", lightDevice.displayName)
    local relayBinding =
      bindings:getOrAddDynamicBinding(NS_RELAY, lightDeviceId, "CONTROL", true, lightDevice.displayName, "RELAY")
    RFP[relayBinding.bindingId] = function(_, strCommand)
      if strCommand == "OPEN" then
        if toboolean(C4:GetDeviceVariable(lightDeviceId, 1000)) then
          log:info("Relay open; triggering light %s state to OFF", lightDevice.displayName)
          SendToDevice(lightDeviceId, "OFF", {})
        end
      elseif strCommand == "CLOSE" then
        if not toboolean(C4:GetDeviceVariable(lightDeviceId, 1000)) then
          log:info("Relay close; triggering light %s state to ON", lightDevice.displayName)
          SendToDevice(lightDeviceId, "ON", {})
        end
      elseif strCommand == "TOGGLE" then
        if toboolean(C4:GetDeviceVariable(lightDeviceId, 1000)) then
          log:info("Relay toggle; triggering light %s state to OFF", lightDevice.displayName)
          SendToDevice(lightDeviceId, "OFF", {})
        else
          log:info("Relay toggle; triggering light %s state to ON", lightDevice.displayName)
          SendToDevice(lightDeviceId, "ON", {})
        end
      end
    end
    local isInitial = true
    RegisterVariableListener(lightDeviceId, 1000, function(_, _, strValue)
      if toboolean(strValue) then
        if not isInitial then
          log:info("Light %s state changed to ON", lightDevice.displayName)
          SendToProxy(relayBinding.bindingId, "CLOSED", {}, "NOTIFY")
        else
          SendToProxy(relayBinding.bindingId, "STATE_CLOSED", {}, "NOTIFY")
        end
      else
        if not isInitial then
          log:info("Light %s state changed to OFF", lightDevice.displayName)
          SendToProxy(relayBinding.bindingId, "OPENED", {}, "NOTIFY")
        else
          SendToProxy(relayBinding.bindingId, "STATE_OPENED", {}, "NOTIFY")
        end
      end
      isInitial = false
    end)
  end
end

--------------------------------------------------------------------------------
-- Action Handlers
--------------------------------------------------------------------------------

function EC.Hide_Lights_In_All_Rooms()
  log:trace("EC.Hide_Lights_In_All_Rooms()")

  local lightDevices = ParseDeviceIdPropertyList("Convert Lights To Relays")
  if IsEmpty(lightDevices) then
    log:info("No lights selected")
    return
  end
  for roomId, roomName in pairs(C4:GetDevicesByC4iName("roomdevice.c4i") or {}) do
    for lightDeviceId, lightDevice in pairs(lightDevices) do
      log:info("Hiding light %s from room %s", lightDevice.deviceName, roomName)
      SendToDevice(
        roomId,
        "SET_DEVICE_HIDDEN_STATE",
        { PROXY_GROUP = "ALL", DEVICE_ID = lightDeviceId, IS_HIDDEN = true }
      )
    end
  end
end

function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")
  bindings:reset()
  persist:reset({ PERSIST_CONVERTED_LIGHTS })
  local resetValues = GetPropertyResetValues({})
  for propName, defaultValue in pairs(resetValues) do
    UpdateProperty(propName, defaultValue, true)
  end
end

--#ifndef DRIVERCENTRAL
--------------------------------------------------------------------------------
-- Update Drivers
--------------------------------------------------------------------------------

function EC.Update_Drivers()
  log:trace("EC.Update_Drivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end

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
