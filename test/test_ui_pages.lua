-- The web tabs built on lib/ui: a page that embeds the kit embeds both its files at paths that resolve, and the kit's
-- page.js breaks a command's base64 the way lib.ui.page-params reads it.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_ui_pages.lua

local T = require("testlib")

local ROOT = (debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./") .. "../"
local KIT = { "style.css", "page.js" }

local function read(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

T.section("page.js")
local pageJs = read(ROOT .. "src/lib/ui/page.js") or ""
T.contains("breaks the body every 76 characters", pageJs, '.replace(/.{76}/g, "$&\\n")')
T.contains("sends it as the command's DATA", pageJs, "tParams: { DATA: encodeParams(params) }")

T.section("pages")
local listing = io.popen('find "' .. ROOT .. 'drivers" -path "*/www/html/*.html" 2>/dev/null')
local pages = {}
for path in listing:lines() do
  pages[#pages + 1] = path
end
listing:close()

local checked = 0
for _, path in ipairs(pages) do
  local html = read(path) or ""
  local dir = path:match("^(.*/)")
  local embeds = {}
  for rel in html:gmatch("<!%-%-%s*#embed%s+(%S+)%s*%-%->") do
    local name = rel:match("src/lib/ui/([^/]+)$")
    if name then
      embeds[name] = rel
    end
  end
  if next(embeds) then
    checked = checked + 1
    local page = path:sub(#ROOT + 1)
    for _, name in ipairs(KIT) do
      T.truthy(page .. " embeds " .. name, embeds[name])
      if embeds[name] then
        T.truthy(page .. "'s " .. name .. " path resolves", read(dir .. embeds[name]))
      end
    end
  end
end
print(checked .. " of " .. #pages .. " pages embed the kit")

T.finish()
