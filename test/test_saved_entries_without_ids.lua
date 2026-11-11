-- What lib/conditionals.lua and lib/events.lua do with a saved record that comes back without its id, or as
-- something other than a table. Restoring events and finding the next free id indexed by that id, so one such
-- record threw "table index is nil" at the start of OnDriverLateInit and stopped the driver from starting.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_saved_entries_without_ids.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.handlers") -- TC

local persist = require("lib.persist")

--- Saves records under key the way a driver might find them: one whole, one without its id and one that is not a
--- table. Then fresh modules read them back, as after a restart.
local function savedAfterRestart(key, whole, noId)
  persist:set(key, { Buttons = { whole = whole, noId = noId, notATable = "x" } })
  ShimPersistLand()
  T.unload("^lib%.")
  ShimResetEvents()
  persist = require("lib.persist")
end

--- The keys of t, sorted.
local function keys(t)
  local out = {}
  for k in pairs(t or {}) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

T.section("a saved conditional without its id is skipped")
savedAfterRestart(
  "Conditionals",
  { conditionalId = 10, name = "CONDITIONAL_10", type = "BOOL", condition_statement = "IS", description = "Whole" },
  { name = "CONDITIONAL_LOST", type = "BOOL", condition_statement = "IS", description = "Lost its id" }
)
local conditionals = require("lib.conditionals")
local ok, added = pcall(conditionals.upsertConditional, conditionals, "Buttons", "new", {
  type = "BOOL",
  condition_statement = "IS",
  description = "New",
}, function()
  return true
end)
T.truthy("a new one is added", ok, added)
T.eq("under the next free id", ok and added.conditionalId, 11)

T.section("a saved event without its id is skipped")
savedAfterRestart(
  "Events",
  { eventId = 10, name = "Whole", description = "When whole" },
  { name = "Lost", description = "Lost its id" }
)
local events = require("lib.events")
T.truthy("restoreEvents runs", pcall(events.restoreEvents, events))
T.eq("and declares only the whole one", keys(ShimEvents()), { 10 })
ok, added = pcall(events.getOrAddEvent, events, "Buttons", "new", "New", "When new")
T.truthy("a new one is added", ok, added)
T.eq("under the next free id", ok and added.eventId, 11)

T.finish()
