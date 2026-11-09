--- The driver's properties for its web tab: what the tab shows, read once from this build's driver.xml, and the
--- changes the tab may make. Passwords stay in Composer's Properties tab.
---
--- lib/ui/page.js's properties card speaks this: the driver's CONFIG_DATA carries `properties`, JSON of `list()`; the
--- page sends `_SET_PROPERTY` with `{ property, value }`; a refusal goes back as PROPERTY_ERROR with `payload`, JSON
--- of `{ property, error }`.

require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")

local log = require("lib.logging")

local SHOWN_TYPES = { LIST = true, STRING = true, RANGED_INTEGER = true }

--- @class TabProperty
--- @field name string The property's name in driver.xml.
--- @field group string The label above it in Composer, or "" before the first label.
--- @field readonly boolean Whether only the driver sets it.
--- @field description? string Its driver.xml description.
--- @field value? string Its current value, in what `list` returns.
--- @field choices? string[] A list's items, or the logger's levels for Log Level.
--- @field minimum? integer A ranged integer's lowest value.
--- @field maximum? integer A ranged integer's highest value.
--- @field logLevels? boolean Set on Log Level, whose choices come from the logger.

--- @class TabProperties
--- @field private _config TabProperty[]|nil The properties the tab shows, read once from driver.xml.
local TabProperties = {}
TabProperties.__index = TabProperties

--- Creates a new `TabProperties` instance.
--- @return TabProperties tabProperties A new `TabProperties` instance.
function TabProperties:new()
  return setmetatable({}, self)
end

--- @private
--- @return TabProperty[] config Each property the tab shows, in driver.xml order.
function TabProperties:_read()
  if self._config then
    return self._config
  end
  self._config = {}
  local group = ""
  for xml in XMLgCapture(C4:GetDriverConfigInfo("config") or "", "property") do
    local kind = XMLCapture(xml, "type")
    -- Text comes back as driver.xml spells it: a label's `&` is `&amp;` there.
    if kind == "LABEL" then
      group = XMLDecode(XMLCapture(xml, "default") or "")
    elseif
      (SHOWN_TYPES[kind] or (kind == "DYNAMIC_LIST" and XMLCapture(xml, "name") == "Log Level"))
      and XMLCapture(xml, "password") ~= "true"
    then
      local property = {
        name = XMLDecode(XMLCapture(xml, "name")),
        group = group,
        readonly = XMLCapture(xml, "readonly") == "true",
        description = XMLDecode(XMLCapture(xml, "description")),
      }
      if kind == "DYNAMIC_LIST" then
        -- Log Level: the logger gives its choices, which a Support Code hour widens.
        property.logLevels = true
      elseif kind == "LIST" then
        property.choices = {}
        for item in XMLgCapture(xml, "item") do
          table.insert(property.choices, XMLDecode(item))
        end
      elseif kind == "RANGED_INTEGER" then
        property.minimum = tonumber(XMLCapture(xml, "minimum"))
        property.maximum = tonumber(XMLCapture(xml, "maximum"))
      end
      table.insert(self._config, property)
    end
  end
  return self._config
end

--- Lists the properties the tab shows, each with its current value.
--- @return TabProperty[] properties In driver.xml order; Log Level's choices are the logger's levels now.
function TabProperties:list()
  local properties = {}
  for _, config in ipairs(self:_read()) do
    local property = { value = Properties[config.name] or "" }
    for key, value in pairs(config) do
      property[key] = value
    end
    if config.logLevels then
      property.logLevels = nil
      property.choices = log:getLogLevelNames()
    end
    table.insert(properties, property)
  end
  return properties
end

--- @private
--- @param config TabProperty
--- @param value string
--- @return string|nil value The value to set, or nil when the property cannot hold it.
--- @return string|nil err Why not.
local function checked(config, value)
  local choices = config.logLevels and log:getLogLevelNames() or config.choices
  if choices then
    for _, choice in ipairs(choices) do
      if choice == value then
        return value
      end
    end
    return nil, string.format("%s has no choice %s.", config.name, value)
  end
  if config.minimum then
    local number = tonumber(value)
    if not number or math.floor(number) ~= number or number < config.minimum or number > config.maximum then
      return nil, string.format("%s must be a whole number from %d to %d.", config.name, config.minimum, config.maximum)
    end
    return string.format("%d", number)
  end
  return value
end

--- Sets one of the driver's properties, as Composer's Properties tab would, so its handler runs.
--- @param name any The property.
--- @param value any Its new value.
--- @return string|nil err Why the tab may not set it, or nil once it is set.
function TabProperties:set(name, value)
  for _, config in ipairs(self:_read()) do
    if config.name == name and not config.readonly and type(value) == "string" then
      local accepted, err = checked(config, value)
      if not accepted then
        return err
      end
      UpdateProperty(name, accepted, true)
      return nil
    end
  end
  return "The tab cannot set " .. tostring(name) .. "."
end

--- Calls `push` after each change to a property the tab shows, wherever it was made. Call it once the load's own
--- property changes have run, at the end of OnDriverLateInit.
--- @param push fun() Sends the tab what it shows.
function TabProperties:follow(push)
  for _, config in ipairs(self:_read()) do
    local key = config.name:gsub("%W", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
    local handler = OPC[key]
    OPC[key] = function(value)
      local result
      if handler then
        result = handler(value)
      end
      push()
      return result
    end
  end
end

return TabProperties:new()
