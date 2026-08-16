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

## v20260816 - 2026-08-16

### Fixed

- Fixed a device you had expanded and then collapsed disappearing from a
  variable-name search in the variable browser; its variables are re-fetched
  when a search would otherwise miss it. Affects Variable Expressions and
  Network Requests.

## v20260805 - 2026-08-05

### Added

- Added annotated screenshots of the Requests and Expressions tabs to the
  Network Requests and Variable Expressions documentation.

### Fixed

- Device Programmer, Light Relay, Sensor Aggregator, Sensor Multiplexer and
  Variable Expressions can now update themselves. Both the Update Drivers action
  and the automatic update check failed with an internal error, so these drivers
  could only be updated by installing a new release by hand. Network Requests
  was unaffected. The broken updater is also what would have fetched this fix,
  so copies already installed need one manual update in Composer; after that
  they keep themselves up to date as normal.
- Sensor Multiplexer now shows the Finite Labs icon in Composer and on
  Navigators instead of a generic placeholder.
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
