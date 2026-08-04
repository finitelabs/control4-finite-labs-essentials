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
