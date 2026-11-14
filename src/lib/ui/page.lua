--- A driver's messages to its web tab. Each goes as one parameter, `json`, which lib/ui/page.js decodes for the page's
--- handler: the socket reads a bare `72.50`, `007` or `false` as a number or a boolean, and C4:SendDataToUI cannot carry
--- a boolean or a nested table at all. A driver that puts base64 in a message breaks it with a space every 76
--- characters: the broker's cost grows with the square of an unbroken run, and JSON writes a newline as `\n`, which
--- doesn't break one.

require("drivers-common-public.global.lib")

local Page = {}

--- Sends the web tab a message; nothing happens when no tab is open.
--- @param command string The page's handler for it.
--- @param data? table What it carries.
function Page.send(command, data)
  data = data or {}
  C4:SendDataToUI(command, { json = next(data) == nil and "{}" or JSON:encode(data) })
end

--- Cuts text to at most `bytes` bytes without splitting a character, for a message's long text.
--- @param text string
--- @param bytes integer|nil No cut when nil.
--- @return string
function Page.cut(text, bytes)
  if not bytes or #text <= bytes then
    return text
  end
  local cut = text:sub(1, bytes)
  -- A lead byte without all its continuation bytes is not valid text; a whole character at the end stays.
  local tail = cut:match("[\192-\255][\128-\191]*$")
  if tail then
    local lead = tail:byte(1)
    local length = lead >= 240 and 4 or lead >= 224 and 3 or 2
    if #tail < length then
      cut = cut:sub(1, #cut - #tail)
    end
  end
  return cut
end

return Page
