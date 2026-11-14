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

<!-- #ifdef DRIVERCENTRAL -->

## v20261112 - 2026-11-12

### Added

- Added the Device Programmer, Light Relay, Network Requests, Sensor Aggregator,
  Sensor Multiplexer and Variable Expressions drivers to DriverCentral.

<!-- #endif -->

<!-- #ifndef DRIVERCENTRAL -->

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

<!-- #endif -->
