--- A driver's messages to its web tab. Each goes as one parameter, `json`, which lib/ui/page.js decodes for the page's
--- handler: the socket reads a bare `72.50`, `007` or `false` as a number or a boolean, and C4:SendDataToUI cannot carry
--- a boolean or a nested table at all. Base64 inside a message is broken with a space every 76 characters, not a
--- newline: the broker's cost grows with the longest unbroken run, and JSON writes a newline as `\n`, which doesn't
--- break one.

require("drivers-common-public.global.lib")

local Page = {}

--- Sends the web tab a message; nothing happens when no tab is open.
--- @param command string The page's handler for it.
--- @param data? table What it carries.
function Page.send(command, data)
  data = data or {}
  C4:SendDataToUI(command, { json = next(data) == nil and "{}" or JSON:encode(data) })
end

return Page
