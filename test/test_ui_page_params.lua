-- lib.ui.page-params: a web tab command's parameters, as lib/ui/page.js sends them with a newline every 76 characters.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_ui_page_params.lua

local T = require("testlib")

require("c4_shim")

local pageParams = require("lib.ui.page-params")

--- A command's parameters as page.js's encodeParams sends them.
local function asPageSends(t)
  return { DATA = (C4:Base64Encode(JSON:encode(t)):gsub(string.rep(".", 76), "%0\n")) }
end

--- Text from every length of UTF-8, with what XML reads as markup.
local TEXT = "caf\195\169 \230\151\165\230\156\172 \240\159\146\161 <a&b>"
local LONG = string.rep("A long value. ", 200)

local sent = asPageSends({ text = TEXT, long = LONG })
T.truthy("the page's body is broken into lines", sent.DATA:find("\n", 1, true))
local got = pageParams(sent)
T.eq("text in every length of UTF-8 reads back", got.text, TEXT)
T.eq("a long value reads back", got.long, LONG)
T.eq("an unbroken body reads too", pageParams({ DATA = C4:Base64Encode(JSON:encode({ a = 1 })) }).a, 1)
T.eq("no DATA reads as no parameters", next(pageParams({})), nil)
T.eq("a body that is not base64 JSON reads as no parameters", next(pageParams({ DATA = "not base64 json" })), nil)
T.eq("nor does JSON that is not an object", next(pageParams({ DATA = C4:Base64Encode("42") })), nil)

T.finish()
