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

<img alt="Variable Manipulator" src="./images/header.png" width="500"/>

---

# <span style="color:#109EFF">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by Control4.

<!-- #endif -->

Control4 programming offers only basic operations on variables: set a value,
randomize, increment, decrement, or copy from another variable. The Variable
Manipulator extends this by letting you build a string from one or more
variables, or evaluate a mathematical equation that references one or more
variables, and publish the result to its own `STRING` and `NUMBER` variables for
use elsewhere in programming.

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
    - [Output](#output)
    - [Token Builder](#token-builder)
  - [Driver Actions](#driver-actions)
- [Programming](#programming)
  - [Referencing Variables](#referencing-variables)
  - [Commands](#commands)
  - [Output Variables and Events](#output-variables-and-events)
  - [Math Functions](#math-functions)
  - [Examples](#examples)
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

- Combine one or more variables into a single string
- Evaluate mathematical equations that reference one or more variables
- Reference any variable in the project by device id and variable id or name
- Token Builder generates `PARAM{}` tokens from a variable picker
- Full Lua math library plus common helpers (`abs`, `min`, `max`, `round`, ...)
- Results published to `STRING` and `NUMBER` variables and to driver events
- Rendered expression shows each reference as `[Room > Device > Variable]`
- Last results persist across driver restarts

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
2. Extract and install the `variable_manipulator.c4z` driver.
3. Use the "Search" tab to find "Variable Manipulator" and add it to your
   project.

<!-- #else -->

1. Download the latest `control4-finite-labs-essentials.zip` from
   [Github](https://github.com/finitelabs/control4-finite-labs-essentials/releases/latest).
2. Extract and install the `variable_manipulator.c4z` driver.
3. Use the "Search" tab to find "Variable Manipulator" and add it to your
   project.

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

### Output

#### String Output (read-only)

The most recent result of the Create String command. This mirrors the driver's
`STRING` variable for at-a-glance viewing in Composer.

#### String Expression (read-only)

The most recent Create String template with each `PARAM{}` token rendered as
`[Room > Device > Variable]`, so you can confirm at a glance which variables a
template references.

#### Equation Output (read-only)

The most recent result of the Calculate Equation command. This mirrors the
driver's `NUMBER` variable for at-a-glance viewing in Composer. Shows
`ERROR IN EQUATION` when the last equation could not be evaluated.

#### Equation Expression (read-only)

The most recent Calculate Equation template with each `PARAM{}` token rendered
as `[Room > Device > Variable]`. Because it is updated even when an equation
fails, it is the quickest way to see which variable reference was wrong.

### Token Builder

A helper for generating `PARAM{}` tokens without looking up ids by hand.

#### Reference Variable

Select any variable in the project. The driver writes the matching token to
Reference Token below.

#### Reference Token

The `PARAM{}` token for the selected variable, for example `PARAM{32,1040}`.
Select the text to copy it into a Create String or Calculate Equation command.
The field is editable so it can be selected and copied; any edit is overwritten
the next time you pick a variable.

## Driver Actions

<!-- #ifndef DRIVERCENTRAL -->

### Update Drivers

Triggers the driver to update from the latest release on GitHub, regardless of
the current version.

<!-- #endif -->

### Reset Driver

Clears the persisted outputs and resets the `STRING` and `NUMBER` variables to
their defaults.

**Parameters:**

- **Are You Sure?** [ **_No_** | Yes ] - Confirmation to reset the driver.

<div style="page-break-after: always"></div>

# <span style="color:#109EFF">Programming</span>

## Referencing Variables

Reference a variable anywhere in a string or equation with a `PARAM{}` token:

```
PARAM{DEVICE_ID,VARIABLE_ID}
```

`DEVICE_ID` is the numeric id of the device that owns the variable.
`VARIABLE_ID` is either the numeric id of the variable or its name (matched
exactly, case-sensitive), for example `PARAM{96,1002}` or `PARAM{96,Humidity}`.
Any variable type may be referenced, including strings, numbers, and booleans.

The easiest way to get a token is the [Token Builder](#token-builder) in the
driver properties: pick a variable and copy the generated token. You can also
build one by hand using the device and variable ids shown in the "Variables"
view in Composer Pro (`View` menu).

If a referenced variable cannot be found, the token is replaced with
`ERROR_VARIABLE_NOT_FOUND` in a string, and the equation is rejected with
`ERROR IN EQUATION`.

## Commands

### Create String

Build a single string from literal text and `PARAM{}` tokens. Each token is
replaced with the referenced variable's current value. The result is published
to the `STRING` variable.

```
Living room is PARAM{96,1001} degrees and PARAM{96,1002}% humidity
```

### Calculate Equation

Substitute `PARAM{}` tokens and evaluate the result as a mathematical
expression. The result is published to the `NUMBER` variable.

```
math.abs(PARAM{96,1002} - PARAM{97,1002})
```

Equations are evaluated in a sandbox that exposes only the math functions listed
below, so an equation cannot read or change the rest of the driver.

## Output Variables and Events

The driver exposes two read-only variables and two events:

| Output              | Type     | Set by             |
| ------------------- | -------- | ------------------ |
| `STRING`            | Variable | Create String      |
| `NUMBER`            | Variable | Calculate Equation |
| String Created      | Event    | Create String      |
| Equation Calculated | Event    | Calculate Equation |

Commands run asynchronously, so the result is not ready on the next line of
programming. Trigger follow-up programming from the driver's variable-changed
events (`When STRING changes`, `When NUMBER changes`) or from the
`String Created` / `Equation Calculated` events. The events fire every time a
command completes, even when the computed value is unchanged, which makes them
useful when a variable-changed event would not re-fire.

## Math Functions

Equations may use the full Lua `math` library (for example `math.floor`,
`math.random`, `math.sin`). The following helpers are also available without the
`math.` prefix:

`abs`, `ceil`, `floor`, `sqrt`, `min`, `max`, `round`, `pi`, `huge`, `tonumber`

Operators follow Lua syntax: `+`, `-`, `*`, `/`, `%` (modulo), `^` (power), and
parentheses for grouping.

## Examples

**Difference between two humidity sensors** (device 96 and 97, variable 1002):

1. Add a "When the variable ... changes" event for each humidity variable.
2. Run the Calculate Equation command with:
   `math.abs(PARAM{96,1002} - PARAM{97,1002})`
3. Add a "When NUMBER changes" event on the Variable Manipulator and read
   `NUMBER` to drive your logic (for example, run a fan when the difference
   exceeds a threshold).

**Average of three temperatures**:

```
round((PARAM{96,1001} + PARAM{97,1001} + PARAM{98,1001}) / 3, 1)
```

**Status string for a custom label**:

```
Pool PARAM{120,2001}F / Spa PARAM{120,2002}F
```

<!-- #ifdef DRIVERCENTRAL -->

<div style="page-break-after: always"></div>

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
