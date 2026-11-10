-- The web tabs built on lib/ui: a page that embeds the kit embeds its files, and each component's pair, at paths that
-- resolve; the kit's page.js breaks a command's base64 the way lib.ui.page-params reads it; style.css is the house base
-- by plain selector and the components' stylesheets style only their own .kit-* markup; and a page restyles no selector
-- the kit styles, since the kit's version is the house one.
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

T.section("style.css")
-- The house base, by plain selector. Anything else in the kit is a component's own .kit-* markup.
local BASE = {}
for _, selector in ipairs({
  ":root",
  "*",
  "[hidden]",
  "body",
  ".nav",
  ".nav.multi",
  ".nav-tab",
  ".nav-tab:hover",
  ".nav-tab.active",
  ".nav-meta",
  ".panel",
  ".panel.active",
  "::-webkit-scrollbar",
  "::-webkit-scrollbar-track",
  "::-webkit-scrollbar-thumb",
  "::-webkit-scrollbar-thumb:hover",
  ".banner",
  ".banner.warn",
  ".banner.err",
  ".card",
  ".card h3",
  ".card h3 .count",
  ".btn",
  ".btn-primary",
  ".btn-primary:hover",
  ".btn-danger",
  ".btn-danger:hover",
  ".btn-secondary",
  ".btn-secondary:hover",
  ".btn-outline",
  ".btn-outline:hover",
  ".btn.danger",
  ".btn.danger:hover",
  ".btn-ghost",
  ".btn-ghost:hover",
  ".btn-sm",
  ".btn:disabled",
  ".btn:focus-visible",
  "label",
  "label.check",
  'input[type="text"]',
  'input[type="number"]',
  'input[type="password"]',
  'input[type="search"]',
  'input[type="url"]',
  "textarea",
  "select",
  "input:focus",
  "textarea:focus",
  "select:focus",
  "input:disabled",
  "textarea:disabled",
  "select:disabled",
  ".input-error",
  ".table-wrap",
  "table",
  "th",
  "td",
  "tbody tr:hover td",
  "tbody tr:last-child td",
  ".trunc",
  ".note",
  ".hint",
  ".empty",
  ".save-error",
  ".chip",
  ".chip-err",
  ".status-dot",
  ".status-ok",
  ".status-warn",
  ".status-none",
  ".seg",
  ".seg button",
  ".seg button:first-child",
  ".seg button.on",
  ".card h3 .btn",
  "input.sm",
  "select.sm",
  "textarea.sm",
  ".note code",
  ".hint code",
  ".mono",
}) do
  BASE[selector] = true
end

--- Each selector a stylesheet's rules name, @media blocks included, comments out.
--- @param css string
--- @return string[]
local function selectors(css)
  local out = {}
  css = css:gsub("/%*.-%*/", ""):gsub("@keyframes[^{]*%b{}", "")
  css = css:gsub("@media[^{]*(%b{})", function(block)
    return block:sub(2, -2)
  end)
  for list in css:gmatch("([^{}]+){[^{}]*}") do
    for selector in list:gmatch("[^,]+") do
      selector = selector:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
      if selector ~= "" then
        out[#out + 1] = selector
      end
    end
  end
  return out
end

local KIT_CSS = { "style.css", "variables.css", "expressions.css" }
local kitSelectors = {}
for _, name in ipairs(KIT_CSS) do
  local css = read(ROOT .. "src/lib/ui/" .. name)
  if css then
    local stray = {}
    for _, selector in ipairs(selectors(css)) do
      kitSelectors[selector] = name
      local ok = selector:find("^%.kit%-") or (name == "style.css" and BASE[selector])
      if not ok then
        stray[#stray + 1] = selector
      end
    end
    T.eq(
      name .. " styles only " .. (name == "style.css" and "the house base and " or "") .. "its own .kit-* markup",
      stray,
      {}
    )
  end
end

T.section("pages")
local listing = io.popen('find "' .. ROOT .. 'drivers" -path "*/www/html/*.html" 2>/dev/null')
local pages = {}
for path in listing:lines() do
  pages[#pages + 1] = path
end
listing:close()

-- Each component's script comes with its stylesheet.
local PAIRS = { ["variables.js"] = "variables.css", ["expressions.js"] = "expressions.css" }

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
    end
    for name, rel in pairs(embeds) do
      T.truthy(page .. "'s " .. name .. " path resolves", read(dir .. rel))
    end
    for script, partner in pairs(PAIRS) do
      if embeds[script] then
        T.truthy(page .. " embeds " .. partner .. " with " .. script, embeds[partner])
      end
    end
    local copies = {}
    for style in html:gmatch("<style>(.-)</style>") do
      for _, selector in ipairs(selectors(style)) do
        -- A page's own tokens go in :root beside the kit's.
        if kitSelectors[selector] and selector ~= ":root" then
          copies[#copies + 1] = selector
        end
      end
    end
    T.eq(page .. " restyles nothing the kit styles", copies, {})
  end
end
print(checked .. " of " .. #pages .. " pages embed the kit")

T.finish()
