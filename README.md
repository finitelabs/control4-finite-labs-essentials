<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

<img alt="Finite Labs Essentials" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#059669">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by Control4.

Finite Labs Essentials is a collection of independent Control4 drivers that
extend your system with advanced management capabilities. Each driver operates
standalone and can be installed individually or together.

# <span style="color:#059669">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)

- [Included Drivers](#included-drivers)

  - [Sensor Aggregator](#sensor-aggregator)
  - [Sensor Multiplexer](#sensor-multiplexer)
  - [Device Programmer](#device-programmer)
  - [Light Relay](#light-relay)
  - [Variable Expressions](#variable-expressions)
  - [Network Requests](#network-requests)
  - [Humidity Alert](#humidity-alert)

- [Installation](#installation)

  - [Installing the Drivers](#installing-the-drivers)

- [Support](#support)

- [Changelog](#changelog)

</div>

# <span style="color:#059669">System Requirements</span>

- Control4 OS 3.3+

# <span style="color:#059669">Included Drivers</span>

## Sensor Aggregator

Combine multiple sensor inputs into single aggregated outputs using configurable
functions. Connect up to 20 temperature, 20 humidity, and 20 contact sensor
inputs from other Control4 drivers and produce aggregated output bindings.

**Key features:**

- Numeric aggregation: Mean, Median, Mode, Min, Max, IQR Mean
- Boolean aggregation: Any, All, Majority
- Separate aggregation settings per sensor type
- Dynamic input and output bindings
- Calibration report for identifying sensor offsets

## Sensor Multiplexer

Switch between named groups of sensor inputs, passing the selected group's
values to output bindings. Unlike the Sensor Aggregator which combines N inputs
into 1 via math, the Sensor Multiplexer selects 1-of-N named groups to pass
through.

**Key features:**

- Named input groups (e.g., Away, Home, Sleep)
- Temperature, humidity, and contact sensor support
- Programming command to select the active input
- Event fires when the active selection changes
- Per-name conditionals for programming logic

### Use Case: Thermostat Temperature Source

Use the Sensor Multiplexer with multiple Sensor Aggregators to feed different
temperature readings to a thermostat based on mode:

`Individual Sensors -> Sensor Aggregators (per-mode) -> Sensor Multiplexer -> Thermostat`

1. Create Sensor Aggregator instances for each mode (e.g., Away, Home, Sleep)
1. Connect appropriate sensors to each aggregator
1. Add a Sensor Multiplexer with Input Names set to `Away,Home,Sleep`
1. Connect aggregator outputs to multiplexer inputs
1. Connect multiplexer output to the thermostat
1. Use programming to switch modes via the "Select Input" command

See the individual Sensor Multiplexer documentation for the full walkthrough.

## Device Programmer

Create virtual sensors and relays controllable via Control4 programming. Enter
comma-delimited names per type (temperature, humidity, contact, relay) and the
driver exposes those as output bindings. Programming commands allow setting each
sensor's value or state, and opening, closing, or toggling relays.

**Key features:**

- Create virtual temperature, humidity, and contact sensors
- Create virtual relays that accept Open, Close, and Toggle commands
- Set sensor values and relay states via programming commands
- Dynamic output bindings based on configured names
- Persistent values survive driver restarts

## Light Relay

Gives each light you pick a relay connection, so a driver that switches a relay
can switch the light instead. Closing the relay turns the light on and opening
it turns the light off, and the light's state reports back as the relay's. One
driver instance covers all of a project's lights.

**Key features:**

- Single driver instance supports all your project's lights
- Dynamic relay bindings created per selected light
- Bidirectional state synchronization between light and relay
- Bulk hide all converted lights from navigators

## Variable Expressions

Extend Control4 programming with string building and math on variables. Define
named expressions in a dedicated Composer tab with a variable browser, syntax
highlighting, and a live preview. Each expression publishes its own result
variable and event, and can recalculate automatically when the variables it
references change.

**Key features:**

- Expressions tab with a searchable variable browser and live result preview
- Named expressions with per-expression `<Name> Result` variables and
  `<Name> Calculated` events
- Automatic recompute when referenced variables change, debounced for chatty
  sources
- Equation mode evaluates math; String mode builds text from variables
- Full Lua math library plus common helpers (`abs`, `min`, `max`, `round`, ...)
  and conditionals
- Rendered expression shows each reference as `[Room > Device > Variable]`
- Expressions and last results persist across driver restarts

## Network Requests

Send HTTP, raw TCP, UDP, and Wake-on-LAN commands to devices and services that
have no Control4 driver. Define requests once, by name, in a dedicated Composer
tab, then fire them from programming with a single Send Request command.

**Key features:**

- Requests tab with a searchable variable browser and per-request send history
- HTTP and HTTPS with any method, custom headers, bodies, and basic auth
- Raw TCP and UDP payloads as text (with escapes) or hex bytes; TCP can wait for
  the device's response
- Wake-on-LAN magic packets by MAC address
- Insert live Control4 variable values anywhere with `PARAM{}` tokens
- Per-request `<Name> Sent` / `<Name> Failed` events and a `<Name> Response`
  variable holding the last response
- Inbound webhooks fire `<Name> Received` events with the payload published to a
  `<Name> Payload` variable, guarded by an optional key
- A webhook can answer its caller with a response built from live Control4
  variable values, so other systems can read values by calling it
- Requests, webhooks, and last results persist across driver restarts

## Humidity Alert

Raise an alert when something adds moisture to a room and its humidity rises,
and hold it until the room has dried out. The driver reads a humidity and an
optional temperature connection and closes a contact output while the alert is
active. It looks for a jump above the level the room was resting at, so it needs
no adjustment between a dry winter and a humid summer.

**Key features:**

- Detection modes: Rise, Threshold, Rise or Threshold
- Follows the moisture in the air when the sensor's temperature is connected
- Optional reference sensor elsewhere in the house, so humidity the whole house
  shares does not count as the room's
- Ends an alert when the room has recovered, with a run-on time and a maximum
- Works with fast sensors and with battery sensors that report only large
  changes
- Contact output that fires programming once at the start and once at the end
- Switches a device itself, a bathroom exhaust fan for example, by a relay,
  light switches or a fan speed controller, and turns off only what it turned on
- Events, conditionals, variables and commands for programming

# <span style="color:#059669">Installation</span>

## Installing the Drivers

1. Download the latest `control4-finite-labs-essentials.zip` from
   [Github](https://github.com/finitelabs/control4-finite-labs-essentials/releases/latest).
1. Extract and install the desired `.c4z` driver files.
1. Use the "Search" tab in Composer Pro to find the driver by name and add it to
   your project.

Each driver includes its own documentation accessible from within Composer Pro.
Refer to the individual driver documentation for detailed property descriptions,
programming reference, and configuration guides.

# <span style="color:#059669">Support</span>

If you have any questions or issues integrating these drivers with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-finite-labs-essentials/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

# <span style="color:#059669">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## Unreleased

### Added

- Added `json(text, path)` to Variable Expressions, which reads one value from a
  variable that holds JSON, such as `json(PARAM{96,1003}, "$.sensors[0].temp")`.
- Humidity Alert can switch a device through Control4 timers: with Control
  Method Timer it sets the selected timers to On, which has no countdown, while
  an alert is active and to Off when it ends. A timer that gives a device turned
  on by hand its own countdown keeps doing so, and no longer cuts an alert
  short.

## v20261113 - 2026-11-13

### Added

- Added Humidity Alert, a driver that raises an alert when moisture raises a
  room's humidity and holds it until the room has dried out. It closes a contact
  output while the alert is active, can switch a relay, light switches or a fan
  speed controller with no Control4 programming, and can ignore humidity the
  whole house shares when a reference sensor is bound.
- Added an optional response to Network Requests webhooks, which answers the
  caller with text you write and the current values of the Control4 variables
  you insert into it.

## v20261112 - 2026-11-12

### Fixed

- Fixed saving text with accented letters or characters outside Western European
  alphabets in the Network Requests and Variable Expressions tabs.
- Fixed the Network Requests and Variable Expressions tabs dropping a value's
  zeros, showing nothing for 0 or false, and not updating an entry named only
  with digits.
- Fixed a variable's value being able to break a Variable Expressions equation
  or run as code in it.
- Fixed comparing a text variable with text in a Variable Expressions equation,
  which was always false.
- Fixed a variable that keeps changing holding off a Variable Expressions
  recalculation indefinitely.
- Fixed saving a long request or expression in the Network Requests and Variable
  Expressions tabs slowing the controller.
- Fixed Network Requests' Webhook URL property reading Failed to listen on port
  after a port change or driver update, while the webhook server was listening.
- Fixed Sensor Multiplexer's Selection Changed event leaving the device's name
  out of its programming line in Composer Pro.
- Fixed long names and values running past the edge of the Network Requests and
  Variable Expressions tabs.
- Fixed Sensor Aggregator's and Sensor Multiplexer's contact outputs firing
  Opened or Closed programming when no contact changed.
- Fixed Sensor Multiplexer's contact output not opening when the selected
  input's contact opened.
- Fixed a Network Requests TCP request to a host that never answers waiting
  forever instead of failing after its timeout.

### Changed

- Changed the drivers' icons and documentation header to a new Finite Labs
  Essentials mark.
- Changed the variable browser in the Network Requests and Variable Expressions
  tabs to list the project's agents along with its devices.
- Changed the Variable Expressions preview to explain an error in a plain
  sentence.

## v20260816 - 2026-08-16

### Fixed

- Fixed a device that was expanded and then collapsed disappearing from a
  variable-name search in the Variable Expressions and Network Requests variable
  browser.

## v20260805 - 2026-08-05

### Added

- Added annotated screenshots of the Requests and Expressions tabs to the
  Network Requests and Variable Expressions documentation.

### Fixed

- Device Programmer, Light Relay, Sensor Aggregator, Sensor Multiplexer and
  Variable Expressions can now update themselves. Copies already installed need
  one manual update in Composer to get this fix.
- Sensor Multiplexer now shows the Finite Labs icon in Composer and on
  Navigators instead of a generic placeholder.
- Fixed the delete button being cut off in the Requests and Expressions tabs.
- A device a driver shows through a proxy of the same name now appears once in
  the Variable Expressions and Network Requests variable browser, with its own
  variables listed first, and devices with no variables are hidden.
- The variable browser now refreshes each time it opens, so new devices and
  variables appear and the values shown are current.

## v20260712 - 2026-07-12

### Added

- Initial release of Network Requests, which sends named HTTP, TCP, UDP and
  Wake-on-LAN requests from programming, with variables in them, Sent and Failed
  events and each response kept. It also receives webhooks, guarded by an
  optional key, with a Received event and the payload in a variable.

## v20260711 - 2026-07-11

### Added

- Initial release of Device Programmer.
- Initial release of Light Relay.
- Initial release of Sensor Aggregator.
- Initial release of Sensor Multiplexer.
- Initial release of Variable Expressions.
