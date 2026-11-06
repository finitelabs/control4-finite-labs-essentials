-- The Sensor Multiplexer's contact output follows the selected input and fires Opened or Closed programming only when
-- the output really changes. A start or a bind tells Control4 with the silent STATE_ form, and only a state the output
-- does not show yet.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_sensor_multiplexer_contact.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")
local bindings = require("lib.bindings")

local function input(name)
  return bindings:getDynamicBinding("In:" .. name, "contact").bindingId
end

local function output()
  return bindings:getDynamicBinding("Output", "contact").bindingId
end

--- What `fn` tells the contact output, as its commands joined by "; " ("" for nothing).
local function told(fn)
  local effects = H.run(fn)
  local prefix = "proxy " .. output() .. " "
  local out = {}
  for line in (effects .. "; "):gmatch("(.-); ") do
    if line:sub(1, #prefix) == prefix then
      out[#out + 1] = line:sub(#prefix + 1)
    end
  end
  return table.concat(out, "; ")
end

local function report(name, command)
  return told(function()
    ReceivedFromProxy(input(name), command, {})
  end)
end

local function bound(name, isBound)
  return told(function()
    OnBindingChanged(input(name), "CONTACT_SENSOR", isBound, 500, 1)
  end)
end

local function selectInput(name)
  return told(function()
    ExecuteCommand("Select Input", { Input = name })
  end)
end

local function start()
  return told(function()
    H.load("sensor_multiplexer", H.LICENSED, { ["Input Names"] = "Upstairs,Downstairs", ["Enable Contact"] = "Yes" })
    H.reads(1)
  end)
end

T.section("sensor_multiplexer: the selected input's contact changing fires its programming")
T.eq("the first load", start(), "")
T.eq("the selected input", Properties["Active Input Name"], "Upstairs")
T.eq("its contact closing closes the output", report("Upstairs", "CLOSED"), "CLOSED")
T.eq("the same state again tells nothing", report("Upstairs", "CLOSED"), "")
T.eq("its contact opening opens the output", report("Upstairs", "OPENED"), "OPENED")
T.eq("another input's contact tells nothing", report("Downstairs", "CLOSED"), "")
T.eq("its contact closing again", report("Upstairs", "CLOSED"), "CLOSED")

T.section("sensor_multiplexer: selecting an input fires programming only when the output changes")
T.eq("an input with the same state", selectInput("Downstairs"), "")
T.eq("the selected input again", selectInput("Downstairs"), "")
report("Upstairs", "OPENED")
T.eq(
  "Cycle Input to an open input",
  told(function()
    ExecuteCommand("Cycle Input", {})
  end),
  "OPENED"
)

T.section("sensor_multiplexer: an input bound again tells nothing the output already shows")
T.eq("its contact closing", report("Upstairs", "CLOSED"), "CLOSED")
T.eq("its unbind", bound("Upstairs", false), "")
T.eq("its bind", bound("Upstairs", true), "")
T.eq("the sensor's state at its bind", report("Upstairs", "STATE_CLOSED"), "")
bound("Upstairs", false)
bound("Upstairs", true)
T.eq("a sensor that tells its state at a bind as a change", report("Upstairs", "CLOSED"), "")
bound("Upstairs", false)
bound("Upstairs", true)
T.eq("an open sensor bound in its place opens the output silently", report("Upstairs", "STATE_OPENED"), "STATE_OPENED")
T.eq("then a real change", report("Upstairs", "CLOSED"), "CLOSED")

T.section("sensor_multiplexer: a selected input with no state yet takes its first state silently")
T.eq("the other input's unbind", bound("Downstairs", false), "")
T.eq("selecting it keeps the output", selectInput("Downstairs"), "")
T.eq("its bind", bound("Downstairs", true), "")
T.eq("its sensor's state at the bind", report("Downstairs", "STATE_CLOSED"), "")
T.eq("then a real change", report("Downstairs", "OPENED"), "OPENED")
T.eq("and back", report("Downstairs", "CLOSED"), "CLOSED")

T.section("sensor_multiplexer: a start tells the output's state silently")
T.eq("a restart", start(), "STATE_CLOSED")
T.eq("a sensor's state told again at its own start", report("Downstairs", "STATE_CLOSED"), "")
T.eq("then a real change", report("Downstairs", "OPENED"), "OPENED")

T.section("sensor_multiplexer: a start with no state for the selected input takes its first state silently")
T.eq("the selected input's unbind", bound("Downstairs", false), "")
T.eq("a restart", start(), "")
T.eq("a sensor's state at its own start", report("Downstairs", "STATE_CLOSED"), "STATE_CLOSED")
T.eq("then a real change", report("Downstairs", "OPENED"), "OPENED")

T.section("sensor_multiplexer: a newly bound output takes the selected input's state silently")
local rebound = told(function()
  OnBindingChanged(output(), "CONTACT_SENSOR", false, 600, 1)
  OnBindingChanged(output(), "CONTACT_SENSOR", true, 601, 1)
end)
T.eq("an output bound to another contact", rebound, "STATE_OPENED")
T.eq("then a real change", report("Downstairs", "CLOSED"), "CLOSED")
T.eq("the selected input's unbind", bound("Downstairs", false), "")
rebound = told(function()
  OnBindingChanged(output(), "CONTACT_SENSOR", false, 601, 1)
  OnBindingChanged(output(), "CONTACT_SENSOR", true, 602, 1)
end)
T.eq("an output bound while the selected input has no state", rebound, "")
bound("Downstairs", true)
T.eq("the first state it gets", report("Downstairs", "STATE_CLOSED"), "STATE_CLOSED")

if H.gate and H.gate._timer then
  H.gate._timer:Cancel()
end
T.finish()
