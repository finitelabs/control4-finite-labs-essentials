# <span style="color:#109EFF">Changelog</span>

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

- Added annotated screenshots of the Requests and Expressions tabs to the
  Network Requests and Variable Expressions documentation.

### Fixed

- Fixed the delete button being cut off in the Requests and Expressions tabs.
- Variable Expressions and Network Requests: a device that a driver exposes
  through a proxy of the same name now appears once in the variable browser
  instead of several times, with its variables grouped by where they come from.
  Proxies that stand for something of their own, such as a security panel's
  areas or a receiver's tuner, are still listed separately. Devices with no
  variables are hidden, and any that still share a room and name are labelled
  with their device id. A device's own variables are always listed first.
- The variable browser now refreshes each time it opens, so devices and
  variables created during the session appear without reloading the tab, and the
  values shown are current rather than those from when a device was first
  expanded.

## v20260712 - 2026-07-12

### Added

- Initial release of Network Requests: named HTTP, TCP, UDP, and Wake-on-LAN
  requests defined in a Requests tab and fired from programming by name, with
  `PARAM{}` variable templating, per-request Sent/Failed events, and response
  capture. Inbound webhooks fire per-webhook Received events with the payload
  published to a variable, guarded by an optional key.

## v20260711 - 2026-07-11

### Added

- Initial release of Device Programmer
- Initial release of Light Relay
- Initial release of Sensor Aggregator
- Initial release of Sensor Multiplexer
- Initial release of Variable Expressions
