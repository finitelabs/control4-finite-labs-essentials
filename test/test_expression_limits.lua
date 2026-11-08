-- The expression sandbox's limits on time and memory: an expression that never ends, makes a
-- huge string or searches with a pattern that backtracks without end fails with a plain error,
-- and the driver carries on. Ordinary expressions are unaffected.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_expression_limits.lua

local T = require("testlib")

require("c4_shim")

local sandbox = require("lib.expression-sandbox")

--- Evaluate and report the error and how long it took, in seconds.
local function eval(expression, bindings)
  local start = os.clock()
  local result, err = sandbox.eval(expression, bindings)
  return result, err, os.clock() - start
end

--- The most memory an expression leaves held as it fails, in MB, wherever the checks fall in
--- its loop: each run pads its start by one more instruction. Returns the last run's error.
local function heldAtFailure(before, loop)
  local most, err = 0, nil
  for pad = 0, 7 do
    collectgarbage("collect")
    local start = collectgarbage("count")
    _, err = sandbox.eval("(function() " .. before .. (" local a = 1"):rep(pad) .. " " .. loop .. " end)()")
    most = math.max(most, (collectgarbage("count") - start) / 1024)
  end
  return most, err
end

local function fails(name, expression, wanted, bindings)
  local result, err, seconds = eval(expression, bindings)
  T.eq(name .. ": no result", result, nil)
  T.contains(name .. ": fails plainly", err or "", wanted)
  T.check(name .. ": in under a second", seconds < 1, seconds)
end

local LOOP = "(function() while true do end end)()"

T.section("an expression that never ends fails, and the driver carries on")
do
  fails("an endless loop", LOOP, "runtime error: the expression ran too long")
  fails("an endless repeat", "(function() local n = 0 repeat n = n + 1 until false end)()", "ran too long")
  fails("endless tail calls", "(function() local function f() return f() end return f() end)()", "ran too long")
  fails("a loop in a gsub callback", '("abc"):gsub(".", function() while true do end end)', "ran too long")
  fails(
    "a loop over gmatch",
    '(function() for _ in ("a b"):gmatch("%a") do while true do end end end)()',
    "ran too long"
  )
  -- Each pads the error by one more instruction, so in one of them a check falls while it's raised.
  for pad = 0, 8 do
    local expression = "(function() local s = ('x'):rep(2^20) s = s .. s .. s .. s .. s"
      .. (" local a = 1"):rep(pad)
      .. " return s + 1 end)()"
    local _, err = sandbox.eval(expression)
    T.truthy(
      "an error raised with memory over the limit keeps a plain message, padded " .. pad,
      err and (err:find("perform arithmetic", 1, true) or err:find("too much memory", 1, true)),
      err
    )
  end
  T.eq("the next expression evaluates", sandbox.eval("1 + 1"), 2)
  T.eq("no hook is left behind", debug.gethook(), nil)
  T.eq("and strings' methods are the real ones again", getmetatable("").__index, string)
  T.eq("string.rep is the real one", ("ab"):rep(3), "ababab")
end

T.section("a string over 1 MB isn't made")
do
  fails("rep through a string's method", '("x"):rep(2^30)', "the expression made a string over 1 MB")
  fails("rep through the string table", 'string.rep("x", 2^30)', "over 1 MB")
  fails("rep with a separator", 'string.rep("x", 600000, "y")', "over 1 MB")
  T.eq("one just under is made", #sandbox.eval('("ab"):rep(500000)'), 1000000)
  fails(
    "format of many copies",
    '(function() local s = ("x"):rep(2^19) return ("%s%s%s"):format(s, s, s) end)()',
    "over 1 MB"
  )
  fails("format's %q, which writes \\127 as four characters", '("%q"):format(("\\127"):rep(300000))', "over 1 MB")
  fails("gsub that copies each match", '("x"):rep(2^18):gsub(".", "%0%0%0%0%0")', "over 1 MB")
  fails("gsub with long replacements", '("x"):rep(1000):gsub(".", { x = ("y"):rep(2^11) })', "over 1 MB")
  T.eq("gsub that shrinks a long string", (sandbox.eval('(("ab"):rep(400000):gsub("b", ""))')), ("a"):rep(400000))
end

T.section("an expression that grows memory fails, before it holds much")
do
  local start = "local s = ('x'):rep(1024)"
  local mb, err = heldAtFailure(start, "while true do s = s .. s end")
  T.contains("doubling a string by concatenating it", err or "", "the expression used too much memory")
  T.check("holding under 16 MB", mb < 16, mb)
  mb, err = heldAtFailure(start, "while true do s = s .. s .. s .. s end")
  T.contains("four copies at a time", err or "", "too much memory")
  T.check("under 16 MB", mb < 16, mb)
  mb, err = heldAtFailure(start, "while true do s = s .. s .. s .. s .. s .. s .. s .. s end")
  T.contains("eight", err or "", "too much memory")
  T.check("under 16 MB", mb < 16, mb)
  mb, err = heldAtFailure("local s = ('x'):rep(2^16)", "return ('x'):rep(1000):gsub('.', function() return s end)")
  T.contains("gsub with a callback's long results", err or "", "too much memory")
  T.check("under 16 MB", mb < 16, mb)
  collectgarbage("stop")
  local built = sandbox.eval("(function() local s = '' for i = 1, 5000 do s = s .. 'x' end return #s end)()")
  collectgarbage("restart")
  T.eq("a string built a character at a time is made, though its garbage passes the limit", built, 5000)
  local _, tableErr = eval("(function() local t, i = {}, 0 while true do i = i + 1 t[i] = i end end)()")
  T.truthy(
    "a table that never stops growing fails",
    tableErr and (tableErr:find("too much memory") or tableErr:find("ran too long")),
    tableErr
  )
end

T.section("a pattern search that would backtrack too long isn't run")
do
  fails(
    "two runs of the same character",
    '("a"):rep(4000):find("a*a*b")',
    "a pattern search in the expression would take too long"
  )
  fails("three lazy runs of anything", '("a"):rep(200):match(".-.-.-b")', "would take too long")
  fails("in gmatch", '("a"):rep(3000):gmatch("a-a-b")', "would take too long")
  fails("in gsub", '("a"):rep(3000):gsub("a*a*b", "")', "would take too long")
  fails(
    "a ^ that gmatch reads as a character",
    '("^" .. ("a"):rep(300)):rep(100):gmatch("^a*a*c")',
    "would take too long"
  )
  fails(
    "a plain find of a long needle in a long subject",
    '("a"):rep(2^20):find(("a"):rep(20) .. "b", 1, true)',
    "would take too long"
  )
  fails(
    "a long pattern over a long subject, without counting more",
    '("a"):rep(2^20):find(("a"):rep(999) .. "b")',
    "would take too long"
  )
  fails(
    "a pattern over 1000 characters",
    '("x"):find(("a"):rep(1001))',
    "a pattern in the expression is over 1000 characters"
  )
  T.eq("a plain find takes a longer one", sandbox.eval('("x"):rep(10):find(("x"):rep(1001), 1, true)'), nil)
  fails("runs of a set that excludes ]", '("a"):rep(1500):find("[^]]*[^]]*b")', "would take too long")
  fails("runs of a set holding an escaped ]", '("a"):rep(1500):find("[%]a]*[%]a]*b")', "would take too long")
  fails("a balanced match scanned from every start", '("("):rep(2^16):find("%b()x")', "would take too long")
  fails(
    "optional characters tried both ways",
    '("a"):rep(24):find(("a?"):rep(24) .. ("a"):rep(24) .. "b")',
    "would take too long"
  )
  -- Counted the most it could be: a fixed start can overlap itself at each of its characters.
  fails("a fixed start that overlaps itself", '("a"):rep(150):find(("a"):rep(50) .. ".-.-b")', "would take too long")
  fails(
    "searches that each pass, in a loop, add up",
    '(function() local s = ("a"):rep(1400) while true do s:find(".-b") end end)()',
    "would take too long"
  )
  fails(
    "plain finds the same",
    '(function() local s = ("a"):rep(2^19) while true do s:find("b", 1, true) end end)()',
    "would take too long"
  )
  fails("find from a NaN start, which searches it all", '("a"):rep(2000):find("a*a*b", 0/0)', "would take too long")
  fails("match the same", '("a"):rep(2000):match("a*a*b", 0/0)', "would take too long")
  fails("a fractional start below zero", '("a"):rep(2000):find("a*a*b", -0.5)', "would take too long")
  fails("a start past 32 bits", '("a"):rep(2000):find("a*a*b", 2^40)', "would take too long")
  fails(
    "a start before the subject, which searches it all",
    '("a"):rep(2000):find("a*a*b", -5000)',
    "would take too long"
  )
  T.eq(
    "a start just past the end searches nothing",
    sandbox.eval(
      '("a"):rep(4000):find("a*a*b", 4001) == nil and ("a"):rep(4000):find("a*a*b", 4002) == nil and "searched"'
    ),
    "searched"
  )
  fails("a plain find from a NaN start", '("a"):rep(2^20):find(("a"):rep(19) .. "b", 0/0, true)', "would take too long")
  T.eq(
    "a search from near the end counts from there",
    sandbox.eval('("a"):rep(4000):find("a*a*b", 3990) == nil and "searched"'),
    "searched"
  )
  T.eq(
    "a plain find from near the end the same",
    sandbox.eval('("a"):rep(2^20):find(("a"):rep(19) .. "b", 2^20 - 5, true) == nil and "searched"'),
    "searched"
  )
  local _, tailErr, tailSeconds =
    eval('(function() local s = ("a"):rep(2^20) .. ("b"):rep(2^20) while true do s:find("a*b", -10) end end)()')
  T.contains("searches of a long subject's tail run until the instruction limit", tailErr or "", "ran too long")
  T.check("without scanning the whole subject each time", tailSeconds < 1, tailSeconds)
  local walk = "(function() local s, n, at = __p[1], 0, 1 while true do "
    .. 'local i, j = s:find("%d+", at) if not i then return n end n = n + 1 at = j + 1 end end)()'
  T.eq("a loop that walks a subject's matches with find", sandbox.eval(walk, { ("reading 12.5, "):rep(100) }), 200)
  local count = '(function() local n = 0 for _ in __p[1]:gmatch("%d+") do n = n + 1 end return n end)()'
  T.eq("gmatch walks a longer one", sandbox.eval(count, { ("reading 12.5, "):rep(4000) }), 8000)
  T.raises("a malformed pattern still reports Lua's own error", function()
    local _, err = sandbox.eval('("x"):find("[a")')
    error(err)
  end, "malformed pattern")
end

T.section("ordinary expressions are unaffected")
do
  local json = '{"name":"Kitchen","temp":21.5,"humidity":40,"pad":"' .. ("x"):rep(5000) .. '"}'
  local cases = {
    { "round((__p[1] * 9 / 5) + 32, 1)", 70.7, { 21.5 } },
    { "__p[1] > 50 and 1 or 0", 1, { 72 } },
    { 'string.format("%.1f F", c2f(21.5))', "70.7 F" },
    { 'abs(__p[1] - __p[2]) > 5 and "Check" or "OK"', "Check", { 48, 40 } },
    { "(function() local s = 0 for i = 1, 100000 do s = s + i end return s end)()", 5000050000 },
    { '(__p[1]:match("^%s*(.-)%s*$"))', "Living room", { "   Living room   " } },
    { '(__p[1]:match("^%s*(.-)%s*$"))', ("y "):rep(30000) .. "y", { "  " .. ("y "):rep(30000) .. "y  " } },
    { '(__p[1]:match("^%s*(.-)%s*$"))', ("^ "):rep(29999) .. "^", { ("^ "):rep(30000) } },
    { "tonumber(__p[1]:match('\"temp\":(.-),'))", 21.5, { json } },
    { 'tonumber((__p[1]:match("(%d+)%.(%d+)")))', 4, { ("Firmware version 4.12 of the dimmer. "):rep(20) } },
    {
      '(function() local n = 0 for _ in __p[1]:gmatch("%a+") do n = n + 1 end return n end)()',
      4,
      { "one two, three four" },
    },
    { '(__p[1]:match("%b()"))', "(b (c))", { "a (b (c)) d" } },
    { '(__p[1]:gsub("%f[%w]%w+", string.upper))', "HELLO, WORLD", { "hello, world" } },
    { '(__p[1]:gsub("[]]", ""))', "ab", { "a]b]" } },
    { '__p[1]:find("o", 6)', 10, { "foo bar foo" } },
    { '__p[1]:find(".", 1, true)', 4, { "abc.def" } },
    { '("ab"):rep(3, "-")', "ab-ab-ab" },
    { 'device_name(100) .. " in " .. room_name(100)', "Battery in Garage" },
  }
  ShimSetDevices({ [100] = { deviceName = "Battery", roomName = "Garage" } })
  for _, case in ipairs(cases) do
    local result, err = sandbox.eval(case[1], case[3])
    T.eq(case[1]:sub(1, 70), err or result, case[2])
  end
end

T.section("the driver's own code runs outside the limits")
do
  local realGetDevice = GetDevice
  local inside
  GetDevice = function(id)
    inside = { hook = debug.gethook(), index = getmetatable("").__index }
    return realGetDevice(id)
  end
  sandbox.eval("device_name(100)")
  GetDevice = realGetDevice
  T.eq("no hook counts its instructions", inside.hook, nil)
  T.eq("and its strings' methods are the real ones", inside.index, string)
end

T.section("a hook the driver set is put back")
do
  local hook = function() end
  debug.sethook(hook, "", 1000000)
  sandbox.eval("1 + 1")
  T.eq("after an expression that succeeds", debug.gethook(), hook)
  sandbox.eval(LOOP)
  T.eq("and after one that fails", debug.gethook(), hook)
  debug.sethook()
end

T.finish()
