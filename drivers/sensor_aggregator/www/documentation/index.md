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

<img alt="Sensor Aggregator" src="./images/header.png" width="500"/>

---

# <span style="color:#109EFF">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by Control4.

<!-- #endif -->

Aggregate multiple sensor inputs into single outputs using configurable
aggregation functions. This driver receives TEMPERATURE_VALUE, HUMIDITY_VALUE,
and CONTACT_SENSOR inputs from other Control4 drivers and produces aggregated
output bindings.

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
    - [Aggregated Output](#aggregated-output)
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

- Aggregate up to 20 temperature and 20 humidity inputs
- Aggregate up to 20 contact sensor inputs
- Configurable numeric aggregation functions: Mean, Median, Mode, Min, Max, IQR
  Mean
- Configurable boolean aggregation functions: Any, All, Majority
- Separate aggregation settings for each sensor type
- Dynamic input and output bindings
- Real-time recalculation when inputs change

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
2. Extract and install the `sensor_aggregator.c4z` driver.
3. Use the "Search" tab to find "Sensor Aggregator" and add it to your project.

<!-- #else -->

1. Download the latest `control4-finite-labs-essentials.zip` from
   [Github](https://github.com/finitelabs/control4-finite-labs-essentials/releases/latest).
2. Extract and install the `sensor_aggregator.c4z` driver.
3. Use the "Search" tab to find "Sensor Aggregator" and add it to your project.

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

#### Temperature Inputs [ 0 - 20, default: **_2_** ]

Number of temperature input bindings to create. Each input accepts a
TEMPERATURE_VALUE connection from another driver.

#### Humidity Inputs [ 0 - 20, default: **_2_** ]

Number of humidity input bindings to create. Each input accepts a HUMIDITY_VALUE
connection from another driver.

#### Contact Inputs [ 0 - 20, default: **_0_** ]

Number of contact input bindings to create. Each input accepts a CONTACT_SENSOR
connection from a contact sensor driver.

#### Temperature Aggregation [ **_Mean_** | Median | Mode | Min | Max | IQR Mean ]

The aggregation function used to combine temperature inputs.

#### Humidity Aggregation [ **_Mean_** | Median | Mode | Min | Max | IQR Mean ]

The aggregation function used to combine humidity inputs.

> **IQR Mean** excludes outliers before averaging. It calculates the
> interquartile range (IQR = Q3 - Q1) and removes values below Q1 - 1.5\*IQR or
> above Q3 + 1.5\*IQR, then computes the mean of the remaining values. With
> fewer than 4 inputs, it falls back to a regular mean.

#### Contact Aggregation [ **_Any_** | All | Majority ]

The aggregation function used to combine contact inputs. **Any** returns closed
if any input is closed, **All** requires all inputs to be closed, and
**Majority** requires more than half to be closed.

### Aggregated Output

#### Aggregated Temperature C (read-only)

The aggregated temperature value in Celsius.

#### Aggregated Temperature F (read-only)

The aggregated temperature value in Fahrenheit.

#### Aggregated Humidity (read-only)

The aggregated humidity value as a percentage.

#### Active Temperature Inputs (read-only)

Number of temperature inputs currently providing values.

#### Active Humidity Inputs (read-only)

Number of humidity inputs currently providing values.

#### Aggregated Contact (read-only)

The aggregated contact state: "Closed", "Open", or empty if no inputs.

#### Active Contact Inputs (read-only)

Number of contact inputs currently providing values.

## Driver Actions

<!-- #ifndef DRIVERCENTRAL -->

### Update Drivers

Triggers the driver to update from the latest release on GitHub, regardless of
the current version.

<!-- #endif -->

### Reset Driver

Resets the driver state, clearing all cached input values and re-creating
bindings.

**Parameters:**

- **Are You Sure?** [ **_No_** | Yes ] - Confirmation to reset the driver.

### Print Calibration Report

Prints a report showing how each input sensor differs from the aggregate value.
For each bound input, displays the device name, cached value, and the adjustment
(delta) needed to match the aggregate. Useful for identifying sensors that need
calibration offsets.

<div style="page-break-after: always"></div>

# <span style="color:#109EFF">Programming</span>

## Connections

### Input Bindings (consumer)

Temperature and humidity input bindings are dynamically created based on the
"Temperature Inputs" and "Humidity Inputs" properties. Connect these to
TEMPERATURE_VALUE or HUMIDITY_VALUE provider bindings from other drivers.

Contact input bindings are dynamically created based on the "Contact Inputs"
property. Connect these to CONTACT_SENSOR provider bindings from contact sensor
drivers.

### Output Bindings (provider)

| Binding                | Class             | Description                         |
| ---------------------- | ----------------- | ----------------------------------- |
| Aggregated Temperature | TEMPERATURE_VALUE | Aggregated temperature in Celsius   |
| Aggregated Humidity    | HUMIDITY_VALUE    | Aggregated humidity as a percentage |
| Aggregated Contact     | CONTACT_SENSOR    | Aggregated contact state            |

These output bindings can be connected to other Control4 devices that consume
temperature, humidity, or contact sensor values.

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
