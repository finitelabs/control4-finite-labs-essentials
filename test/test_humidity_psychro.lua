-- The moisture math against published reference values.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_humidity_psychro.lua

local T = require("testlib")
local Psychro = require("humidity.psychro")

--- A number rounded to a count of decimals, for comparing with a table value.
local function rounded(value, decimals)
  local scale = 10 ^ decimals
  return math.floor(value * scale + 0.5) / scale
end

T.section("saturation vapor pressure")
T.eq("at 0 C, in hPa", rounded(Psychro.saturationPressure(0), 4), 6.1094)
T.eq("at 20 C", rounded(Psychro.saturationPressure(20), 1), 23.3)
T.eq(
  "it rises about 6 percent a degree near room temperature",
  rounded(Psychro.saturationPressure(22) / Psychro.saturationPressure(21), 2),
  1.06
)

T.section("absolute humidity, in grams per cubic meter")
T.eq("20 C at 80 percent", rounded(Psychro.absoluteHumidity(80, 20), 1), 13.8)
T.eq("21 C at 30 percent, a dry winter room", rounded(Psychro.absoluteHumidity(30, 21), 1), 5.5)
T.eq("24 C at 55 percent, a summer room", rounded(Psychro.absoluteHumidity(55, 24), 1), 11.9)
T.eq("30 C at 80 percent, a muggy day", rounded(Psychro.absoluteHumidity(80, 30), 1), 24.2)

T.section("dew point, in degrees Celsius")
T.eq("21 C at 30 percent", rounded(Psychro.dewPoint(30, 21), 1), 2.8)
T.eq("24 C at 55 percent", rounded(Psychro.dewPoint(55, 24), 1), 14.4)
T.eq("30 C at 80 percent", rounded(Psychro.dewPoint(80, 30), 1), 26.2)
T.eq("25 C at 90 percent, a shower", rounded(Psychro.dewPoint(90, 25), 1), 23.2)
T.eq("40 C at 50 percent", rounded(Psychro.dewPoint(50, 40), 1), 27.6)
T.eq("saturated air is at its dew point", rounded(Psychro.dewPoint(100, 18), 6), 18)

T.section("humidity at another temperature")
T.eq("the same temperature changes nothing", Psychro.humidityAt(47, 22, 22), 47)
T.eq("air that warmed 2 C held more water than its reading shows", rounded(Psychro.humidityAt(44, 23, 21), 1), 49.7)
T.eq("it passes 100 when the cooler air could not hold it", rounded(Psychro.humidityAt(100, 25, 21), 0), 127)
T.eq(
  "it keeps the vapor pressure",
  rounded(Psychro.vaporPressure(Psychro.humidityAt(60, 27, 22), 22), 6),
  rounded(Psychro.vaporPressure(60, 27), 6)
)

T.finish()
