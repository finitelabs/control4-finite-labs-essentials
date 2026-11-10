--- A web tab command's parameters: JSON in base64 in tParams.DATA. lib/ui/page.js breaks the base64 with a newline
--- every 76 characters, and only OS 4.3's decoder is known to take them, so they are stripped here. A body that does
--- not decode reads as no parameters, with a warning, so a handler never has to guard the call.

require("drivers-common-public.global.lib")

local log = require("lib.logging")

--- @param tParams table|nil
--- @return table params
return function(tParams)
  local encoded = tostring((tParams or {}).DATA or "e30="):gsub("%s", "")
  local ok, decoded = pcall(function()
    return JSON:decode(C4:Base64Decode(encoded))
  end)
  if ok and type(decoded) == "table" then
    return decoded
  end
  log:warn("A web tab command's parameters did not decode")
  return {}
end
