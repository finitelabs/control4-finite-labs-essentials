[copyright]: # "Copyright 2026 Finite Labs, LLC. All rights reserved."

<style>
@media print {
   .noprint {
      visibility: hidden;
      display: none;
   }
   * {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
}
</style>

<img alt="Finite Labs Essentials" src="./images/header.png" width="500"/>

---

# <span style="color:#109EFF">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by Control4.

<!-- #endif -->

Finite Labs Essentials is a collection of independent Control4 drivers that
extend your system with advanced management capabilities. Each driver operates
standalone and can be installed individually or together.

# <span style="color:#109EFF">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Included Drivers](#included-drivers)
  - [Sensor Aggregator](#sensor-aggregator)
  - [Sensor Multiplexer](#sensor-multiplexer)
  - [Device Programmer](#device-programmer)
  - [Light Relay](#light-relay)
- [Installation](#installation)
  <!-- #ifdef DRIVERCENTRAL -->
  - [DriverCentral Cloud Setup](#drivercentral-cloud-setup)
  <!-- #endif -->
  - [Installing the Drivers](#installing-the-drivers)
  <!-- #ifdef DRIVERCENTRAL -->
- [Developer Information](#developer-information)
<!-- #endif -->
- [Support](#support)
- [Changelog](#changelog)

</div>

<div style="page-break-after: always"></div>

# <span style="color:#109EFF">System Requirements</span>

- Control4 OS 3.3+

# <span style="color:#109EFF">Included Drivers</span>

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
2. Connect appropriate sensors to each aggregator
3. Add a Sensor Multiplexer with Input Names set to `Away,Home,Sleep`
4. Connect aggregator outputs to multiplexer inputs
5. Connect multiplexer output to the thermostat
6. Use programming to switch modes via the "Select Input" command

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

Dynamically creates relay connections for one or more selected light devices
using a single driver instance. This enables controlling devices that use relay
drivers (e.g., fans, fireplaces) from a light switch, with bidirectional state
synchronization.

**Key features:**

- Single driver instance supports all your project's lights
- Dynamic relay bindings created per selected light
- Bidirectional state synchronization between light and relay
- Bulk hide all converted lights from navigators

<div style="page-break-after: always"></div>

# <span style="color:#109EFF">Installation</span>

<!-- #ifdef DRIVERCENTRAL -->

## DriverCentral Cloud Setup

> If you already have the
> [DriverCentral Cloud driver](https://drivercentral.io/platforms/control4-drivers/utility/drivercentral-cloud-driver/)
> installed in your project you can continue to
> [Installing the Drivers](#installing-the-drivers).

This driver suite relies on the DriverCentral Cloud driver to manage licensing
and automatic updates. If you are new to using DriverCentral you can refer to
their [Cloud Driver](https://help.drivercentral.io/407519-Cloud-Driver)
documentation for setting it up.

<!-- #endif -->

## Installing the Drivers

<!-- #ifdef DRIVERCENTRAL -->

1. Download the latest `control4-finite-labs-essentials.zip` from
   [DriverCentral](https://drivercentral.io/platforms/control4-drivers/utility/utility-suite).
2. Extract and install the desired `.c4z` driver files.
3. Use the "Search" tab in Composer Pro to find the driver by name and add it to
   your project.

<!-- #else -->

1. Download the latest `control4-finite-labs-essentials.zip` from
   [Github](https://github.com/finitelabs/control4-finite-labs-essentials/releases/latest).
2. Extract and install the desired `.c4z` driver files.
3. Use the "Search" tab in Composer Pro to find the driver by name and add it to
   your project.

<!-- #endif -->

Each driver includes its own documentation accessible from within Composer Pro.
Refer to the individual driver documentation for detailed property descriptions,
programming reference, and configuration guides.

<div style="page-break-after: always"></div>

<!-- #ifdef DRIVERCENTRAL -->

# <span style="color:#109EFF">Developer Information</span>

<p align="center">
<img alt="Finite Labs" src="./images/finite-labs-logo.png" width="400"/>
</p>

Copyright &copy; 2026 Finite Labs LLC

All information contained herein is, and remains the property of Finite Labs LLC
and its suppliers, if any. The intellectual and technical concepts contained
herein are proprietary to Finite Labs LLC and its suppliers and may be covered
by U.S. and Foreign Patents, patents in process, and are protected by trade
secret or copyright law. Dissemination of this information or reproduction of
this material is strictly forbidden unless prior written permission is obtained
from Finite Labs LLC. For the latest information, please visit
https://drivercentral.io/platforms/control4-drivers/utility/utility-suite

<!-- #endif -->

# <span style="color:#109EFF">Support</span>

<!-- #ifdef DRIVERCENTRAL -->

If you have any questions or issues integrating these drivers with Control4, you
can contact us at
[driver-support@finitelabs.com](mailto:driver-support@finitelabs.com) or
call/text us at [+1 (949) 371-5805](tel:+19493715805).

<!-- #else -->

If you have any questions or issues integrating these drivers with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-finite-labs-essentials/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<!-- #endif -->

<div style="page-break-after: always"></div>

<!-- #embed-changelog -->
