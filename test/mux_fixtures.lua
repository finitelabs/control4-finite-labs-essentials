-- Sensor Multiplexer fixtures: a thermostat proxy, with a C4-THERM behind it, as the
-- multiplexer's thermostat link sees it over Director.

require("c4_shim")
require("c4_local")

local F = {}

local VARIABLES = {
  "SCALE",
  "HVAC_MODE",
  "HVAC_STATE",
  "PRESET",
  "TEMPERATURE_C",
  "HEAT_SETPOINT_C",
  "COOL_SETPOINT_C",
}

--- Install a thermostat. Like C4-THERM, it applies a SET_PRESET only for a preset name
--- it has exactly, and reports the temperature it is sent on its remote sensor input.
--- @param opts table { presets = { { name, heat, cool } }, mode, preset, temperature }
--- @return table thermostat `.proxyId`, `.protocolId`, `.sent` (every command, in order, with
--- the temperatures sent to it), `:set(name, value)`, `:addPreset(name, heat, cool)` and `:restore()`.
function F.thermostat(opts)
  local t = { protocolId = 787, proxyId = 788, presets = {}, sent = {} }
  local variables, ids = {}, {}
  for i, name in ipairs(VARIABLES) do
    ids[name] = 1100 + i
    variables[tostring(ids[name])] = { name = name, value = "" }
  end

  function t:set(name, value)
    variables[tostring(ids[name])].value = tostring(value)
    OnWatchedVariableChanged(self.proxyId, ids[name], tostring(value))
  end

  function t:addPreset(name, heat, cool)
    table.insert(self.presets, { name = name, heat = heat, cool = cool })
  end

  for _, preset in ipairs(opts.presets or {}) do
    t:addPreset(preset.name, preset.heat, preset.cool)
  end

  ShimSetDevices({
    [t.protocolId] = { deviceName = "Thermostat", proxies = tostring(t.proxyId) },
    [t.proxyId] = { deviceName = "Thermostat", variables = variables },
  })
  variables[tostring(ids.SCALE)].value = "CELSIUS"
  variables[tostring(ids.HVAC_MODE)].value = opts.mode or "Cool"
  variables[tostring(ids.HVAC_STATE)].value = "Off"
  variables[tostring(ids.TEMPERATURE_C)].value = tostring(opts.temperature or "")
  for _, preset in ipairs(t.presets) do
    if preset.name == opts.preset then
      variables[tostring(ids.PRESET)].value = preset.name
      variables[tostring(ids.HEAT_SETPOINT_C)].value = tostring(preset.heat)
      variables[tostring(ids.COOL_SETPOINT_C)].value = tostring(preset.cool)
    end
  end

  local sendUIRequest, sendToDevice, sendToProxy = C4.SendUIRequest, C4.SendToDevice, C4.SendToProxy

  function C4:SendUIRequest(deviceId, request, params)
    if tonumber(deviceId) ~= t.proxyId or request ~= "GET_PRESETS" then
      return sendUIRequest(self, deviceId, request, params)
    end
    local out = { "<presets>" }
    for i, preset in ipairs(t.presets) do
      out[#out + 1] = string.format('<preset preset_id="%d" name="%s" preset_edit="all"/>', i, preset.name)
    end
    out[#out + 1] = "</presets>"
    return table.concat(out)
  end

  function C4:SendToDevice(deviceId, command, params)
    if tonumber(deviceId) ~= t.proxyId then
      return sendToDevice(self, deviceId, command, params)
    end
    table.insert(t.sent, { command = command, name = params.NAME })
    if command ~= "SET_PRESET" then
      return
    end
    for _, preset in ipairs(t.presets) do
      if preset.name == params.NAME then
        t:set("HEAT_SETPOINT_C", preset.heat)
        t:set("COOL_SETPOINT_C", preset.cool)
        t:set("PRESET", preset.name)
      end
    end
  end

  -- The multiplexer's only output in linked mode is the temperature the thermostat reads.
  function C4:SendToProxy(bindingId, command, params, ...)
    if command == "VALUE_CHANGED" and params and params.CELSIUS then
      table.insert(t.sent, { command = "TEMPERATURE", value = params.CELSIUS })
      t:set("TEMPERATURE_C", params.CELSIUS)
    end
    return sendToProxy(self, bindingId, command, params, ...)
  end

  function t:restore()
    C4.SendUIRequest, C4.SendToDevice, C4.SendToProxy = sendUIRequest, sendToDevice, sendToProxy
    ShimResetDevices()
  end

  return t
end

return F
