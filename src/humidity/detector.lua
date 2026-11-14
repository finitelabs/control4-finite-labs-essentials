-- Decides when a room's humidity means a shower, and for how long the alert
-- should last. A pure state machine: it calls nothing in Control4, keeps no
-- timers and stores nothing. The driver feeds it samples, a tick about once a
-- minute and commands, each with the current time in seconds, and acts on the
-- changes it returns.
--
-- An alert starts on a rise above the level the room rested at, on a fixed
-- level, or on a command. It ends when the reasons it started for are gone,
-- and always by its maximum. Every start is answered by exactly one clear.
--
-- The state is one plain table. `history` is working memory and can be dropped
-- before the rest is stored: the first sample after a restart only seeds it.

local Psychro = require("humidity.psychro")

local Detector = {}

--- How an alert may start.
--- @enum HumidityMode
Detector.Mode = {
  RISE = "Rise",
  THRESHOLD = "Threshold",
  RISE_OR_THRESHOLD = "Rise or Threshold",
}

--- Why an alert is active.
--- @enum HumidityReason
Detector.Reason = {
  RISE = "Rise",
  THRESHOLD = "Threshold",
  MANUAL = "Manual",
}

--- What a call changed.
--- @enum HumidityChangeType
Detector.Change = {
  STARTED = "started",
  CLEARED = "cleared",
  TIMED_OUT = "timed_out",
  STALE = "stale",
  RESTORED = "restored",
}

--- How far back the low a rise is measured from may lie, in seconds.
--- @type number
local RISE_WINDOW = 15 * 60

--- How long after an alert, or after a switched device stops, a start needs a larger rise.
--- @type number
local HOLD_OFF = 15 * 60

--- How much larger that rise is.
--- @type number
local HOLD_OFF_FACTOR = 2

--- The most an old baseline can multiply the rise it needs.
--- @type number
local OLD_BASELINE_FACTOR = 2

--- With no sample for this long, the next one only seeds a new baseline.
--- @type number
local BASELINE_MAX_AGE = 2 * 60 * 60

--- How far back the resting level is remembered, in seconds.
--- @type number
local REST_WINDOW = 2 * 60 * 60

--- Two samples this far apart judge whether the humidity has stopped falling.
--- @type number
local SETTLE_TIME = 15 * 60

--- A fall of at most this many points over that time is "stopped falling".
--- @type number
local SETTLE_FALL = 1

--- Settled counts once this share of the Recovery setting's fall has happened:
--- a room that stops drying short of its target ends there, a plateau near the
--- peak does not.
--- @type number
local SETTLE_SHARE = 0.5

--- A reading at or above this is a wet sensor, never a settled or recovered room.
--- @type number
local SATURATED = 95

--- A second shower may extend an alert to this many times its maximum.
--- @type number
local CEILING_FACTOR = 2

--- Clear Below is held at least this far under Alert Above.
--- @type number
local THRESHOLD_GAP = 3

--- The time between two ticks, in seconds.
--- @type number
local TICK = 60

--- A gap between calls longer than this is a clock jump, not elapsed time.
--- @type number
local CLOCK_JUMP = 5 * 60

--- Downtime longer than this across a restart cannot be trusted.
--- @type number
local MAX_DOWNTIME = 24 * 60 * 60

--- History keeps one sample per this many seconds.
--- @type number
local BUCKET = 60

--- A threshold start needs the room this many points wetter than the reference.
--- @type number
local REFERENCE_MARGIN = 8

--- @class HumiditySettings
--- @field enabled boolean False ends any alert and starts none.
--- @field mode HumidityMode How an alert may start.
--- @field riseAmount number The rise, in points, that starts an alert.
--- @field alertAbove number The level at or above which a threshold alert starts.
--- @field clearBelow number The level at or below which a threshold alert ends.
--- @field recoveryPercent number The share of a rise, in percent, that must be gone for the room to count as recovered.
--- @field runOnSeconds number How long an alert lasts after its reasons are gone.
--- @field maxAlertSeconds number The longest a detected alert lasts.
--- @field sensorTimeoutSeconds number Silence after which the sensor is stale; 0 never.

--- @class HumiditySample
--- @field t number When it was taken, in seconds.
--- @field rh number Relative humidity in percent, as the sensor reported it.
--- @field c number|nil Temperature in degrees Celsius, when the sensor gave one.
--- @field rest boolean True when taken outside an alert and its hold-off.

--- @class ReferenceSample
--- @field t number When it was taken, in seconds.
--- @field rh number Relative humidity in percent, as the reference sensor reported it.
--- @field c number|nil Temperature in degrees Celsius, when that sensor gave one.

--- @class HumidityChange
--- @field type HumidityChangeType What happened.
--- @field reason HumidityReason|nil Why, for a start.

--- @class HumidityState
--- @field seed boolean True when the next sample only sets a baseline.
--- @field history HumiditySample[] Recent samples, oldest first.
--- @field refHistory ReferenceSample[]|nil Recent reference samples, oldest first; working memory like `history`.
--- @field stale boolean True while the sensor has been silent too long.
--- @field active boolean True while an alert is active.
--- @field reason string Why the alert started, "" when clear.
--- @field reasons table<string, boolean> The reasons that still hold.
--- @field latched boolean True while threshold starts wait for the room to dry.
--- @field expire boolean True when a restart could not tell how long it was down.
--- @field lastNow number|nil The time of the last call.
--- @field lastSampleTime number|nil The time of the last accepted sample.
--- @field lastRh number|nil The last accepted humidity.
--- @field lastC number|nil The temperature that came with it.
--- @field startTime number|nil When the alert started.
--- @field maxDeadline number|nil When the alert ends whatever the room does.
--- @field ceiling number|nil The latest a second shower may move that to.
--- @field runOnUntil number|nil When the run-on ends, once no reason holds.
--- @field manualUntil number|nil When a manual alert ends.
--- @field startLevel number|nil The humidity the rise started from.
--- @field refC number|nil The temperature that level was read at.
--- @field peak number|nil The highest humidity since the rise started.
--- @field peakTime number|nil When that was.
--- @field lowSincePeak number|nil The lowest humidity since the peak.
--- @field holdOffUntil number|nil When the hold-off after an alert ends.
--- @field leakGuardUntil number|nil When the hold-off after a switched device stops ends.
--- @field floorTime number|nil Samples before this no longer set the baseline.
--- @field deviceRunning boolean|nil True while a device the driver watches runs.
--- @field deviceRest HumiditySample|nil The highest sample the room rested at before the device ran.
--- @field deviceRestUntil number|nil When that sample stops counting, once the device has stopped.

--- A state with nothing learned and no alert.
--- @return HumidityState state A new state.
function Detector.newState()
  return {
    seed = true,
    history = {},
    stale = false,
    active = false,
    reason = "",
    reasons = {},
    latched = false,
    expire = false,
  }
end

--- A humidity re-expressed at a reference temperature, or as read when either
--- temperature is missing.
--- @param rh number
--- @param c number|nil
--- @param refC number|nil
--- @return number rh
local function valueAt(rh, c, refC)
  if c ~= nil and refC ~= nil then
    return Psychro.humidityAt(rh, c, refC)
  end
  return rh
end

--- @param settings HumiditySettings
--- @return boolean rise True when a rise may start an alert.
local function usesRise(settings)
  return settings.mode ~= Detector.Mode.THRESHOLD
end

--- @param settings HumiditySettings
--- @return boolean threshold True when a level may start an alert.
local function usesThreshold(settings)
  return settings.mode ~= Detector.Mode.RISE
end

--- @param settings HumiditySettings
--- @return number clearBelow The level a threshold alert ends at.
local function clearLevel(settings)
  return math.min(settings.clearBelow, settings.alertAbove - THRESHOLD_GAP)
end

--- @param value number|nil A stored time.
--- @param delta number Seconds to add.
--- @return number|nil value The time moved, nil when there was none.
local function shifted(value, delta)
  if value == nil then
    return nil
  end
  return value + delta
end

--- Move every stored time by the size of a clock jump.
--- @param state HumidityState
--- @param delta number Seconds to add.
local function shiftTimes(state, delta)
  state.lastSampleTime = shifted(state.lastSampleTime, delta)
  state.startTime = shifted(state.startTime, delta)
  state.maxDeadline = shifted(state.maxDeadline, delta)
  state.ceiling = shifted(state.ceiling, delta)
  state.runOnUntil = shifted(state.runOnUntil, delta)
  state.manualUntil = shifted(state.manualUntil, delta)
  state.peakTime = shifted(state.peakTime, delta)
  state.holdOffUntil = shifted(state.holdOffUntil, delta)
  state.leakGuardUntil = shifted(state.leakGuardUntil, delta)
  state.floorTime = shifted(state.floorTime, delta)
  for _, sample in ipairs(state.history) do
    sample.t = sample.t + delta
  end
  for _, sample in ipairs(state.refHistory or {}) do
    sample.t = sample.t + delta
  end
end

--- Take the time of a call. Calls come at least once a tick, so a longer gap
--- or a step backwards is the clock moving, and the stored times move with it.
--- @param state HumidityState
--- @param now number
local function advance(state, now)
  if state.lastNow ~= nil then
    local dt = now - state.lastNow
    if dt < 0 or dt > CLOCK_JUMP then
      shiftTimes(state, dt - TICK)
    end
  end
  state.lastNow = now
end

--- @param state HumidityState
--- @param now number
--- @return boolean holding True during the hold-off that follows an alert.
local function inHoldOff(state, now)
  return state.holdOffUntil ~= nil and now < state.holdOffUntil
end

--- @param state HumidityState
--- @param now number
--- @return boolean guarding True during the hold-off that follows a device stopping.
local function inLeakGuard(state, now)
  return state.leakGuardUntil ~= nil and now < state.leakGuardUntil
end

--- Keep one sample per bucket and nothing older than the resting memory.
--- @param state HumidityState
--- @param now number
--- @param rh number
--- @param c number|nil
local function remember(state, now, rh, c)
  local history = state.history
  -- A running exhaust fan pulls the room's own air over a sensor in its housing: not where it rests.
  local rest = not state.active and not inHoldOff(state, now) and not state.deviceRunning
  local sample = { t = now, rh = rh, c = c, rest = rest }
  local last = history[#history]
  if last ~= nil and math.floor(last.t / BUCKET) == math.floor(now / BUCKET) then
    history[#history] = sample
  else
    history[#history + 1] = sample
  end
  while #history > 1 and history[1].t < now - REST_WINDOW do
    table.remove(history, 1)
  end
end

--- The sample a rise is measured from: the driest in the rise window, counting
--- the one in force when the window opened. Its age is how long that value has
--- stood, which for a quiet sensor is longer than the window.
--- @param state HumidityState
--- @param now number
--- @param c number|nil The temperature of the sample being judged.
--- @return HumiditySample|nil low The baseline sample, nil with no history.
--- @return number age Seconds since that value came into force.
local function recentLow(state, now, c)
  local floor = state.floorTime
  local cut = now - RISE_WINDOW
  if floor ~= nil and floor > cut then
    cut = floor
  end
  local low, lowValue, lowTime = nil, nil, nil
  local inForce = nil
  for _, sample in ipairs(state.history) do
    if sample.t < cut then
      inForce = sample
    else
      local value = valueAt(sample.rh, sample.c, c)
      if lowValue == nil or value < lowValue then
        low, lowValue, lowTime = sample, value, sample.t
      end
    end
  end
  if inForce ~= nil then
    local value = valueAt(inForce.rh, inForce.c, c)
    if lowValue == nil or value < lowValue then
      low, lowTime = inForce, inForce.t
      if floor ~= nil and lowTime < floor then
        lowTime = floor
      end
    end
  end
  if low == nil then
    return nil, 0
  end
  return low, now - lowTime
end

--- The highest level the room rested at before a baseline sample.
--- @param state HumidityState
--- @param now number
--- @param low HumiditySample The baseline sample.
--- @param refC number|nil The temperature to compare at.
--- @return number|nil high The level, nil when nothing was seen at rest.
local function restingHigh(state, now, low, refC)
  local high = nil
  for _, sample in ipairs(state.history) do
    if sample.rest and sample.t <= low.t and sample.t >= now - REST_WINDOW then
      local value = valueAt(sample.rh, sample.c, refC)
      if high == nil or value > high then
        high = value
      end
    end
  end
  -- A device run of any length must not age out the level the room rested at before it.
  local kept = state.deviceRest
  if kept ~= nil and (state.deviceRunning or (state.deviceRestUntil ~= nil and now < state.deviceRestUntil)) then
    local value = valueAt(kept.rh, kept.c, refC)
    if high == nil or value > high then
      high = value
    end
  end
  return high
end

--- The reference sample in force, unless the reference has been silent longer
--- than a sensor may be. A quiet reference is a steady room, so its last value
--- stands until then.
--- @param state HumidityState
--- @param settings HumiditySettings
--- @param now number
--- @return ReferenceSample|nil reference The sample, nil with no usable reference.
local function referenceInForce(state, settings, now)
  local refHistory = state.refHistory
  local last = refHistory and refHistory[#refHistory]
  if last == nil then
    return nil
  end
  if settings.sensorTimeoutSeconds > 0 and now - last.t > settings.sensorTimeoutSeconds then
    return nil
  end
  return last
end

--- How much the reference room rose since a moment in the past: the part of
--- the room's own rise that the whole house shares. Only changes are compared,
--- so two sensors that read a few points apart do no harm.
--- @param state HumidityState
--- @param settings HumiditySettings
--- @param now number
--- @param since number The time the room's rise is measured from.
--- @return number rise The reference's rise in points, never below 0.
local function referenceRise(state, settings, now, since)
  local current = referenceInForce(state, settings, now)
  if current == nil then
    return 0
  end
  -- The value in force at that moment; with none that old, the oldest known.
  local base = state.refHistory[1]
  for _, sample in ipairs(state.refHistory) do
    if sample.t <= since then
      base = sample
    end
  end
  -- A reference that dried out says nothing about this room, so it never adds to the rise.
  return math.max(0, valueAt(current.rh, current.c, base.c) - base.rh)
end

--- Whether the room is wetter than the reference by the margin a threshold
--- start needs. With no usable reference there is nothing to compare.
--- @param state HumidityState
--- @param settings HumiditySettings
--- @param now number
--- @param rh number
--- @param c number|nil
--- @return boolean above True when it is, or when no reference is in use.
local function aboveReference(state, settings, now, rh, c)
  local reference = referenceInForce(state, settings, now)
  if reference == nil then
    return true
  end
  return rh - valueAt(reference.rh, reference.c, c) >= REFERENCE_MARGIN
end

--- Whether a sample is a rise that may start an alert.
--- @param state HumidityState
--- @param settings HumiditySettings
--- @param now number
--- @param rh number
--- @param c number|nil
--- @param factor number How many times the Rise Amount is needed.
--- @return boolean rising True when it is.
--- @return number|nil startLevel The humidity the rise started from.
--- @return number|nil refC The temperature that level was read at.
--- @return number|nil current The sample at that temperature.
local function isRise(state, settings, now, rh, c, factor)
  local low, age = recentLow(state, now, c)
  if low == nil then
    return false
  end
  local refC = nil
  if c ~= nil and low.c ~= nil then
    refC = low.c
  end
  local current = valueAt(rh, c, refC)
  local aged = math.max(1, math.min(OLD_BASELINE_FACTOR, age / RISE_WINDOW))
  local shared = referenceRise(state, settings, now, now - age)
  if current - low.rh - shared < settings.riseAmount * aged * factor then
    return false
  end
  -- Climbing back to a level the room already rested at is not a shower.
  local high = restingHigh(state, now, low, refC)
  if high ~= nil and current < high + settings.riseAmount / 2 then
    return false
  end
  return true, low.rh, refC, current
end

--- @param state HumidityState
--- @return boolean detected True when a reason other than Manual holds.
local function hasDetectedReason(state)
  return state.reasons[Detector.Reason.RISE] == true or state.reasons[Detector.Reason.THRESHOLD] == true
end

--- Add a reason to the alert, starting it when there is none.
--- @param state HumidityState
--- @param settings HumiditySettings
--- @param now number
--- @param reason HumidityReason
--- @param changes HumidityChange[]
local function addReason(state, settings, now, reason, changes)
  if not state.active then
    state.active = true
    state.reason = reason
    state.reasons = {}
    state.startTime = now
    changes[#changes + 1] = { type = Detector.Change.STARTED, reason = reason }
  end
  state.reasons[reason] = true
  state.runOnUntil = nil
  if reason ~= Detector.Reason.MANUAL and state.maxDeadline == nil then
    state.maxDeadline = now + settings.maxAlertSeconds
    state.ceiling = now + CEILING_FACTOR * settings.maxAlertSeconds
  end
end

--- Start tracking a rise inside the alert.
--- @param state HumidityState
--- @param now number
--- @param startLevel number
--- @param refC number|nil
--- @param current number
local function trackRise(state, now, startLevel, refC, current)
  state.startLevel = startLevel
  state.refC = refC
  state.peak = current
  state.peakTime = now
  state.lowSincePeak = current
end

--- End the alert and start its hold-off.
--- @param state HumidityState
--- @param settings HumiditySettings
--- @param now number
--- @param timedOut boolean True when the maximum ended it.
--- @param changes HumidityChange[]
local function endAlert(state, settings, now, timedOut, changes)
  changes[#changes + 1] = { type = Detector.Change.CLEARED }
  if timedOut then
    changes[#changes + 1] = { type = Detector.Change.TIMED_OUT }
  end
  -- An alert that ends in a humid room must not start again on the level alone.
  if usesThreshold(settings) and state.lastRh ~= nil and state.lastRh > clearLevel(settings) then
    state.latched = true
  end
  state.active = false
  state.reason = ""
  state.reasons = {}
  state.expire = false
  state.startTime = nil
  state.maxDeadline = nil
  state.ceiling = nil
  state.runOnUntil = nil
  state.manualUntil = nil
  state.startLevel = nil
  state.refC = nil
  state.peak = nil
  state.peakTime = nil
  state.lowSincePeak = nil
  state.holdOffUntil = now + HOLD_OFF
  state.floorTime = now
end

--- Whether the humidity has stopped falling, judged from samples alone: a
--- quiet sensor proves nothing.
--- @param state HumidityState
--- @param settings HumiditySettings
--- @param now number
--- @param rh number
--- @param current number
--- @return boolean settled True when it has.
local function isSettled(state, settings, now, rh, current)
  if rh >= SATURATED then
    return false
  end
  local remaining = 1 - SETTLE_SHARE * settings.recoveryPercent / 100
  if current > state.startLevel + remaining * (state.peak - state.startLevel) then
    return false
  end
  local anchor = nil
  for _, sample in ipairs(state.history) do
    if sample.t <= now - SETTLE_TIME and sample.t >= state.peakTime then
      anchor = sample
    end
  end
  if anchor == nil then
    return false
  end
  local high = current
  for _, sample in ipairs(state.history) do
    if sample.t >= anchor.t then
      high = math.max(high, valueAt(sample.rh, sample.c, state.refC))
    end
  end
  return high - current <= SETTLE_FALL
end

--- Judge a sample while an alert is active.
--- @param state HumidityState
--- @param settings HumiditySettings
--- @param now number
--- @param rh number
--- @param c number|nil
--- @param changes HumidityChange[]
local function sampleDuringAlert(state, settings, now, rh, c, changes)
  if state.reasons[Detector.Reason.RISE] then
    local current = valueAt(rh, c, state.refC)
    if current > state.peak then
      state.peak = current
      state.peakTime = now
      state.lowSincePeak = current
    else
      state.lowSincePeak = math.min(state.lowSincePeak, current)
      if current - state.lowSincePeak >= settings.riseAmount then
        -- Another shower: follow its peak, and give it time up to the ceiling.
        state.peak = current
        state.peakTime = now
        state.lowSincePeak = current
        state.maxDeadline = math.min(now + settings.maxAlertSeconds, state.ceiling)
      end
    end
    local remaining = 1 - settings.recoveryPercent / 100
    local recovered = rh < SATURATED and current <= state.startLevel + remaining * (state.peak - state.startLevel)
    if recovered or isSettled(state, settings, now, rh, current) then
      state.reasons[Detector.Reason.RISE] = nil
    end
  elseif usesRise(settings) then
    local rising, startLevel, refC, current = isRise(state, settings, now, rh, c, 1)
    if rising then
      addReason(state, settings, now, Detector.Reason.RISE, changes)
      trackRise(state, now, startLevel, refC, current)
    end
  end

  if usesThreshold(settings) then
    if state.reasons[Detector.Reason.THRESHOLD] then
      if rh <= clearLevel(settings) then
        state.reasons[Detector.Reason.THRESHOLD] = nil
      end
    elseif rh >= settings.alertAbove and not state.latched and aboveReference(state, settings, now, rh, c) then
      addReason(state, settings, now, Detector.Reason.THRESHOLD, changes)
    end
  end

  if next(state.reasons) == nil then
    if state.runOnUntil == nil then
      state.runOnUntil = now + settings.runOnSeconds
    end
  else
    state.runOnUntil = nil
  end
end

--- Judge a sample while no alert is active.
--- @param state HumidityState
--- @param settings HumiditySettings
--- @param now number
--- @param rh number
--- @param c number|nil
--- @param changes HumidityChange[]
local function sampleWhileClear(state, settings, now, rh, c, changes)
  local holding = inHoldOff(state, now)
  if state.latched and rh <= clearLevel(settings) then
    state.latched = false
  end

  local factor = (holding or inLeakGuard(state, now)) and HOLD_OFF_FACTOR or 1
  if usesRise(settings) then
    local rising, startLevel, refC, current = isRise(state, settings, now, rh, c, factor)
    if rising then
      addReason(state, settings, now, Detector.Reason.RISE, changes)
      trackRise(state, now, startLevel, refC, current)
    end
  end

  if usesThreshold(settings) and rh >= settings.alertAbove and aboveReference(state, settings, now, rh, c) then
    if state.active then
      if not state.latched then
        addReason(state, settings, now, Detector.Reason.THRESHOLD, changes)
      end
    elseif not state.latched then
      if not holding then
        addReason(state, settings, now, Detector.Reason.THRESHOLD, changes)
      end
    elseif isRise(state, settings, now, rh, c, factor) then
      -- A shower in a room that stayed humid still gets its alert.
      state.latched = false
      addReason(state, settings, now, Detector.Reason.THRESHOLD, changes)
    end
  end
end

--- Everything that depends on time alone.
--- @param state HumidityState
--- @param settings HumiditySettings
--- @param now number
--- @param changes HumidityChange[]
local function timeCheck(state, settings, now, changes)
  if state.active then
    if not settings.enabled or state.expire then
      endAlert(state, settings, now, false, changes)
    else
      if state.reasons[Detector.Reason.MANUAL] and now >= state.manualUntil then
        state.reasons[Detector.Reason.MANUAL] = nil
        state.manualUntil = nil
        if next(state.reasons) == nil and state.runOnUntil == nil then
          endAlert(state, settings, now, false, changes)
        end
      end
      if state.active and state.maxDeadline ~= nil and now >= state.maxDeadline then
        if state.reasons[Detector.Reason.MANUAL] then
          -- A manual hold outlasts the maximum: only what was detected ends there.
          state.reasons = { [Detector.Reason.MANUAL] = true }
          state.maxDeadline = nil
          state.ceiling = nil
          state.latched = usesThreshold(settings)
        else
          endAlert(state, settings, now, hasDetectedReason(state), changes)
        end
      end
      if state.active and state.runOnUntil ~= nil and now >= state.runOnUntil then
        endAlert(state, settings, now, false, changes)
      end
    end
  end

  -- The level the room settled at during a hold-off is the new baseline.
  if state.holdOffUntil ~= nil and now >= state.holdOffUntil then
    state.floorTime = state.holdOffUntil
    state.holdOffUntil = nil
  end
  if state.leakGuardUntil ~= nil and now >= state.leakGuardUntil then
    state.floorTime = state.leakGuardUntil
    state.leakGuardUntil = nil
  end

  if
    not state.stale
    and settings.sensorTimeoutSeconds > 0
    and state.lastSampleTime ~= nil
    and now - state.lastSampleTime > settings.sensorTimeoutSeconds
  then
    state.stale = true
    changes[#changes + 1] = { type = Detector.Change.STALE }
  end
end

--- A humidity report. A reading that cannot be real is dropped, and does not
--- count as hearing from the sensor.
--- @param state HumidityState The state, changed in place.
--- @param settings HumiditySettings The current settings.
--- @param now number The time, in seconds.
--- @param rh number|nil Relative humidity in percent.
--- @param celsius number|nil Temperature from the same sensor, in degrees Celsius.
--- @return HumidityChange[] changes What the report changed, in order.
function Detector.sample(state, settings, now, rh, celsius)
  local changes = {}
  advance(state, now)
  timeCheck(state, settings, now, changes)
  if type(rh) ~= "number" or not (rh > 0 and rh <= 100) then
    return changes
  end
  local c = celsius
  if type(c) ~= "number" or not (c >= 0 and c <= 50) then
    c = nil
  end

  if state.stale then
    state.stale = false
    changes[#changes + 1] = { type = Detector.Change.RESTORED }
  end
  local silence = state.lastSampleTime ~= nil and now - state.lastSampleTime or 0
  state.lastSampleTime = now
  state.lastRh = rh
  state.lastC = c

  if state.active then
    state.seed = false
    sampleDuringAlert(state, settings, now, rh, c, changes)
  elseif state.seed or silence > BASELINE_MAX_AGE then
    state.seed = false
    state.history = {}
  elseif settings.enabled then
    sampleWhileClear(state, settings, now, rh, c, changes)
  end
  remember(state, now, rh, c)
  return changes
end

--- A report from the reference sensor, somewhere else in the house. It starts
--- and ends nothing: it only corrects how the room's next samples are judged.
--- @param state HumidityState The state, changed in place.
--- @param now number The time, in seconds.
--- @param rh number|nil Relative humidity in percent.
--- @param celsius number|nil Temperature from the same sensor, in degrees Celsius.
function Detector.reference(state, now, rh, celsius)
  advance(state, now)
  if type(rh) ~= "number" or not (rh > 0 and rh <= 100) then
    return
  end
  local c = celsius
  if type(c) ~= "number" or not (c >= 0 and c <= 50) then
    c = nil
  end
  local refHistory = state.refHistory or {}
  state.refHistory = refHistory
  local sample = { t = now, rh = rh, c = c }
  local last = refHistory[#refHistory]
  if last ~= nil and math.floor(last.t / BUCKET) == math.floor(now / BUCKET) then
    refHistory[#refHistory] = sample
  else
    refHistory[#refHistory + 1] = sample
  end
  -- Keep the one value in force when the resting memory opens: a quiet sensor's only sample.
  while #refHistory > 1 and refHistory[2].t < now - REST_WINDOW do
    table.remove(refHistory, 1)
  end
end

--- The reference sensor was unbound or changed: its readings no longer count.
--- @param state HumidityState The state, changed in place.
function Detector.dropReference(state)
  state.refHistory = nil
end

--- The reference reading the room is being corrected with.
--- @param state HumidityState The state.
--- @param settings HumiditySettings The current settings.
--- @param now number The time, in seconds.
--- @return number|nil rh Its humidity, nil when no reference is in use.
--- @return boolean silent True when there is one but it has been silent too long.
function Detector.referenceReading(state, settings, now)
  local reference = referenceInForce(state, settings, now)
  if reference ~= nil then
    return reference.rh, false
  end
  return nil, state.refHistory ~= nil and #state.refHistory > 0
end

--- The passing of time. Call it about once a minute, and after a setting
--- changes.
--- @param state HumidityState The state, changed in place.
--- @param settings HumiditySettings The current settings.
--- @param now number The time, in seconds.
--- @return HumidityChange[] changes What the tick changed, in order.
function Detector.tick(state, settings, now)
  local changes = {}
  advance(state, now)
  timeCheck(state, settings, now, changes)
  return changes
end

--- Start an alert by command, or hold an active one for at least this long.
--- @param state HumidityState The state, changed in place.
--- @param settings HumiditySettings The current settings.
--- @param now number The time, in seconds.
--- @param seconds number How long the manual alert lasts.
--- @return HumidityChange[] changes What the command changed, in order.
function Detector.startManual(state, settings, now, seconds)
  local changes = {}
  advance(state, now)
  timeCheck(state, settings, now, changes)
  addReason(state, settings, now, Detector.Reason.MANUAL, changes)
  state.manualUntil = math.max(state.manualUntil or 0, now + seconds)
  return changes
end

--- End the alert now, by command or because its device was switched off by hand.
--- @param state HumidityState The state, changed in place.
--- @param settings HumiditySettings The current settings.
--- @param now number The time, in seconds.
--- @return HumidityChange[] changes What the command changed, in order.
function Detector.clear(state, settings, now)
  local changes = {}
  advance(state, now)
  timeCheck(state, settings, now, changes)
  if state.active then
    endAlert(state, settings, now, false, changes)
  end
  return changes
end

--- A switched device stopped while no alert was active. A sensor in an exhaust fan's housing then
--- reads outdoor air leaking back, so the next rise is held to the larger
--- amount and the baseline is taken again once the reading has settled.
--- @param state HumidityState The state, changed in place.
--- @param now number The time, in seconds.
function Detector.deviceStopped(state, now)
  advance(state, now)
  if state.deviceRunning then
    state.deviceRunning = false
    state.deviceRestUntil = now + REST_WINDOW
  end
  if not state.active then
    state.leakGuardUntil = now + HOLD_OFF
    state.floorTime = now
  end
end

--- A switched device started. The level the room rested at before it is kept for as long
--- as the device runs, so the climb after it stops is measured against that level.
--- @param state HumidityState The state, changed in place.
--- @param now number The time, in seconds.
function Detector.deviceStarted(state, now)
  advance(state, now)
  if state.deviceRunning then
    return
  end
  local kept = state.deviceRest
  if kept ~= nil and (state.deviceRestUntil == nil or now >= state.deviceRestUntil) then
    kept = nil
  end
  for _, sample in ipairs(state.history) do
    if sample.rest and sample.t >= now - REST_WINDOW and (kept == nil or sample.rh > kept.rh) then
      kept = sample
    end
  end
  state.deviceRest = kept
  state.deviceRestUntil = nil
  state.deviceRunning = true
end

--- The sensor was bound or changed: the next sample only sets a baseline.
--- @param state HumidityState The state, changed in place.
function Detector.reseed(state)
  state.seed = true
end

--- The driver started. Time that passed while it was down counts, unless the
--- clock cannot say how much: then an active alert ends at the next tick.
--- @param state HumidityState The state as it was stored, changed in place.
--- @param now number The time, in seconds.
function Detector.restart(state, now)
  local down = state.lastNow ~= nil and now - state.lastNow or 0
  if down < 0 or down > MAX_DOWNTIME then
    state.expire = state.active
    state.holdOffUntil = nil
    state.leakGuardUntil = nil
    state.floorTime = nil
    state.deviceRest = nil
    state.deviceRestUntil = nil
  end
  state.history = state.history or {}
  -- The reference must be heard again: its stored readings have no known age.
  state.refHistory = nil
  state.seed = true
  state.lastNow = now
end

return Detector
