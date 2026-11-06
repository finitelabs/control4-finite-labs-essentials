-- The Sensor Aggregator's contact output fires Opened or Closed programming only when its inputs' devices change.
-- A start or a bind tells Control4 with the silent STATE_ form, and only a state the output does not show yet.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_sensor_aggregator_contact.lua

require("c4_shim")
local T = require("testlib")
local H = require("license_harness")
local bindings = require("lib.bindings")

local function input(i)
  return bindings:getDynamicBinding("ContactIn", "input_" .. i).bindingId
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

local function report(i, command)
  return told(function()
    ReceivedFromProxy(input(i), command, {})
  end)
end

local function bound(i, isBound)
  return told(function()
    OnBindingChanged(input(i), "CONTACT_SENSOR", isBound, 500 + i, 1)
  end)
end

local function start()
  return told(function()
    H.load("sensor_aggregator", H.LICENSED, { ["Contact Inputs"] = "2" })
    H.reads(1)
  end)
end

T.section("sensor_aggregator: a contact that changes fires its programming")
T.eq("the first load", start(), "")
T.eq("an input closing closes the output", report(1, "CLOSED"), "CLOSED")
T.eq("the same state again tells nothing", report(1, "CLOSED"), "")
T.eq("the input opening opens the output", report(1, "OPENED"), "OPENED")
T.eq("a second input closing closes the output", report(2, "CLOSED"), "CLOSED")

T.section("sensor_aggregator: an unbind that changes the output fires no programming")
T.eq("the closed input's unbind opens the output silently", bound(2, false), "STATE_OPENED")
T.eq("its bind", bound(2, true), "")
T.eq("its sensor's state at the bind closes the output silently", report(2, "STATE_CLOSED"), "STATE_CLOSED")
T.eq("then a real change", report(2, "OPENED"), "OPENED")

T.section("sensor_aggregator: an input bound again tells nothing the output already shows")
T.eq("an input closing", report(1, "CLOSED"), "CLOSED")
T.eq("the other input's unbind", bound(2, false), "")
T.eq("the last input's unbind", bound(1, false), "")
T.eq("its bind", bound(1, true), "")
T.eq("the sensor's state at its bind", report(1, "STATE_CLOSED"), "")
bound(1, false)
bound(1, true)
T.eq("a sensor that tells its state at a bind as a change", report(1, "CLOSED"), "")
bound(1, false)
bound(1, true)
T.eq("an open sensor bound in its place opens the output silently", report(1, "STATE_OPENED"), "STATE_OPENED")
T.eq("then a real change", report(1, "CLOSED"), "CLOSED")

T.section("sensor_aggregator: a start tells the output's state silently")
T.eq("a restart", start(), "STATE_CLOSED")
T.eq("a sensor's state told again at its own start", report(1, "STATE_CLOSED"), "")
T.eq("then a real change", report(1, "OPENED"), "OPENED")

T.section("sensor_aggregator: a start with no input state yet takes the sensors' first states silently")
T.eq("the last input's unbind", bound(1, false), "")
T.eq("a restart", start(), "")
T.eq("a sensor's state at its own start", report(1, "STATE_OPENED"), "STATE_OPENED")
T.eq("then a real change", report(1, "CLOSED"), "CLOSED")

T.section("sensor_aggregator: a newly bound output takes the aggregate silently")
local rebound = told(function()
  OnBindingChanged(output(), "CONTACT_SENSOR", false, 600, 1)
  OnBindingChanged(output(), "CONTACT_SENSOR", true, 601, 1)
end)
T.eq("an output bound to another contact", rebound, "STATE_CLOSED")
T.eq("then a real change", report(1, "OPENED"), "OPENED")
T.eq("the last input's unbind", bound(1, false), "")
rebound = told(function()
  OnBindingChanged(output(), "CONTACT_SENSOR", false, 601, 1)
  OnBindingChanged(output(), "CONTACT_SENSOR", true, 602, 1)
end)
T.eq("an output bound while no input has a state", rebound, "")
bound(1, true)
T.eq("the first state it gets", report(1, "STATE_OPENED"), "STATE_OPENED")

if H.gate and H.gate._timer then
  H.gate._timer:Cancel()
end
T.finish()
