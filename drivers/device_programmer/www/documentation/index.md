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

<img alt="Device Programmer" src="./images/header.png" width="500"/>

---

# <span style="color:#109EFF">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by Control4.

<!-- #endif -->

Create virtual sensors and relays controllable via Control4 programming. Enter
comma-delimited names per type (temperature, humidity, contact, relay) and the
driver exposes those as output bindings. Programming commands allow setting each
sensor's value or state, and opening, closing, or toggling relays. Values are
persisted and restored on boot.

# <span style="color:#109EFF">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Installer Setup](#installer-setup)
  <!-- #ifdef DRIVERCENTRAL -->
  - [DriverCentral Cloud Setup](#drivercentral-cloud-setup)
  <!-- #endif -->
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
    - [Cloud Settings](#cloud-settings)
    - [Driver Settings](#driver-settings)
    - [Device Configuration](#device-configuration)
  - [Driver Actions](#driver-actions)
- [Programming](#programming)
  - [Connections](#connections)
  - [Commands](#commands)
  <!-- #ifdef DRIVERCENTRAL -->
- [Developer Information](#developer-information)
<!-- #endif -->
- [Support](#support)
- [Changelog](#changelog)

</div>

<div style="page-break-after: always"></div>

# <span style="color:#109EFF">System Requirements</span>

- Control4 OS 3.3+

# <span style="color:#109EFF">Features</span>

- Create virtual temperature, humidity, and contact sensors
- Create virtual relays that accept Open, Close, and Toggle commands
- Set sensor values and relay states via programming commands
- Dynamic output bindings based on configured names
- Persistent values survive driver restarts

<div style="page-break-after: always"></div>

# <span style="color:#109EFF">Installer Setup</span>

<!-- #ifdef DRIVERCENTRAL -->

## DriverCentral Cloud Setup

> If you already have the
> [DriverCentral Cloud driver](https://drivercentral.io/platforms/control4-drivers/utility/drivercentral-cloud-driver/)
> installed in your project you can continue to
> [Adding the Driver](#adding-the-driver).

This driver relies on the DriverCentral Cloud driver to manage licensing and
automatic updates. If you are new to using DriverCentral you can refer to their
[Cloud Driver](https://help.drivercentral.io/407519-Cloud-Driver) documentation
for setting it up.

<!-- #endif -->

## Adding the Driver

<!-- #ifdef DRIVERCENTRAL -->

1. Download the latest `control4-finite-labs-essentials.zip` from
   [DriverCentral](https://drivercentral.io/platforms/control4-drivers/utility/utility-suite).
2. Extract and install the `device_programmer.c4z` driver.
3. Use the "Search" tab to find "Device Programmer" and add it to your project.

<!-- #else -->

1. Download the latest `control4-finite-labs-essentials.zip` from
   [Github](https://github.com/finitelabs/control4-finite-labs-essentials/releases/latest).
2. Extract and install the `device_programmer.c4z` driver.
3. Use the "Search" tab to find "Device Programmer" and add it to your project.

<!-- #endif -->

## Driver Properties

### Cloud Settings

<!-- #ifdef DRIVERCENTRAL -->

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

#### Automatic Updates [ Off | **_On_** ]

Enables or disables automatic driver updates via DriverCentral.

<!-- #else -->

#### Automatic Updates [ Off | **_On_** ]

Enables or disables automatic driver updates from GitHub releases.

#### Update Channel [ **_Production_** | Prerelease ]

Sets the update channel for which releases are considered during automatic
updates from GitHub releases.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

Displays the current status of the driver.

#### Driver Version (read-only)

Displays the current version of the driver.

#### Log Level [ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra ]

Sets the logging level. Default is `3 - Info`.

#### Log Mode [ **_Off_** | Print | Log | Print and Log ]

Sets the logging mode. Default is `Off`.

### Device Configuration

#### Temperature Names

Comma-delimited list of virtual temperature sensor names (e.g.,
`Living Room,Kitchen`). Each name creates a TEMPERATURE_VALUE output binding.
Names are trimmed of whitespace, deduplicated (case-insensitive, first wins),
and colons are stripped (reserved for internal use).

#### Humidity Names

Comma-delimited list of virtual humidity sensor names (e.g.,
`Living Room,Kitchen`). Each name creates a HUMIDITY_VALUE output binding.

#### Contact Names

Comma-delimited list of virtual contact sensor names (e.g.,
`Front Door,Garage`). Each name creates a CONTACT_SENSOR output binding.

#### Relay Names

Comma-delimited list of virtual relay names (e.g., `Front Gate,Garage Door`).
Each name creates a RELAY output binding. Bound consumers can send OPEN, CLOSE,
and TOGGLE commands which update persisted state and send notifications.

## Driver Actions

<!-- #ifndef DRIVERCENTRAL -->

### Update Drivers

Triggers the driver to update from the latest release on GitHub, regardless of
the current version.

<!-- #endif -->

### Reset Driver

Resets the driver state, clearing all persisted values and bindings.

**Parameters:**

- **Are You Sure?** [ **_No_** | Yes ] - Confirmation to reset the driver.

<div style="page-break-after: always"></div>

# <span style="color:#109EFF">Programming</span>

## Connections

### Output Bindings (provider)

Output bindings are dynamically created for each configured sensor name. For
example, with Temperature Names set to "Living Room,Kitchen", the driver
creates:

| Binding                 | Class             | Description                         |
| ----------------------- | ----------------- | ----------------------------------- |
| Living Room Temperature | TEMPERATURE_VALUE | Virtual temperature for Living Room |
| Kitchen Temperature     | TEMPERATURE_VALUE | Virtual temperature for Kitchen     |

Similarly for humidity, contact, and relay names. For example, with Relay Names
set to "Front Gate,Garage Door", the driver creates:

| Binding           | Class | Description                   |
| ----------------- | ----- | ----------------------------- |
| Front Gate Relay  | RELAY | Virtual relay for Front Gate  |
| Garage Door Relay | RELAY | Virtual relay for Garage Door |

Relay bindings accept OPEN, CLOSE, and TOGGLE commands from bound consumers,
making them fully functional virtual relays.

Connect these to devices that consume sensor values (e.g., a thermostat for
temperature, or a lighting scene for contact sensors) or relay proxies (e.g.,
`relaysingle_relay_c4.c4i`).

## Commands

### Set Temperature

Sets the value of a virtual temperature sensor. The value is converted from the
specified scale to the project's configured temperature scale, then persisted
and sent to any connected consumer.

**Parameters:**

- **Name** (Dynamic List) - The name of the temperature sensor. Populated from
  the "Temperature Names" property.
- **Value** (String) - The temperature value.
- **Scale** (List) - The scale of the provided value: `Fahrenheit` or `Celsius`.
  The value is converted to the project's temperature scale if different.

### Set Humidity

Sets the value of a virtual humidity sensor.

**Parameters:**

- **Name** (Dynamic List) - The name of the humidity sensor. Populated from the
  "Humidity Names" property.
- **Value** (String) - The humidity value as a percentage (clamped to 0-100).

### Set Contact

Sets the state of a virtual contact sensor.

**Parameters:**

- **Name** (Dynamic List) - The name of the contact sensor. Populated from the
  "Contact Names" property.
- **State** (List) - The contact state: `Open` or `Closed`.

### Set Temperature from Variable

Sets a virtual temperature sensor from a variable's current value. The value is
converted from the specified scale to the project's configured temperature
scale.

**Parameters:**

- **Name** (Dynamic List) - The name of the temperature sensor. Populated from
  the "Temperature Names" property.
- **Variable** (Variable Selector) - A number variable whose current value is
  used as the temperature.
- **Scale** (List) - The scale of the variable's value: `Fahrenheit` or
  `Celsius`. The value is converted to the project's temperature scale if
  different.

### Set Humidity from Variable

Sets a virtual humidity sensor from a variable's current value.

**Parameters:**

- **Name** (Dynamic List) - The name of the humidity sensor. Populated from the
  "Humidity Names" property.
- **Variable** (Variable Selector) - A number variable whose current value is
  used as the humidity percentage (clamped to 0-100).

### Set Contact from Variable

Sets a virtual contact sensor from a boolean variable's current value.

**Parameters:**

- **Name** (Dynamic List) - The name of the contact sensor. Populated from the
  "Contact Names" property.
- **Variable** (Variable Selector) - A boolean variable whose current value
  determines the contact state (`true` = Closed, `false` = Open).

### Open Relay

Opens a virtual relay (sets state to Open).

**Parameters:**

- **Name** (Dynamic List) - The name of the relay. Populated from the "Relay
  Names" property.

### Close Relay

Closes a virtual relay (sets state to Closed).

**Parameters:**

- **Name** (Dynamic List) - The name of the relay. Populated from the "Relay
  Names" property.

### Toggle Relay

Toggles a virtual relay between Open and Closed states. If the relay has no
persisted state, it defaults to Closed.

**Parameters:**

- **Name** (Dynamic List) - The name of the relay. Populated from the "Relay
  Names" property.

### Set Relay from Variable

Sets a virtual relay state from a boolean variable's current value.

**Parameters:**

- **Name** (Dynamic List) - The name of the relay. Populated from the "Relay
  Names" property.
- **Variable** (Variable Selector) - A boolean variable whose current value
  determines the relay state (`true` = Closed, `false` = Open).

<div style="page-break-after: always"></div>

<!-- #ifdef DRIVERCENTRAL -->

# <span style="color:#109EFF">Developer Information</span>

<p align="center">
<img alt="Finite Labs" src="./images/finite-labs-logo.png" width="400"/>
</p>

Copyright © 2026 Finite Labs LLC

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

If you have any questions or issues integrating this driver with Control4, you
can contact us at
[driver-support@finitelabs.com](mailto:driver-support@finitelabs.com) or
call/text us at [+1 (949) 371-5805](tel:+19493715805).

<!-- #else -->

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-finite-labs-essentials/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<!-- #endif -->

<div style="page-break-after: always"></div>

<!-- #embed-changelog -->
