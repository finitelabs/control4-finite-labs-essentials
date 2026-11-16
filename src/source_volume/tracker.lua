-- Decides when a room's volume is set to a picked source's fixed level and
-- when the level from before is put back. A pure state machine: it calls
-- nothing in Control4, keeps no timers and stores nothing. The driver feeds it
-- a settled snapshot of its room with the current time in seconds, and sends
-- the levels it returns.
--
-- Levels are kept per volume device, because a room may use one device for
-- audio sources and another for video. A level is only ever put back on a
-- device this tracker changed. A level restores only while the room still
-- holds the last level seen under the picked source, so a level another
-- driver or Control4's default volumes set at the switch wins.
--
-- The state is one plain table that the driver stores whole.

local Tracker = {}

--- What a call changed.
--- @enum SourceVolumeChangeType
Tracker.Change = {
  SET = "set",
  FIXED = "fixed",
  RESTORED = "restored",
  UNSETTABLE = "unsettable",
  MISSED = "missed",
}

--- How long a level sent waits to show in the room before it is sent again, in seconds.
--- @type number
Tracker.CONFIRM_SECONDS = 3

--- @class SourceVolumeRoom
--- @field source number The selected device, 0 when the room is off.
--- @field power boolean
--- @field volume number The room's volume, -1 when unknown.
--- @field volumeDevice number The device the room's volume acts on.
--- @field discrete boolean Whether the room accepts a volume level.
--- @field useDefaults boolean Whether Control4's default volumes are on for the room.

--- @class SourceVolumeSettings
--- @field enabled boolean
--- @field sources table<number, number> Picked source to its fixed level.

--- @class SourceVolumeChange
--- @field type SourceVolumeChangeType
--- @field level number|nil
--- @field source number|nil

--- A fresh state.
--- @return table
function Tracker.new()
  return {
    active = nil,
    activeDevice = nil,
    off = false,
    saved = {},
    held = {},
    last = {},
    sent = nil,
  }
end

--- Whether a level is a real volume.
--- @param level any
--- @return boolean
local function known(level)
  return type(level) == "number" and level >= 0
end

--- Device ids arrive as numbers or strings; tables key them as strings so a stored state round-trips.
--- @param id number
--- @return string
local function key(id)
  return tostring(id)
end

--- Send a level and remember it until the room shows it.
local function send(state, changes, source, device, level, now)
  state.sent = { source = source, device = device, level = level, at = now, retried = false }
  changes[#changes + 1] = { type = Tracker.Change.SET, level = level }
end

--- Follow up on a level sent earlier. Returns true while it is still on its way.
local function followSent(state, room, now, changes)
  local sent = state.sent
  if not sent then
    return false
  end
  if key(sent.device) ~= key(room.volumeDevice) or not room.power then
    state.sent = nil
    return false
  end
  if room.volume == sent.level then
    state.sent = nil
    return false
  end
  if now - sent.at < Tracker.CONFIRM_SECONDS then
    return true
  end
  -- After a switch, keep waiting so a late level still restores, but never resend or report under another source.
  local stillSelected = sent.source == tonumber(room.source)
  if not sent.retried and stillSelected then
    sent.retried = true
    sent.at = now
    changes[#changes + 1] = { type = Tracker.Change.SET, level = sent.level }
    return true
  end
  state.sent = nil
  if stillSelected then
    changes[#changes + 1] = { type = Tracker.Change.MISSED, level = sent.level }
  end
  return false
end

--- Forget everything saved, as when the driver is disabled.
--- @param state table
function Tracker.forget(state)
  for k in pairs(state) do
    state[k] = nil
  end
  for k, v in pairs(Tracker.new()) do
    state[k] = v
  end
end

--- Act on a settled snapshot of the room.
--- @param state table
--- @param settings SourceVolumeSettings
--- @param room SourceVolumeRoom
--- @param now number Seconds.
--- @return SourceVolumeChange[]
function Tracker.update(state, settings, room, now)
  local changes = {}
  if not settings.enabled then
    Tracker.forget(state)
    return changes
  end

  local source = tonumber(room.source) or 0
  if not room.power or source == 0 then
    state.active = nil
    state.activeDevice = nil
    state.sent = nil
    state.off = true
    return changes
  end

  local wasOff = state.off
  state.off = false
  local device = key(room.volumeDevice)
  local inFlight = followSent(state, room, now, changes)
  local fixed = settings.sources[source]

  if fixed then
    local entering = state.active ~= source or state.activeDevice ~= device
    if entering then
      if not room.discrete then
        if state.active ~= source then
          changes[#changes + 1] = { type = Tracker.Change.UNSETTABLE, source = source }
        end
        state.active = source
        state.activeDevice = device
        return changes
      end
      if state.saved[device] == nil then
        local before = state.last[device]
        if not known(before) and not wasOff and state.active == nil then
          before = room.volume
        end
        if known(before) then
          state.saved[device] = before
        end
      end
      state.active = source
      state.activeDevice = device
      state.held[device] = fixed
      if room.volume ~= fixed then
        send(state, changes, source, room.volumeDevice, fixed, now)
      end
      changes[#changes + 1] = { type = Tracker.Change.FIXED, source = source, level = fixed }
    elseif not inFlight and known(room.volume) then
      state.held[device] = room.volume
    end
    return changes
  end

  state.active = nil
  state.activeDevice = nil
  local saved = state.saved[device]
  if saved ~= nil and not inFlight then
    state.saved[device] = nil
    local held = state.held[device]
    state.held[device] = nil
    if wasOff and room.useDefaults then
      state.last[device] = room.volume
      return changes
    end
    if room.discrete and room.volume == held then
      if room.volume ~= saved then
        send(state, changes, source, room.volumeDevice, saved, now)
      end
      changes[#changes + 1] = { type = Tracker.Change.RESTORED, level = saved }
      state.last[device] = saved
      return changes
    end
  end
  if not inFlight and known(room.volume) then
    state.last[device] = room.volume
  end
  return changes
end

--- The level that will be put back on the room's current volume device, or -1.
--- @param state table
--- @param room SourceVolumeRoom
--- @return number
function Tracker.savedLevel(state, room)
  local saved = state.saved[key(room.volumeDevice)]
  if saved == nil and state.activeDevice then
    saved = state.saved[state.activeDevice]
  end
  return saved or -1
end

--- Whether a picked source holds the room.
--- @param state table
--- @return boolean
function Tracker.isActive(state)
  return state.active ~= nil
end

return Tracker
