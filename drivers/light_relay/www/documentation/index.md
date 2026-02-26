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

<img alt="Light Relay" src="./images/header.png" width="500"/>

---

# <span style="color:#109EFF">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by Control4.

<!-- #endif -->

Dynamically creates relay connections for one or more selected light devices
using a single driver instance. This enables controlling devices that use relay
drivers (e.g., fans, fireplaces) from a light switch, with bidirectional state
synchronization.

# <span style="color:#109EFF">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Supported Light Proxies](#supported-light-proxies)
- [Installer Setup](#installer-setup)
  <!-- #ifdef DRIVERCENTRAL -->
  - [DriverCentral Cloud Setup](#drivercentral-cloud-setup)
  <!-- #endif -->
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
    - [Cloud Settings](#cloud-settings)
    - [Driver Settings](#driver-settings)
    - [Light Configuration](#light-configuration)
  - [Driver Actions](#driver-actions)
- [Programming](#programming)
  - [Connections](#connections)
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

- Single driver instance supports all your project's lights
- Dynamic relay bindings created per selected light
- Bidirectional state synchronization between light and relay
- Bulk hide all converted lights from navigators

# <span style="color:#109EFF">Supported Light Proxies</span>

- `light.c4i`
- `light_v2.c4i`
- `outlet_light.c4i`

<div style="page-break-after: always"></div>

# <span style="color:#109EFF">Installer Setup</span>

> Only a **_single_** driver instance is needed since you can multiselect lights
> in the properties and the relay bindings will be created dynamically. Adding
> multiple instances of this driver will work, but is not necessary.

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
2. Extract and install the `light_relay.c4z` driver.
3. Use the "Search" tab to find "Light Relay" and add it to your project.

<!-- #else -->

1. Download the latest `control4-finite-labs-essentials.zip` from
   [Github](https://github.com/finitelabs/control4-finite-labs-essentials/releases/latest).
2. Extract and install the `light_relay.c4z` driver.
3. Use the "Search" tab to find "Light Relay" and add it to your project.

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

### Light Configuration

#### Convert Lights To Relays

Select one or more light devices to create dynamic relay connections. Each
selected light gets a corresponding relay output binding with bidirectional
state synchronization.

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

### Hide Lights In All Rooms

Hides all lights selected in
[Convert Lights To Relays](#convert-lights-to-relays) from all room navigators.
This is useful when lights are being controlled exclusively through their relay
bindings and should not appear in the UI.

<div style="page-break-after: always"></div>

# <span style="color:#109EFF">Programming</span>

## Connections

### Output Bindings (provider)

Output bindings are dynamically created for each selected light device. Each
binding is a RELAY class binding named after the light device (with room prefix
if available).

For example, selecting "Kitchen Light" and "Living Room Light" creates:

| Binding           | Class | Description                         |
| ----------------- | ----- | ----------------------------------- |
| Kitchen Light     | RELAY | Relay binding for Kitchen Light     |
| Living Room Light | RELAY | Relay binding for Living Room Light |

Connect these relay bindings to devices that consume relay connections (e.g.,
fan controllers, fireplace relays).

The relay responds to OPEN (turn light off), CLOSE (turn light on), and TOGGLE
commands. Light state changes are reflected back as OPENED/CLOSED notifications
on the relay binding.

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
