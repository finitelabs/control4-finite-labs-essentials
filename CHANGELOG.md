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

- Added a Properties card at the top of the Network Requests and Variable
  Expressions tabs. It shows the driver's properties and sets them as Composer's
  Properties tab does, and a change made in either place shows in the other.

<!-- #ifdef DRIVERCENTRAL -->

- Added a `Support Code` property to the Device Programmer, Light Relay, Network
  Requests, Sensor Aggregator, Sensor Multiplexer and Variable Expressions
  drivers. A code from Finite Labs support opens the driver's Lua tab in
  Composer for an hour; leave it blank otherwise.
- Added a `Cloud Monitoring` property, Enabled by default, and a
  `Diagnostics Snapshot` action to every driver. Cloud Monitoring sends Finite
  Labs an hourly report of the driver's memory use and a report of each error it
  hits; the documentation says what they hold.
- Added a license check to every driver. Without an active DriverCentral license
  or trial, a driver stops five minutes after it loads and shows
  `No active license` in Driver Status: it sends nothing to its devices,
  proxies, events, variables or the network, and answers a webhook with 503. A
  license starts it again at once.

<!-- #endif -->

### Fixed

- Fixed a variable's value being able to break or run as part of a Variable
  Expressions expression. An equation now reads each value as data, so a text
  variable holding a quote no longer breaks it and no value can run as code.
- Fixed comparing a text variable in a Variable Expressions equation:
  `PARAM{96,Mode} == "On"` now compares the text. It was always false before.
- Fixed saving a long request or expression in the Network Requests and Variable
  Expressions tabs slowing the controller. The tabs now send long commands in a
  form the controller handles quickly.
- Fixed Network Requests' Webhook URL property reading
  `Failed to listen on port` after a port change or a driver update, while the
  webhook server was listening on the new port.
- Fixed Sensor Multiplexer's Selection Changed event leaving the device's name
  out of its script title in Composer Pro. The title now names the multiplexer.

### Changed

- Changed the drivers' icons and documentation header to a new Finite Labs
  Essentials mark.
- Removed the bar that held a single tab from the top of the Network Requests
  and Variable Expressions tabs. It returns if a driver gains a second tab.

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
