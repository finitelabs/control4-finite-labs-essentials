--- A web tab command's parameters. A page breaks its base64 with a newline every 76 characters, since the broker's cost
--- grows with the square of an unbroken run, and only OS 4.3's decoder is known to take them, so they are stripped here.

require("drivers-common-public.global.lib")

--- @param tParams table
--- @return table
return function(tParams)
  local encoded = (tParams.DATA or "e30="):gsub("%s", "")
  return JSON:decode(C4:Base64Decode(encoded))
end
