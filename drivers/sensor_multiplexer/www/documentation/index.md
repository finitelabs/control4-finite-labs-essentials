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

<img alt="Sensor Multiplexer" src="./images/header.png" width="500"/>

---

# <span style="color:#109EFF">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by Control4.

<!-- #endif -->

Switch between named groups of sensor inputs, passing the selected group's
values to output bindings. Unlike the Sensor Aggregator which combines N inputs
into 1 via math, the Sensor Multiplexer selects 1-of-N named groups to pass
through.

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
    - [Input Configuration](#input-configuration)
    - [Multiplexer Output](#multiplexer-output)
  - [Driver Actions](#driver-actions)
- [Programming](#programming)
  - [Connections](#connections)
  - [Commands](#commands)
  - [Events](#events)
  - [Conditionals](#conditionals)
- [Use Case: Thermostat Temperature Source](#use-case-thermostat-temperature-source)
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

- Switch between named groups of sensor inputs
- Support for temperature, humidity, and contact sensor types
- Dynamic input and output bindings based on configured names
- Programming command to select the active input
- Event fires when the active selection changes
- Per-name conditionals for programming logic
- Persistent state survives driver restarts

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
2. Extract and install the `sensor_multiplexer.c4z` driver.
3. Use the "Search" tab to find "Sensor Multiplexer" and add it to your project.

<!-- #else -->

1. Download the latest `control4-finite-labs-essentials.zip` from
   [Github](https://github.com/finitelabs/control4-finite-labs-essentials/releases/latest).
2. Extract and install the `sensor_multiplexer.c4z` driver.
3. Use the "Search" tab to find "Sensor Multiplexer" and add it to your project.

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

### Input Configuration

#### Input Names

Comma-delimited list of input group names (e.g., `Away,Home,Sleep`). Each name
creates a set of input bindings for the enabled sensor types. Names are trimmed
of whitespace, deduplicated (case-insensitive, first wins), and colons are
stripped (reserved for internal use).

#### Enable Temperature [ **_Yes_** | No ]

When enabled, creates a temperature input binding for each named group and a
temperature output binding.

#### Enable Humidity [ **_Yes_** | No ]

When enabled, creates a humidity input binding for each named group and a
humidity output binding.

#### Enable Contact [ Yes | **_No_** ]

When enabled, creates a contact input binding for each named group and a contact
output binding.

### Multiplexer Output

#### Active Input Name (read-only)

Displays the name of the currently selected input group.

#### Output Temperature C (read-only)

The output temperature value in Celsius from the active input group. Only
visible when Enable Temperature is set to `Yes`.

#### Output Temperature F (read-only)

The output temperature value in Fahrenheit from the active input group. Only
visible when Enable Temperature is set to `Yes`.

#### Output Humidity (read-only)

The output humidity value from the active input group. Only visible when Enable
Humidity is set to `Yes`.

#### Output Contact (read-only)

The output contact state from the active input group: "Closed", "Open", or empty
if no value available. Only visible when Enable Contact is set to `Yes`.

## Driver Actions

<!-- #ifndef DRIVERCENTRAL -->

### Update Drivers

Triggers the driver to update from the latest release on GitHub, regardless of
the current version.

<!-- #endif -->

### Cycle Input

Cycles to the next input in the names list, wrapping from the last name back to
the first. Useful for testing or manual cycling through input groups.

### Reset Driver

Resets the driver state, clearing all cached input values, bindings, events, and
conditionals.

**Parameters:**

- **Are You Sure?** [ **_No_** | Yes ] - Confirmation to reset the driver.

<div style="page-break-after: always"></div>

# <span style="color:#109EFF">Programming</span>

## Connections

### Input Bindings (consumer)

Input bindings are dynamically created for each name in the "Input Names"
property, one per enabled sensor type. For example, with names "Away,Home,Sleep"
and temperature enabled, the driver creates:

| Binding           | Class             | Description                      |
| ----------------- | ----------------- | -------------------------------- |
| Away Temperature  | TEMPERATURE_VALUE | Temperature input for Away mode  |
| Home Temperature  | TEMPERATURE_VALUE | Temperature input for Home mode  |
| Sleep Temperature | TEMPERATURE_VALUE | Temperature input for Sleep mode |

Connect these to TEMPERATURE_VALUE, HUMIDITY_VALUE, or CONTACT_SENSOR provider
bindings from other drivers (such as Sensor Aggregator outputs).

### Output Bindings (provider)

| Binding            | Class             | Description                               |
| ------------------ | ----------------- | ----------------------------------------- |
| Output Temperature | TEMPERATURE_VALUE | Temperature from the active input group   |
| Output Humidity    | HUMIDITY_VALUE    | Humidity from the active input group      |
| Output Contact     | CONTACT_SENSOR    | Contact state from the active input group |

Output bindings are created based on the Enable Temperature/Humidity/Contact
properties. Connect these to devices that consume sensor values (e.g., a
thermostat).

## Commands

### Select Input

Selects the active input group by name. Use this command in programming to
switch which group of sensor values is passed to the output.

**Parameters:**

- **Input** (Dynamic List) - The name of the input group to select. The dropdown
  is populated from the "Input Names" property.

## Events

### Selection Changed

Fires whenever the active input selection changes. Use this event to trigger
programming actions when switching between input groups.

## Conditionals

A conditional is created for each name in the "Input Names" property:

- **\<Name\>** - Tests whether the named input group is the currently active
  selection. Shows as "Active" or "Inactive".

For example, with names "Away,Home,Sleep", three conditionals are created:
"Away", "Home", and "Sleep".

<div style="page-break-after: always"></div>

# <span style="color:#109EFF">Use Case: Thermostat Temperature Source</span>

This walkthrough demonstrates how to use the Sensor Multiplexer with Sensor
Aggregators to feed different temperature readings to a thermostat based on
Away/Home/Sleep modes.

**Signal flow:**
`Individual Sensors → Sensor Aggregators (per-mode) → Sensor Multiplexer → Thermostat`

### Step 1: Create Sensor Aggregators

Create three Sensor Aggregator driver instances:

1. **Away Sensors** - Add temperature sensors relevant to away mode (e.g.,
   hallway sensors)
2. **Home Sensors** - Add temperature sensors relevant to home mode (e.g.,
   living room, kitchen sensors)
3. **Sleep Sensors** - Add temperature sensors relevant to sleep mode (e.g.,
   bedroom sensors)

Connect the appropriate temperature sensors to each aggregator's input bindings.

### Step 2: Add the Sensor Multiplexer

1. Add the Sensor Multiplexer driver to your project.
2. Set **Input Names** to `Away,Home,Sleep`.
3. Ensure **Enable Temperature** is set to `Yes`.

### Step 3: Connect Aggregator Outputs to Multiplexer Inputs

In the Connections tab:

- Connect **Away Sensors** → Aggregated Temperature output to **Sensor
  Multiplexer** → Away Temperature input
- Connect **Home Sensors** → Aggregated Temperature output to **Sensor
  Multiplexer** → Home Temperature input
- Connect **Sleep Sensors** → Aggregated Temperature output to **Sensor
  Multiplexer** → Sleep Temperature input

### Step 4: Connect Multiplexer Output to Thermostat

Connect the **Sensor Multiplexer** → Output Temperature to the thermostat's
temperature input binding (C4-THERM).

### Step 5: Program Mode Switching

Use the **Scheduler agent** or custom programming to switch modes:

- **Morning (6 AM)**: Execute "Select Input" command with Input = "Home"
- **Evening (10 PM)**: Execute "Select Input" command with Input = "Sleep"
- **Away mode**: Execute "Select Input" command with Input = "Away" (triggered
  by occupancy or manual toggle)

You can also use the **conditionals** in programming to check which mode is
active and branch logic accordingly.

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
