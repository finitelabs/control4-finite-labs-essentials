-- Moisture math for humid air: saturation vapor pressure, dew point, absolute
-- humidity, and relative humidity re-expressed at another temperature.
--
-- Relative humidity alone says little about how much water the air holds: the
-- same air reads about 6 % of its value lower for each degree Celsius it warms.
-- Everything here goes through vapor pressure, which does not move with
-- temperature.
--
-- Saturation pressure uses the Magnus form with the Alduchov and Eskridge
-- coefficients, good to 0.4 % from -40 to 50 C. Below freezing it is still the
-- pressure over water, which is what a relative humidity reading is defined
-- against.

local Psychro = {}

--- Magnus coefficient (dimensionless).
--- @type number
local MAGNUS_A = 17.625

--- Magnus coefficient, in degrees Celsius.
--- @type number
local MAGNUS_B = 243.04

--- Saturation vapor pressure at 0 C, in hPa.
--- @type number
local MAGNUS_C = 6.1094

--- Grams of water per cubic meter for each hPa of vapor pressure per kelvin.
--- @type number
local ABSOLUTE_HUMIDITY_FACTOR = 216.679

--- Offset from degrees Celsius to kelvin.
--- @type number
local KELVIN_OFFSET = 273.15

--- Saturation vapor pressure over water.
--- @param celsius number Air temperature in degrees Celsius.
--- @return number hPa The pressure at which the air is saturated.
function Psychro.saturationPressure(celsius)
  return MAGNUS_C * math.exp(MAGNUS_A * celsius / (MAGNUS_B + celsius))
end

--- Vapor pressure of air at a relative humidity and temperature.
--- @param rh number Relative humidity in percent.
--- @param celsius number Air temperature in degrees Celsius.
--- @return number hPa The partial pressure of the water vapor.
function Psychro.vaporPressure(rh, celsius)
  return rh / 100 * Psychro.saturationPressure(celsius)
end

--- Dew point of air at a relative humidity and temperature.
--- @param rh number Relative humidity in percent, above 0.
--- @param celsius number Air temperature in degrees Celsius.
--- @return number celsius The temperature at which this air would be saturated.
function Psychro.dewPoint(rh, celsius)
  local gamma = math.log(rh / 100) + MAGNUS_A * celsius / (MAGNUS_B + celsius)
  return MAGNUS_B * gamma / (MAGNUS_A - gamma)
end

--- Absolute humidity of air at a relative humidity and temperature.
--- @param rh number Relative humidity in percent.
--- @param celsius number Air temperature in degrees Celsius.
--- @return number gramsPerCubicMeter The mass of water vapor in a cubic meter of air.
function Psychro.absoluteHumidity(rh, celsius)
  return ABSOLUTE_HUMIDITY_FACTOR * Psychro.vaporPressure(rh, celsius) / (celsius + KELVIN_OFFSET)
end

--- The relative humidity the same air would have at another temperature.
--- It passes 100 when the air holds more water than the other temperature could.
--- @param rh number Relative humidity in percent.
--- @param celsius number The temperature the reading was taken at, in degrees Celsius.
--- @param referenceCelsius number The temperature to express it at, in degrees Celsius.
--- @return number rh Relative humidity in percent at the reference temperature.
function Psychro.humidityAt(rh, celsius, referenceCelsius)
  return rh * Psychro.saturationPressure(celsius) / Psychro.saturationPressure(referenceCelsius)
end

return Psychro
