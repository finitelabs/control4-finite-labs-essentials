-- The humidity detector against recorded and drawn humidity traces: when an
-- alert starts, when it ends, and that every start is answered by one clear.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_humidity_detector.lua
--
-- Each trace is replayed as a driver would feed it: a tick every minute and
-- each reading as a sample at its minute. Events read "type reason @minute".

local T = require("testlib")
local F = require("humidity_fixtures")
local Detector = require("humidity.detector")

local RISE = Detector.Mode.RISE
local THRESHOLD = Detector.Mode.THRESHOLD
local EITHER = Detector.Mode.RISE_OR_THRESHOLD

--- The events of a replay, joined by "; " ("" for none).
local function events(trace, overrides, opts)
  return table.concat((F.replay(trace, F.settings(overrides), opts)), "; ")
end

--- How many events of one type a replay produced.
local function count(trace, overrides, type, opts)
  local n = 0
  for _, event in ipairs((F.replay(trace, F.settings(overrides), opts))) do
    if event:find(type, 1, true) == 1 then
      n = n + 1
    end
  end
  return n
end

--- Tick once a minute over a span, returning every change.
local function ticks(state, settings, fromMinute, toMinute)
  local changes = {}
  for minute = fromMinute, toMinute do
    for _, change in ipairs(Detector.tick(state, settings, minute * 60)) do
      changes[#changes + 1] = change
    end
  end
  return changes
end

local leakLoop = F.recorded("leakLoop")
local shower = F.recorded("shower")

T.section("recorded: a sensor in a fan housing reading leaked outdoor air is not a shower")
T.eq("the afternoon as recorded", events(leakLoop), "")
T.eq("told each time the fan stopped", events(leakLoop, nil, { fanStops = true }), "")
T.eq("with no temperature", events(F.withoutTemperature(leakLoop)), "")
T.eq("through a sensor that reports 6 point changes", events(F.onChange(leakLoop, 6, 60)), "")
T.eq("through a sensor that reports every 5 minutes", events(F.everyMinutes(leakLoop, 5)), "")

T.section("recorded: a shower starts one alert, at its first rising sample, and ends it once")
-- The first rising sample is minute 18. Half the rise is gone at minute 50, so
-- the run-on ends at minute 60. A quarter is not reached until minute 77.
T.eq("rise", events(shower), "started Rise @18; cleared @60")
T.eq(
  "asked to wait for three quarters of the rise, the maximum ends it first",
  events(shower, { recoveryPercent = 75 }),
  "started Rise @18; cleared @78"
)
T.eq("told when the recorded fan stopped", events(shower, nil, { fanStops = true }), "started Rise @18; cleared @60")
T.eq("the creep of 2 points over 80 minutes after it starts nothing", count(shower, nil, "started"), 1)
T.eq("with no temperature", events(F.withoutTemperature(shower)), "started Rise @18; cleared @60")
T.eq(
  "with no temperature and three quarters asked, it times out",
  events(F.withoutTemperature(shower), { recoveryPercent = 75 }),
  "started Rise @18; cleared @78; timed_out @78"
)
T.eq("threshold", events(shower, { mode = THRESHOLD }), "started Threshold @21; cleared @61")
T.eq("rise or threshold", events(shower, { mode = EITHER }), "started Rise @18; cleared @61")
T.eq(
  "a shorter maximum ends it sooner, and says so",
  events(shower, { maxAlertSeconds = 30 * 60 }),
  "started Rise @18; cleared @48; timed_out @48"
)

T.section("recorded: the same shower through slow sensors")
T.eq("6 point changes or hourly", events(F.onChange(shower, 6, 60)), "started Rise @18; cleared @67")
T.eq("every 5 minutes", events(F.everyMinutes(shower, 5)), "started Rise @20; cleared @60")
T.eq("every 10 minutes", events(F.everyMinutes(shower, 10)), "started Rise @20; cleared @60")

T.section("a dry winter shower")
local winter = F.line({
  { t = 0, rh = 30, c = 21 },
  { t = 30, rh = 30, c = 21 },
  { t = 36, rh = 85, c = 23 },
  { t = 45, rh = 85, c = 24 },
  { t = 60, rh = 45, c = 22.5 },
  { t = 90, rh = 34, c = 21.5 },
  { t = 180, rh = 31, c = 21 },
})
T.eq("rise", events(winter), "started Rise @31; cleared @65")
T.eq("6 point changes or hourly", events(F.onChange(winter, 6, 60)), "started Rise @32; cleared @67")

T.section("humid weather is not a shower")
local drift = F.line({
  { t = 0, rh = 55, c = 24 },
  { t = 360, rh = 80, c = 26 },
  { t = 720, rh = 55, c = 24 },
})
T.eq("a drift of 25 points over 6 hours", events(drift), "")
T.eq("through a sensor that reports 6 point changes or hourly", events(F.onChange(drift, 6, 60)), "")
T.eq("through a sensor that reports 7 point changes or twice a day", events(F.onChange(drift, 7, 720)), "")
T.eq(
  "a fixed level runs once to its maximum, then waits for the room to dry",
  events(drift, { mode = THRESHOLD, alertAbove = 70, clearBelow = 60 }),
  "started Threshold @216; cleared @276; timed_out @276"
)

local twoDays = F.line({
  { t = 0, rh = 55, c = 24 },
  { t = 360, rh = 80, c = 26 },
  { t = 720, rh = 55, c = 24 },
  { t = 1080, rh = 80, c = 26 },
  { t = 1440, rh = 55, c = 24 },
})
T.eq(
  "once the room has dried, the level starts an alert again",
  count(twoDays, { mode = THRESHOLD, alertAbove = 70, clearBelow = 60 }, "started"),
  2
)

T.section("a shower in an air-conditioned house, and in a house already humid")
local conditioned = F.line({
  { t = 0, rh = 50, c = 24 },
  { t = 30, rh = 50, c = 24 },
  { t = 36, rh = 90, c = 25 },
  { t = 42, rh = 90, c = 25.5 },
  { t = 60, rh = 58, c = 24.5 },
  { t = 120, rh = 51, c = 24 },
})
T.eq("air-conditioned", events(conditioned), "started Rise @31; cleared @64")
local humidHouse = F.line({
  { t = 0, rh = 75, c = 26 },
  { t = 30, rh = 75, c = 26 },
  { t = 36, rh = 97, c = 27 },
  { t = 42, rh = 97, c = 27.5 },
  { t = 60, rh = 80, c = 26.5 },
  { t = 120, rh = 76, c = 26 },
})
T.eq("at 75 percent", events(humidHouse), "started Rise @32; cleared @64")
T.eq(
  "at 75 percent, rise or threshold: one alert, ended by the maximum",
  events(humidHouse, { mode = EITHER }),
  "started Rise @32; cleared @92; timed_out @92"
)

T.section("a steam session pins the sensor at 100 percent")
local steam = F.line({
  { t = 0, rh = 45, c = 22 },
  { t = 10, rh = 45, c = 22 },
  { t = 14, rh = 100, c = 26 },
  { t = 64, rh = 100, c = 28 },
  { t = 80, rh = 60, c = 25 },
  { t = 140, rh = 47, c = 22 },
})
T.eq("a flat top is not a settled room", events(steam), "started Rise @11; cleared @71; timed_out @71")

local wetAndCold = F.line({
  { t = 0, rh = 45, c = 24 },
  { t = 10, rh = 45, c = 24 },
  { t = 14, rh = 100, c = 27 },
  { t = 24, rh = 100, c = 28 },
  { t = 34, rh = 100, c = 20 },
  { t = 90, rh = 100, c = 20 },
})
T.eq(
  "nor is a wet sensor in a room that cooled below where it started",
  events(wetAndCold),
  "started Rise @11; cleared @71; timed_out @71"
)

T.section("showers back to back")
local twice = F.line({
  { t = 0, rh = 40, c = 22 },
  { t = 10, rh = 40, c = 22 },
  { t = 15, rh = 90, c = 24 },
  { t = 25, rh = 90, c = 24.5 },
  { t = 30, rh = 70, c = 24 },
  { t = 35, rh = 92, c = 25 },
  { t = 45, rh = 92, c = 25.5 },
  { t = 65, rh = 50, c = 23 },
  { t = 130, rh = 42, c = 22 },
})
T.eq("a second one during the first is the same alert", count(twice, nil, "started"), 1)
T.eq("and it is cleared once", count(twice, nil, "cleared"), 1)
local points = { { t = 0, rh = 45, c = 22 }, { t = 10, rh = 45, c = 22 } }
for shower = 0, 4 do
  local t = 10 + shower * 40
  points[#points + 1] = { t = t + 5, rh = 90, c = 24 }
  points[#points + 1] = { t = t + 40, rh = 70, c = 23 }
end
T.contains(
  "one after another, they extend it to twice its maximum and no further",
  events(F.line(points)),
  "started Rise @11; cleared @131; timed_out @131; started"
)
local soonAfter = F.line({
  { t = 0, rh = 40, c = 22 },
  { t = 10, rh = 40, c = 22 },
  { t = 15, rh = 88, c = 24 },
  { t = 22, rh = 88, c = 24 },
  { t = 40, rh = 48, c = 22.5 },
  { t = 62, rh = 46, c = 22 },
  { t = 67, rh = 88, c = 24 },
  { t = 75, rh = 88, c = 24 },
  { t = 95, rh = 48, c = 22.5 },
  { t = 160, rh = 42, c = 22 },
})
T.eq(
  "one that starts during the hold-off still starts at once",
  events(soonAfter),
  "started Rise @11; cleared @43; started Rise @63; cleared @96"
)

T.section("what does not count as a rise")
local dip = F.line({
  { t = 0, rh = 50, c = 22 },
  { t = 30, rh = 50, c = 22 },
  { t = 33, rh = 42, c = 21 },
  { t = 43, rh = 50, c = 22 },
  { t = 90, rh = 50, c = 22 },
})
T.eq("a dip and its recovery", events(dip), "")
local smallRise = F.line({
  { t = 0, rh = 50, c = 22 },
  { t = 30, rh = 50, c = 22 },
  { t = 40, rh = 54, c = 22 },
  { t = 90, rh = 51, c = 22 },
})
T.eq("a rise under the Rise Amount", events(smallRise), "")
local cooling = F.line({
  { t = 0, rh = 50, c = 24 },
  { t = 30, rh = 50, c = 24 },
  { t = 42, rh = 59.7, c = 21 },
  { t = 120, rh = 59.7, c = 21 },
})
T.eq("a room that cools with no change in its moisture", events(cooling), "")
T.eq(
  "with no temperature the same room reads as a rise, bounded by its maximum",
  events(F.withoutTemperature(cooling)),
  "started Rise @38; cleared @98; timed_out @98"
)
local rebound = F.line({
  { t = 0, rh = 40, c = 22 },
  { t = 10, rh = 40, c = 22 },
  { t = 15, rh = 88, c = 24 },
  { t = 22, rh = 88, c = 24 },
  { t = 40, rh = 48, c = 22.5 },
  { t = 48, rh = 46, c = 22 },
  { t = 63, rh = 54, c = 22 },
  { t = 150, rh = 52, c = 22 },
})
T.eq("the rebound after an alert, during the hold-off or when it ends", count(rebound, nil, "started"), 1)

T.section("a door left open: a small, slow rise")
local doorOpen = F.line({
  { t = 0, rh = 45, c = 22 },
  { t = 30, rh = 45, c = 22 },
  { t = 40, rh = 53, c = 23 },
  { t = 50, rh = 53, c = 23 },
  { t = 70, rh = 47, c = 22 },
  { t = 130, rh = 45, c = 22 },
})
T.eq("is caught once it passes the Rise Amount", events(doorOpen), "started Rise @36; cleared @72")

T.section("readings that cannot be real, and long silences")
local state = Detector.newState()
local settings = F.settings()
Detector.sample(state, settings, 0, 45, 22)
T.eq("a humidity of 0 is dropped", #Detector.sample(state, settings, 60, 0, 22), 0)
T.eq("and the next real reading is not a rise from it", #Detector.sample(state, settings, 120, 46, 22), 0)
T.eq("a temperature of 85 is dropped, the humidity kept", #Detector.sample(state, settings, 180, 46, 85), 0)
T.eq("a humidity that is not a number is dropped", #Detector.sample(state, settings, 240, nil, 22), 0)

local quiet = { { t = 0, rh = 45, c = 22 }, { t = 1, rh = 45, c = 22 } }
quiet[3] = { t = 181, rh = 60, c = 22 }
T.eq("3 hours of silence, then 15 points higher: only a new baseline", events(quiet), "")
quiet[3] = { t = 81, rh = 52, c = 22 }
T.eq("80 minutes of silence, then 7 points higher: an old baseline needs more", events(quiet), "")
quiet[3] = { t = 81, rh = 59, c = 22 }
T.eq("80 minutes of silence, then 14 points higher", events(quiet, nil, { untilMinute = 82 }), "started Rise @81")

T.section("the first reading after a start or a new connection only sets the baseline")
state = Detector.newState()
settings = F.settings({ mode = THRESHOLD })
T.eq("a first reading above the level", #Detector.sample(state, settings, 0, 90, 24), 0)
T.eq("the next one starts the alert", Detector.sample(state, settings, 60, 90, 24)[1].type, "started")
state = Detector.newState()
settings = F.settings()
Detector.sample(state, settings, 0, 45, 22)
Detector.reseed(state)
T.eq("a new sensor reading 15 points higher", #Detector.sample(state, settings, 60, 60, 22), 0)

T.section("a fixed level in a room that stays humid")
local damp = F.line({
  { t = 0, rh = 85, c = 26 },
  { t = 200, rh = 85, c = 26 },
  { t = 206, rh = 98, c = 27 },
  { t = 215, rh = 98, c = 27 },
  { t = 235, rh = 86, c = 26 },
  { t = 400, rh = 85, c = 26 },
})
T.eq(
  "runs once, then only a shower starts it again",
  events(damp, { mode = THRESHOLD }),
  "started Threshold @1; cleared @61; timed_out @61; started Threshold @202; cleared @262; timed_out @262"
)

local bounce = F.line({
  { t = 0, rh = 60, c = 26 },
  { t = 10, rh = 60, c = 26 },
  { t = 20, rh = 85, c = 26 },
  { t = 30, rh = 69, c = 26 },
  { t = 43, rh = 69, c = 26 },
  { t = 46, rh = 82, c = 26 },
  { t = 120, rh = 82, c = 26 },
})
T.eq(
  "a level crossed again during the hold-off waits for it to end",
  events(bounce, { mode = THRESHOLD }),
  "started Threshold @18; cleared @40; started Threshold @55; cleared @115; timed_out @115"
)

T.section("commands")
state = Detector.newState()
settings = F.settings()
Detector.sample(state, settings, 0, 45, 22)
T.eq("Start Alert starts a manual alert", Detector.startManual(state, settings, 60, 20 * 60)[1].reason, "Manual")
T.eq("it holds for its time", #ticks(state, settings, 2, 20), 0)
local ended = ticks(state, settings, 21, 22)
T.eq("then clears, and is not a time-out", { #ended, ended[1].type }, { 1, "cleared" })
T.eq("Clear Alert with no alert changes nothing", #Detector.clear(state, settings, 23 * 60), 0)
Detector.startManual(state, settings, 24 * 60, 20 * 60)
T.eq("Clear Alert ends an alert", Detector.clear(state, settings, 25 * 60)[1].type, "cleared")
T.eq("the state names no reason once clear", { state.active, state.reason }, { false, "" })

T.section("detection disabled")
local running = select(2, F.replay({ shower[1], shower[18], shower[19], shower[20] }, F.settings()))
T.eq("an alert is active", running.active, true)
local off = F.settings({ enabled = false })
T.eq("disabling ends it", Detector.tick(running, off, 20 * 60)[1].type, "cleared")
T.eq("and no shower starts one", #Detector.sample(running, off, 60 * 60, 99, 28), 0)

T.section("a silent sensor")
state = Detector.newState()
settings = F.settings()
Detector.sample(state, settings, 0, 45, 22)
local minute = 0
local staleEvents = 0
while minute < 26 * 60 do
  minute = minute + 1
  staleEvents = staleEvents + #Detector.tick(state, settings, minute * 60)
end
T.eq("is reported stale once", { staleEvents, state.stale }, { 1, true })
T.eq("and restored by its next reading", Detector.sample(state, settings, minute * 60 + 60, 46, 22)[1].type, "restored")

T.section("restarts: every start is answered by one clear")
--- The state as a driver stores it: everything but the history.
local function stored(live)
  local copy = {}
  for key, value in pairs(live) do
    copy[key] = value
  end
  copy.history = nil
  copy.reasons = {}
  for key, value in pairs(live.reasons) do
    copy.reasons[key] = value
  end
  return copy
end
local function midShower()
  return select(2, F.replay({ shower[1], shower[18], shower[19], shower[20], shower[21] }, F.settings()))
end
settings = F.settings()
state = stored(midShower())
Detector.restart(state, 25 * 60)
T.eq("a restart of 5 minutes keeps the alert", { state.active, #Detector.tick(state, settings, 25 * 60) }, { true, 0 })
T.eq("and its first reading is judged as part of it", #Detector.sample(state, settings, 26 * 60, 99.9, 28), 0)
state = stored(midShower())
Detector.restart(state, 200 * 60)
local after = Detector.tick(state, settings, 200 * 60)
T.eq(
  "an alert that passed its maximum while down ends at the first tick",
  { after[1].type, after[2].type, state.active },
  { "cleared", "timed_out", false }
)
T.eq("and the first reading after it only sets the baseline", #Detector.sample(state, settings, 201 * 60, 70, 24), 0)
state = stored(midShower())
Detector.restart(state, -1000)
after = Detector.tick(state, settings, -1000)
T.eq("a clock that went backwards across the restart ends the alert", { #after, after[1].type }, { 1, "cleared" })

settings = F.settings({ mode = THRESHOLD })
state = Detector.newState()
Detector.sample(state, settings, 0, 60, 26)
state = stored(state)
Detector.restart(state, 60)
T.eq("with no alert, the first reading after a restart starts none", #Detector.sample(state, settings, 120, 90, 26), 0)
T.eq("the next one does", Detector.sample(state, settings, 180, 90, 26)[1].type, "started")
settings = F.settings()

T.section("a fan that stops lets outdoor air back onto a sensor in its housing")
-- Three hours of fan have aged out the level the reading rested at before.
local longRun = { { t = 0, rh = 46, c = 24 } }
for minute = 1, 180 do
  longRun[#longRun + 1] = { t = minute, rh = 46, c = 24, fan = 1 }
end
for minute = 181, 200 do
  longRun[#longRun + 1] = { t = minute, rh = math.min(56, 46 + (minute - 180) * 2.5), c = 24, fan = 0 }
end
T.eq("the climb after it stops is held to the larger rise", events(longRun, nil, { fanStops = true }), "")
T.eq("not told of the fan, the same climb reads as a rise", count(longRun, nil, "started"), 1)

T.section("a clock that jumps while the driver runs")
state = midShower()
T.eq("an hour forward does not end the alert", #Detector.tick(state, settings, (20 + 61) * 60), 0)
T.eq("which still has its hour to run", state.maxDeadline, (18 + 60 + 60) * 60)
state = midShower()
Detector.tick(state, settings, (20 - 59) * 60)
T.eq("an hour back does not stretch it", state.maxDeadline, (18 + 60 - 60) * 60)

T.section("a room that stops drying short of its target ends there")
local plateau = F.line({
  { t = 0, rh = 50, c = 22 },
  { t = 30, rh = 50, c = 22 },
  { t = 34, rh = 90, c = 22 },
  { t = 40, rh = 90, c = 22 },
  { t = 50, rh = 76, c = 22 },
  { t = 150, rh = 76, c = 22 },
})
T.eq("stopped falling with a third of the rise gone", events(plateau), "started Rise @31; cleared @75")
T.eq(
  "a plateau just under the peak is a shower still running",
  events(F.line({
    { t = 0, rh = 50, c = 22 },
    { t = 30, rh = 50, c = 22 },
    { t = 34, rh = 90, c = 22 },
    { t = 36, rh = 86, c = 22 },
    { t = 150, rh = 86, c = 22 },
  })),
  "started Rise @31; cleared @91; timed_out @91"
)

T.section("after a time-out in a humid room, the hold-off's larger rise applies to every start")
local humidAfter = F.line({
  { t = 0, rh = 50, c = 22 },
  { t = 30, rh = 50, c = 22 },
  { t = 31, rh = 85, c = 22 },
  { t = 94, rh = 85, c = 22 },
  { t = 95, rh = 92, c = 22 },
  { t = 130, rh = 92, c = 22 },
})
T.eq("threshold", events(humidAfter, { mode = THRESHOLD }), "started Threshold @31; cleared @91; timed_out @91")
T.eq("rise or threshold", events(humidAfter, { mode = EITHER }), "started Rise @31; cleared @91; timed_out @91")

T.section("a manual hold outlasts the maximum")
state = Detector.newState()
settings = F.settings()
Detector.sample(state, settings, 0, 50, 22)
Detector.sample(state, settings, 29 * 60, 50, 22)
T.eq("a shower starts an alert", Detector.sample(state, settings, 30 * 60, 90, 22)[1].reason, "Rise")
ticks(state, settings, 31, 84)
Detector.sample(state, settings, 84 * 60, 90, 22)
T.eq("Start Alert on an active alert changes nothing yet", #Detector.startManual(state, settings, 85 * 60, 30 * 60), 0)
T.eq("the maximum passes and the alert holds", #ticks(state, settings, 86, 114), 0)
local held = ticks(state, settings, 115, 116)
T.eq("it ends when the hold does, and is not a time-out", { #held, held[1].type }, { 1, "cleared" })

state = Detector.newState()
settings = F.settings({ mode = EITHER })
Detector.sample(state, settings, 0, 50, 22)
Detector.sample(state, settings, 29 * 60, 50, 22)
Detector.sample(state, settings, 30 * 60, 90, 22)
local humidHold = {}
for minute = 31, 150 do
  if minute == 85 then
    Detector.startManual(state, settings, minute * 60, 30 * 60)
  end
  local changes = minute % 5 == 0 and Detector.sample(state, settings, minute * 60, 90, 22)
    or Detector.tick(state, settings, minute * 60)
  for _, change in ipairs(changes) do
    humidHold[#humidHold + 1] = change.type .. " @" .. minute
  end
end
T.eq(
  "in a room still above Alert Above, the level does not start a second maximum",
  table.concat(humidHold, "; "),
  "cleared @115"
)
settings = F.settings()

state = Detector.newState()
Detector.sample(state, settings, 0, 45, 22)
Detector.startManual(state, settings, 60, 30 * 60)
Detector.startManual(state, settings, 120, 5 * 60)
T.eq("a second, shorter Start Alert does not shorten the first", #ticks(state, settings, 3, 30), 0)
T.eq("which still ends on time", #ticks(state, settings, 31, 32), 1)

T.finish()
