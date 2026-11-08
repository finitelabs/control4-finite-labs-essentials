--- The driver's properties for its web tab: what the tab shows, read once from this build's driver.xml, and the
--- changes the tab may make. Passwords stay in Composer's Properties tab.

require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")

local log = require("lib.logging")

--- @class TabProperties
--- @field private _config table[]|nil
local TabProperties = {}
TabProperties.__index = TabProperties

local SHOWN_TYPES = { LIST = true, STRING = true, RANGED_INTEGER = true }

--- Creates a new `TabProperties` instance.
--- @return TabProperties tabProperties A new `TabProperties` instance.
function TabProperties:new()
  return setmetatable({}, self)
end

--- @private
--- @return table[] config Each property the tab shows, in driver.xml order.
function TabProperties:_read()
  if self._config then
    return self._config
  end
  self._config = {}
  local group = ""
  for xml in XMLgCapture(C4:GetDriverConfigInfo("config") or "", "property") do
    local kind = XMLCapture(xml, "type")
    if kind == "LABEL" then
      group = XMLCapture(xml, "default") or ""
    elseif
      (SHOWN_TYPES[kind] or (kind == "DYNAMIC_LIST" and XMLCapture(xml, "name") == "Log Level"))
      and XMLCapture(xml, "password") ~= "true"
    then
      local property = {
        name = XMLCapture(xml, "name"),
        group = group,
        readonly = XMLCapture(xml, "readonly") == "true",
        description = XMLCapture(xml, "description"),
      }
      if kind == "DYNAMIC_LIST" then
        -- Log Level: the logger gives its choices, which a Support Code hour widens.
        property.logLevels = true
      elseif kind == "LIST" then
        property.choices = {}
        for item in XMLgCapture(xml, "item") do
          table.insert(property.choices, item)
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

--- @return table[] properties Each property the tab shows, with its current value: name, group (the label above it),
--- readonly, description, value, a list's choices, and a ranged integer's minimum and maximum.
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
--- @param config table
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
--- @param push fun()
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
