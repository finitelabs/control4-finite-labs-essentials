-- Control4 environment seams this repo's suites need that c4_shim.lua does not provide.

require("c4_shim")

--- As on Director, a property update is read back through Properties.
function C4:UpdateProperty(name, value)
  Properties[name] = value
end

--- One variable's value, by device and variable id.
function C4:GetDeviceVariable(deviceId, variableId)
  local variable = (C4:GetDeviceVariables(deviceId) or {})[tostring(variableId)]
  return variable and variable.value
end

--- As on Director, a new listener is told the variable's current value at once.
function C4:RegisterVariableListener(deviceId, variableId)
  local value = C4:GetDeviceVariable(deviceId, variableId)
  if value ~= nil then
    OnWatchedVariableChanged(deviceId, variableId, value)
  end
end

--- The proxies a protocol device carries, as Director's comma-separated id list.
function C4:GetProxyDevicesById(deviceId)
  local device = C4:GetDevices({ DeviceIds = tostring(deviceId) })[tonumber(deviceId)]
  local proxies = device and device.proxies
  if type(proxies) == "table" then
    return table.concat(proxies, ",")
  end
  return proxies or ""
end
