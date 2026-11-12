-- Humidity traces for the detector's tests, and the helpers that replay them.
--
-- The recorded traces come from a bathroom with its sensor in the exhaust fan
-- housing, one sample a minute: relative humidity in percent, temperature in
-- degrees Celsius, and whether the fan ran. The fan in them was switched by a
-- fixed level and a comparison with outdoor air, which is what made it cycle.
--
-- leakLoop: a warm, humid afternoon with no shower. With the fan off, outdoor
-- air leaks back onto the sensor and the reading climbs 12 to 16 points; with
-- the fan on it drops to the room's own value.
--
-- shower: a long shower in dry weather, the slow fall after it, then a creep of
-- 2 points over 80 minutes that crossed the old fixed level.

local Detector = require("humidity.detector")

local F = {}

--- @class RecordedTrace
--- @field rh number[] Relative humidity, one value a minute.
--- @field c number[] Temperature in degrees Celsius, one value a minute.
--- @field fan number[] 1 while the fan ran, one value a minute.

--- The numbers in a block of text, in order.
--- @param text string
--- @return number[] numbers
local function numbers(text)
  local list = {}
  for token in text:gmatch("%S+") do
    list[#list + 1] = tonumber(token)
  end
  return list
end

--- @type table<string, RecordedTrace>
local RECORDED = {
  leakLoop = {
    rh = numbers([[
      57.5 58.4 56.8 56.4 58.1 57.5 57.7 57.8 57.2 56.9 58.0 56.5 57.3 58.5 58.2
      58.4 51.3 46.7 45.9 48.2 54.3 58.2 56.4 58.0 59.8 60.2 60.2 52.3 47.3 46.5
      50.0 54.7 57.0 57.9 58.3 58.5 58.0 57.7 57.6 57.7 57.7 52.5 48.9 47.6 47.9
      53.6 58.8 60.2 58.4 58.2 59.3 61.3 62.4 62.6 53.5 47.6 46.5 47.2 53.6 59.6
      60.8 60.6 59.3 59.4 52.5 47.2 46.0 46.1 47.9 54.6 60.5 60.7 61.5 62.2 62.2
      52.9 46.8 45.8 48.0 56.1 60.6 59.5 59.7 59.9 52.3 51.0 54.4 57.9 60.3 60.7
      58.7 59.6 60.0 52.3 47.1 46.0 46.4 49.8 55.7 57.1 57.9 55.4 54.0 51.1 48.3
    ]]),
    c = numbers([[
      25.44 25.50 25.56 25.61 25.61 25.61 25.67 25.72 25.72 25.72 25.72 25.78 25.72 25.78 25.78
      25.83 25.83 25.67 25.39 25.17 25.11 25.17 25.17 25.17 25.22 25.22 25.28 25.28 25.17 25.06
      24.94 24.89 24.89 24.94 25.00 25.00 25.06 25.11 25.11 25.17 25.22 25.17 25.11 24.94 24.83
      24.78 24.78 24.78 24.83 24.83 24.83 24.89 24.94 25.00 25.00 24.94 24.83 24.72 24.72 24.72
      24.72 24.78 24.78 24.83 24.83 24.72 24.67 24.56 24.50 24.44 24.44 24.50 24.50 24.67 24.78
      24.78 24.72 24.67 24.56 24.50 24.56 24.61 24.67 24.78 24.78 24.78 24.83 24.89 24.94 25.06
      25.17 25.22 25.22 25.28 25.22 25.06 24.83 24.78 24.78 24.78 24.83 24.89 24.94 25.06 25.06
    ]]),
    fan = numbers([[
      0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 1 1 1 0 0 0 0 0 0 0 1 1 1 1 0 0 0 0 0 0 0 0 0 0 1
      1 1 1 0 0 0 0 0 0 0 0 0 1 1 1 1 0 0 0 0 0 0 1 1 1 1 0 0 0 0 0 0 0 1 1 1 1 0 0 0
      0 0 1 1 1 1 0 0 0 0 0 1 1 1 1 0 0 0 0 0 0 0 0 0 0
    ]]),
  },
  shower = {
    rh = numbers([[
      45.5 45.2 45.3 45.0 45.0 44.7 44.5 44.4 44.4 44.3 44.1 44.0 44.0 44.0 44.1
      44.1 44.2 44.2 58.8 69.6 78.5 85.8 95.4 97.8 99.1 99.9 99.9 99.9 99.9 99.9
      99.9 99.9 99.9 99.9 99.9 99.9 99.9 99.9 99.9 99.9 99.9 99.9 99.9 99.3 95.3
      87.9 83.8 79.0 75.1 73.4 71.4 69.9 68.3 67.6 66.7 66.6 65.5 65.4 65.4 64.7
      64.8 64.3 64.2 63.6 63.4 63.1 62.8 61.7 61.6 60.6 60.3 60.4 59.8 59.4 59.1
      59.6 59.4 59.2 58.8 59.0 58.2 56.0 55.1 54.4 53.8 53.2 52.8 52.1 51.3 50.8
      50.9 50.4 50.1 49.7 49.2 49.1 48.9 48.4 47.8 47.9 47.7 48.7 48.9 48.9 48.9
      48.9 49.0 48.5 48.6 48.7 48.5 48.8 48.5 48.6 48.7 48.7 48.6 48.5 48.5 48.5
      48.6 48.5 48.5 48.4 48.2 48.6 48.6 48.5 48.5 48.2 48.3 48.4 48.3 48.5 48.3
      48.4 48.6 48.6 48.8 49.0 49.1 49.2 49.3 49.4 49.4 49.4 49.4 49.7 49.6 49.7
      49.6 49.8 49.8 49.8 50.0 50.0 50.1 50.1 50.2 50.2 50.2 50.4 50.3 50.3 50.0
      50.0 49.8 49.7 49.7 49.7 49.6 49.5 49.5 49.5 49.3 49.2 49.0 49.0 48.9 48.9
      48.9 48.7 48.6 48.7 48.4 48.4 48.3 48.3 48.1 48.1 48.2 48.1 48.0 47.9 48.0
      48.0 48.0 48.0 48.1 48.0 48.2 48.3 48.2 48.3
    ]]),
    c = numbers([[
      24.72 24.61 24.61 24.61 24.61 24.61 24.61 24.61 24.72 24.72 24.72 24.72 24.72 24.72 24.61
      24.72 24.72 24.72 24.78 25.00 25.22 25.50 26.11 26.72 27.22 27.72 28.11 28.39 28.72 29.00
      29.22 29.39 29.50 29.61 29.72 29.78 29.89 30.00 30.11 30.22 30.28 30.28 30.28 30.22 30.11
      29.89 29.61 29.28 29.11 28.78 28.61 28.39 28.28 28.11 28.00 27.89 27.78 27.72 27.61 27.50
      27.50 27.39 27.39 27.39 27.28 27.28 27.28 27.22 27.22 27.22 27.11 27.11 27.11 27.11 27.11
      27.00 27.00 26.89 26.89 26.78 26.78 26.72 26.72 26.72 26.72 26.61 26.61 26.61 26.61 26.50
      26.50 26.50 26.39 26.39 26.28 26.28 26.28 26.22 26.22 26.11 26.22 26.11 26.11 26.11 26.11
      26.11 26.00 26.00 26.00 26.00 26.00 26.00 26.00 26.00 26.00 26.00 26.00 25.89 26.00 26.00
      26.00 26.00 26.00 26.00 26.00 26.00 26.00 26.11 26.00 26.11 26.11 26.11 26.11 26.11 26.00
      26.00 26.00 26.00 26.11 26.00 26.11 26.11 26.11 26.11 26.11 26.11 26.11 26.22 26.11 26.22
      26.22 26.22 26.28 26.22 26.28 26.28 26.28 26.28 26.28 26.39 26.28 26.39 26.39 26.50 26.50
      26.61 26.61 26.61 26.61 26.61 26.61 26.61 26.61 26.61 26.61 26.61 26.61 26.61 26.61 26.61
      26.61 26.61 26.61 26.61 26.50 26.50 26.50 26.50 26.50 26.50 26.50 26.50 26.50 26.50 26.50
      26.50 26.50 26.50 26.39 26.39 26.39 26.39 26.39 26.28
    ]]),
    fan = numbers([[
      0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
      1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
      1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
      0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
      1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 0 0 0 0 0 0
      0 0 0 0
    ]]),
  },
}

--- @class TracePoint
--- @field t number Minutes from the start of the trace.
--- @field rh number Relative humidity in percent.
--- @field c number|nil Temperature in degrees Celsius.
--- @field fan number|nil 1 while a fan ran.

--- A recorded trace as a list of points, one a minute.
--- @param name string "leakLoop" or "shower".
--- @return TracePoint[] trace
function F.recorded(name)
  local source = RECORDED[name]
  local trace = {}
  for i, rh in ipairs(source.rh) do
    trace[i] = { t = i - 1, rh = rh, c = source.c[i], fan = source.fan[i] }
  end
  return trace
end

--- A trace drawn as straight lines between a few points, one point a minute.
--- @param points TracePoint[] The corners, in time order.
--- @return TracePoint[] trace
function F.line(points)
  local trace = {}
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    for t = a.t, b.t - 1 do
      local k = (t - a.t) / (b.t - a.t)
      local c = nil
      if a.c ~= nil and b.c ~= nil then
        c = a.c + k * (b.c - a.c)
      end
      trace[#trace + 1] = { t = t, rh = a.rh + k * (b.rh - a.rh), c = c }
    end
  end
  local last = points[#points]
  trace[#trace + 1] = { t = last.t, rh = last.rh, c = last.c }
  return trace
end

--- The same trace without its temperatures.
--- @param trace TracePoint[]
--- @return TracePoint[] trace
function F.withoutTemperature(trace)
  local out = {}
  for i, point in ipairs(trace) do
    out[i] = { t = point.t, rh = point.rh, fan = point.fan }
  end
  return out
end

--- What a sensor that reports on a fixed interval would send.
--- @param trace TracePoint[]
--- @param minutes number The interval.
--- @return TracePoint[] trace
function F.everyMinutes(trace, minutes)
  local out = {}
  for _, point in ipairs(trace) do
    if point.t % minutes == 0 then
      out[#out + 1] = point
    end
  end
  return out
end

--- What a sensor that reports only a change, or a keep-alive, would send.
--- @param trace TracePoint[]
--- @param step number The change in points that makes it report.
--- @param keepAliveMinutes number How long it stays silent at most.
--- @return TracePoint[] trace
function F.onChange(trace, step, keepAliveMinutes)
  local out = {}
  local last = nil
  for _, point in ipairs(trace) do
    if last == nil or math.abs(point.rh - last.rh) >= step or point.t - last.t >= keepAliveMinutes then
      out[#out + 1] = point
      last = point
    end
  end
  return out
end

--- The driver's default settings, with any of them replaced.
--- @param overrides? HumiditySettings The settings to replace (optional).
--- @return HumiditySettings settings
function F.settings(overrides)
  local settings = {
    enabled = true,
    mode = Detector.Mode.RISE,
    riseAmount = 6,
    alertAbove = 80,
    clearBelow = 70,
    recoveryPercent = 50,
    runOnSeconds = 10 * 60,
    maxAlertSeconds = 60 * 60,
    sensorTimeoutSeconds = 24 * 60 * 60,
  }
  for key, value in pairs(overrides or {}) do
    settings[key] = value
  end
  return settings
end

--- @class ReplayOptions
--- @field state? HumidityState A state to continue from.
--- @field untilMinute? number Keep ticking to this minute after the last point.
--- @field fanStops? boolean Tell the detector when the recorded fan stopped.
--- @field fanRuns? boolean Tell the detector when the recorded fan started and stopped.
--- @field reference? TracePoint[] What the reference sensor reports, each point at its minute.

--- Feed a trace to the detector as a driver would: a tick every minute, each
--- point as a sample at its minute.
--- @param trace TracePoint[]
--- @param settings HumiditySettings
--- @param opts? ReplayOptions (optional)
--- @return string[] events Each change as "type reason @minute".
--- @return HumidityState state The state at the end.
function F.replay(trace, settings, opts)
  opts = opts or {}
  local state = opts.state or Detector.newState()
  local events = {}
  local function note(changes, minute)
    for _, change in ipairs(changes) do
      local reason = change.reason and (" " .. change.reason) or ""
      events[#events + 1] = string.format("%s%s @%d", change.type, reason, minute)
    end
  end
  local index = 1
  local refIndex = 1
  local reference = opts.reference or {}
  local fanWasOn = false
  local lastMinute = math.max(trace[#trace].t, opts.untilMinute or 0)
  for minute = trace[1].t, lastMinute do
    local now = minute * 60
    note(Detector.tick(state, settings, now), minute)
    while reference[refIndex] ~= nil and reference[refIndex].t <= minute do
      Detector.reference(state, now, reference[refIndex].rh, reference[refIndex].c)
      refIndex = refIndex + 1
    end
    while trace[index] ~= nil and trace[index].t <= minute do
      local point = trace[index]
      if (opts.fanStops or opts.fanRuns) and fanWasOn and point.fan == 0 then
        Detector.fanStopped(state, now)
      end
      if opts.fanRuns and not fanWasOn and point.fan == 1 then
        Detector.fanStarted(state, now)
      end
      fanWasOn = point.fan == 1
      note(Detector.sample(state, settings, now, point.rh, point.c), minute)
      index = index + 1
    end
  end
  return events, state
end

return F
