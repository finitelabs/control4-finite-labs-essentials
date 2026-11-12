<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

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

<img alt="Humidity Alert" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#059669">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by Control4.

Raise an alert when something adds moisture to a room and its humidity rises,
and hold it until the room has dried out again. A shower, a bath, cooking or a
running dryer all count. This driver reads a HUMIDITY_VALUE and an optional
TEMPERATURE_VALUE connection from another Control4 driver and closes a
CONTACT_SENSOR output while the alert is active. Control4 programming can act on
the alert, or the driver can switch a device itself, a bathroom exhaust fan for
example. It works through the seasons, because it looks for a jump above the
level the room was resting at rather than for a fixed number.

# <span style="color:#059669">Index</span>

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
    - [Detection Settings](#detection-settings)
    - [Timing Settings](#timing-settings)
    - [Output Settings](#output-settings)
    - [Status](#status)
  - [Driver Actions](#driver-actions)
- [How It Decides](#how-it-decides)
  - [The Reference Sensor](#the-reference-sensor)
  - [Known Limits](#known-limits)
- [Switching a Device](#switching-a-device)
  - [Sharing a Device with a Timer Driver](#sharing-a-device-with-a-timer-driver)
- [Programming](#programming)
  - [Connections](#connections)
  - [Events](#events)
  - [Conditionals](#conditionals)
  - [Variables](#variables)
  - [Commands](#commands)
  <!-- #ifdef DRIVERCENTRAL -->
- [Developer Information](#developer-information)

<!-- #endif -->

- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#059669">System Requirements</span>

- Control4 OS 3.3+

# <span style="color:#059669">Features</span>

- Detects moisture added to a room from a jump in humidity, in a dry winter and
  a humid summer alike
- Three detection modes: Rise, Threshold, Rise or Threshold
- Uses the sensor's temperature, when connected, to follow the moisture in the
  air instead of the relative humidity alone
- An optional reference sensor elsewhere in the house, so humidity the whole
  house shares does not count as the room's
- Ends an alert when the room has recovered, with a run-on time and a maximum
- Holds off after an alert, so the climb that can follow it does not start
  another
- Works with sensors that report every few seconds and with battery sensors that
  report only large changes
- A contact output that fires Control4 programming once when an alert starts and
  once when it ends
- Switches a device itself, with no Control4 programming: by a relay, by light
  switches or by a fan speed controller
- Turns off only what it turned on, and treats a device switched off during an
  alert as the end of that alert
- Events, conditionals, variables and commands for Control4 programming

# <span style="color:#059669">Installer Setup</span>

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
   [DriverCentral](https://drivercentral.io/platforms/control4-drivers/utility/finite-labs-essentials).
1. Extract and install the `humidity_alert.c4z` driver.
1. Use the "Search" tab to find "Humidity Alert" and add it to your project.

<!-- #else -->

1. Download the latest `control4-finite-labs-essentials.zip` from
   [Github](https://github.com/finitelabs/control4-finite-labs-essentials/releases/latest).
1. Extract and install the `humidity_alert.c4z` driver.
1. Use the "Search" tab to find "Humidity Alert" and add it to your project.

<!-- #endif -->

## Driver Properties

### Cloud Settings

<!-- #ifdef DRIVERCENTRAL -->

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

#### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates via DriverCentral. Changing it on
any item of this driver changes it on all of them.

<!-- #else -->

#### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates from GitHub releases. Changing it
on any item of this driver changes it on all of them.

#### Update Channel \[ **_Production_** | Prerelease \]

Sets the update channel for which releases are considered during automatic
updates from GitHub releases. Changing it on any item of this driver changes it
on all of them.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

Displays the current status of the driver.

#### Driver Version (read-only)

Displays the current version of the driver.

<!-- #ifdef DRIVERCENTRAL -->

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug \]

Sets the logging level. Default is `3 - Info`. While a Support Code has
Composer's Lua tab open, it also offers `5 - Trace` and `6 - Ultra`.

<!-- #else -->

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

<!-- #endif -->

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

<!-- #ifdef DRIVERCENTRAL -->

#### Support Code

Leave it blank unless Finite Labs support gives you a code: for an hour, it
opens Composer's Lua tab to this driver and adds `5 - Trace` and `6 - Ultra` to
Log Level.

#### Cloud Monitoring \[ Disabled | **_Enabled_** \]

When Enabled, the driver sends Finite Labs a short report once an hour, and a
report of each error it hits, at most 10 a minute. We use them to find and fix
problems in the driver. Set it to Disabled to send nothing.

A report holds the controller's MAC address and OS version, the driver's name,
version, device ID and DriverCentral license status, how much memory the driver
uses, and the sizes of its largest internal tables. An error report also holds
the error message and where in the driver it happened. Before a message is sent,
anything in it that looks like a password, token, key, network address or email
address is removed.

<!-- #endif -->

### Detection Settings

#### Detection \[ **_Enabled_** | Disabled \]

Turns detection on or off. Disabled ends an active alert and starts none, until
it is set to Enabled again. The Enable Detection and Disable Detection commands
change this property.

#### Detection Mode \[ **_Rise_** | Threshold | Rise or Threshold \]

How the driver decides that an alert starts.

- **Rise** starts an alert when the humidity jumps above the level the room was
  resting at. Use it for moisture that comes and goes, a shower for example. It
  needs no adjustment between seasons.
- **Threshold** starts an alert when the humidity is at or above Alert Above.
  Use it for a room whose normal humidity stays well below that level all year.
- **Rise or Threshold** starts an alert on either one.

Settings the chosen mode does not use are hidden and keep their values.

#### Rise Amount \[ 2 - 30, default: **_6_** \]

The rise in humidity, in percentage points, that starts an alert in the Rise
modes. Lower it to catch smaller rises. Raise it if alerts start when nothing
has added moisture.

#### Recovery \[ 10 - 95, default: **_50_** \]

The percent of the rise that must be gone before the alert can end. At 50, an
alert that started at 45 % and peaked at 95 % can end once the humidity is back
at 70 %. A higher value keeps the alert active longer.

#### Alert Above \[ 30 - 100, default: **_80_** \]

The humidity, in percent, at or above which an alert starts in the Threshold
modes.

#### Clear Below \[ 20 - 97, default: **_70_** \]

The humidity, in percent, at or below which a threshold alert ends. The driver
treats it as at least 3 below Alert Above.

#### Reference Sensor \[ **_Disabled_** | Enabled \]

Enabled adds the Reference Humidity and Reference Temperature connections, for a
sensor somewhere else in the house. The driver then leaves out of its decision
whatever the house and the room share. See
[The Reference Sensor](#the-reference-sensor). Disabled removes both
connections.

### Timing Settings

#### Run-On Time \[ 0 - 120, default: **_10_** \]

Minutes the alert stays active after the humidity has recovered.

#### Maximum Alert Time \[ 5 - 240, default: **_60_** \]

Minutes after which an alert ends, even if the room is still humid. A second
rise during an alert can extend it, to twice this time at most.

#### Sensor Timeout \[ 0 - 168, default: **_24_** \]

Hours without a humidity report before the sensor counts as stale. A sensor that
reports only when its reading changes can be silent for hours in a steady room,
so keep this long. 0 never marks it stale.

### Output Settings

#### Control Method \[ **_None_** | Relay | Light Switch | Fan Speed Controller \]

How the driver switches a device during an alert, an exhaust fan for example.
See [Switching a Device](#switching-a-device) for what it does with the device.

- **None**: the driver switches nothing. Use the Alert Contact connection or the
  driver's events.
- **Relay**: adds a Fan Relay connection. The driver closes the relay when an
  alert starts and opens it when the alert ends.
- **Light Switch**: shows the Light Switches property. The driver turns the
  selected switches on and off.
- **Fan Speed Controller**: shows the Fan Controller property. The driver turns
  the selected fan controller on, at the speed the controller itself turns on
  at, and off.

The Fan Relay connection exists only while Control Method is Relay, and each
selector shows only for its own method. A hidden selector keeps its selection.

#### Light Switches

The light switches the alert turns on, the switches of a room's exhaust fans for
example. Shown while Control Method is Light Switch.

#### Fan Controller

The fan speed controller the alert turns on. Shown while Control Method is Fan
Speed Controller.

### Status

#### Alert (read-only)

"Clear", or "Active" with the reason the alert started: Rise, Threshold or
Manual. It also says when detection is disabled or the humidity sensor is stale.

#### Humidity (read-only)

The last humidity the sensor reported.

#### Temperature (read-only)

The temperature that came with that report, in Celsius and Fahrenheit.

#### Dew Point (read-only)

The dew point of the last report, in Celsius and Fahrenheit. Empty without a
temperature.

#### Start Humidity (read-only)

The humidity the room was resting at when the active alert started.

#### Peak Humidity (read-only)

The highest humidity the sensor reported during the active alert.

#### Reference (read-only)

What the reference sensor is doing for the driver:

| Value                 | Meaning                                                                      |
| --------------------- | ---------------------------------------------------------------------------- |
| Not used              | Reference Sensor is Disabled.                                                |
| Waiting for a reading | The reference has not reported since it was connected or the driver started. |
| In use: 47 %          | The room's reports are being corrected with this reference humidity.         |
| Silent, not in use    | The reference has not reported within the Sensor Timeout.                    |

## Driver Actions

<!-- #ifndef DRIVERCENTRAL -->

### Update Drivers

Triggers the driver to update from the latest release on GitHub, regardless of
the current version.

<!-- #endif -->

### Start Alert

Starts an alert by hand, with the reason Manual, as the Start Alert command
does.

**Parameters:**

- **Minutes** \[ 1 - 240, default: **_20_** \] - How long the alert lasts.

### Clear Alert

Ends the active alert now.

### Enable Detection

Sets Detection to Enabled.

### Disable Detection

Sets Detection to Disabled, which ends an active alert.

### Reset Driver

Ends an active alert, then resets the driver: its connections, its variables and
every setting return to their defaults, and the driver forgets the level the
room was resting at.

<!-- #ifdef DRIVERCENTRAL -->

It also turns Cloud Monitoring back on, as a fresh install has it.

<!-- #endif -->

**Parameters:**

- **Are You Sure?** \[ **_No_** | Yes \] - Confirmation to reset the driver.

<!-- #ifdef DRIVERCENTRAL -->

### Diagnostics Snapshot

Prints a report in the Lua output, and sends it to Finite Labs only while Cloud
Monitoring is Enabled.

<!-- #endif -->

# <span style="color:#059669">How It Decides</span>

**A rise.** The driver keeps the lowest humidity of the last 15 minutes as the
level the room is resting at. An alert starts when a report is at least the Rise
Amount above it. Two things keep ordinary changes from counting:

- The report must also be above the highest level the room rested at in the last
  two hours. A dip and the climb back from it is not a rise.
- A sensor that was silent for a long time needs a larger jump, and after two
  hours of silence its next report only sets a new resting level. Weather that
  moves the humidity slowly does not start an alert, even through a sensor that
  reports in large steps.

**Temperature.** Hot water and cooking warm a room as they add moisture, and
warm air shows a lower relative humidity for the same moisture. With the
Temperature connection bound to the same sensor as Humidity, the driver compares
the moisture in the air, so a room that only warms or cools does not look like a
change. A humidity report is paired with the temperature reported with it. Every
value the driver shows is the humidity the sensor reported.

**The end.** An alert can end when the Recovery share of the rise is gone, or
when the humidity has stopped falling with at least half of that share gone. It
then stays active for the Run-On Time. A sensor that still reads 95 % or more is
wet and never counts as recovered. Whatever the room does, the alert ends at the
Maximum Alert Time.

**After an alert.** For 15 minutes a new alert needs twice the Rise Amount, and
the level the room settles at becomes the new resting level. Humidity often
climbs for a while when an exhaust fan stops, and that climb does not start
another alert.

**A threshold.** In the Threshold modes an alert starts at Alert Above and ends
at Clear Below. When a threshold alert reaches the Maximum Alert Time while the
room is still above Alert Above, the threshold waits until the humidity has
fallen to Clear Below before it can start another, so a humid day raises one
alert and not one after another. A rise still starts an alert in Rise or
Threshold.

**Restarts.** The first report after the driver starts, or after the Humidity
connection is bound, only sets the resting level. An alert that was active when
the controller restarted is still active afterwards, and one whose time ran out
while the controller was down ends within a minute of the start.

## The Reference Sensor

Weather, cooking and a damp evening raise the humidity of the whole house, the
bathroom included. A second sensor somewhere else in the house lets the driver
tell that from moisture made in the room. Set Reference Sensor to Enabled and
connect Reference Humidity, and Reference Temperature when the same sensor gives
one. The reference is a correction to the Detection Mode in use, not a mode of
its own:

- **In Rise**, whatever the reference rose over the same minutes is taken off
  the room's rise. When the house and the room climb together, no alert starts.
  A reference that falls changes nothing: it never makes the room's rise larger.
- **In Threshold**, a humidity at or above Alert Above starts an alert only when
  the room is also at least 8 points wetter than the reference. A humid week
  does not run a fan. Once an alert has started, it ends as it would without a
  reference.

Any temperature and humidity sensor elsewhere in the house can be the reference.
The best place is where the fan's replacement air comes from: the hall or the
bedroom outside the bathroom door. It does not need to be the same model as the
room's sensor. In Rise only changes are compared, so two sensors that read a few
points apart do no harm.

A reference report never starts or ends an alert. A reference that reports only
changes may stay quiet for hours, and its last reading stands until the Sensor
Timeout has passed. After that, or with nothing connected, the driver decides
from the room's sensor alone, exactly as it does with Reference Sensor Disabled.
The first report after the driver starts or the reference is connected is where
its changes are measured from.

A door left open lets the hall share a shower. The rise the reference sees is
taken off the room's, so an alert starts a little later, and not at all when the
reference follows the room to within the Rise Amount.

## Known Limits

- A sensor that sends its first report ten minutes into a rise cannot start an
  alert sooner than that.
- A constant source of moisture in the room, a humidifier or laundry drying,
  starts a new alert each time the humidity climbs again after one ends.
- A steam session longer than the Maximum Alert Time loses the alert at the
  maximum. Raise the Maximum Alert Time for such a room.
- Without a Temperature connection, a room that cools quickly can read as a rise
  in humidity.
- A Threshold alert is only as good as its fixed number. Rise needs no seasonal
  adjustment.
- The Temperature connection must come from the same sensor as Humidity. A
  temperature from another room makes the comparison worse, not better.
- A sensor in an exhaust fan's housing reads wet whenever the fan is off, from
  air that leaks back down the duct. In Threshold it can then read 8 points
  above the reference with no shower, so the reference corrects less there. Use
  Rise for such a sensor.

# <span style="color:#059669">Switching a Device</span>

With a Control Method chosen, the driver switches the selected devices itself.
Most often that is a room's exhaust fan, but it can be anything a relay, a light
switch or a fan speed controller runs.

- When an alert starts, it turns on every selected device that is off. Those
  devices are the alert's own.
- When the alert ends, it turns off the devices it turned on, and no others. A
  device that was already on when the alert started is left on.
- A device the alert turned on that is switched off during the alert, at the
  wall or by anything else, ends the alert. The driver turns off the alert's
  other devices, and for the next 15 minutes only a clearly larger rise starts a
  new alert.
- A device that was already on when the alert started and that goes off during
  the alert is turned back on, once, and is the alert's own from then. Switched
  off again, it ends the alert.
- With no alert, the driver never switches a device. A device someone turns on
  by hand stays on until they turn it off.
- When a selected device goes off for any reason, the driver expects the
  humidity reading to move for a few minutes and does not take a small climb for
  a new rise. This matters for a sensor mounted in an exhaust fan's own housing,
  which reads the room's air while the fan runs and air from the duct once it
  stops.
- A controller restart leaves the devices as they are. An alert that is still
  active after the restart turns its devices off when it ends.

Turning Detection off, unbinding the Humidity connection, Reset Driver and a
lapsed license each end the alert and turn its devices off.

## Sharing a Device with a Timer Driver

A device, most often a fan, can also be run by a countdown timer driver that
watches the same switch. Two things about such a timer matter here:

- Some timers start their own countdown whenever the device turns on, and turn
  it off when it runs out. If that happens during an alert, this driver sees its
  device switched off and ends the alert, even if the room is still humid. Leave
  that option off on the timer, or set its time at least as long as Maximum
  Alert Time.
- A timer that was already running the device when an alert starts keeps control
  of it. If the timer turns the device off while the alert is still active, this
  driver turns it back on once and runs it to the end of the alert.

The two never switch the device back and forth: after any device of the alert is
switched off, the alert is over.

# <span style="color:#059669">Programming</span>

## Connections

| Connection            | Class             | Direction | Description                                                                         |
| --------------------- | ----------------- | --------- | ----------------------------------------------------------------------------------- |
| Humidity              | HUMIDITY_VALUE    | Input     | The room's humidity sensor. Required.                                               |
| Temperature           | TEMPERATURE_VALUE | Input     | The same sensor's temperature. Optional.                                            |
| Alert Contact         | CONTACT_SENSOR    | Output    | Closed while an alert is active, else open.                                         |
| Fan Relay             | RELAY             | Output    | Closed by the driver during an alert. Exists while Control Method is Relay.         |
| Reference Humidity    | HUMIDITY_VALUE    | Input     | A humidity sensor elsewhere in the house. Exists while Reference Sensor is Enabled. |
| Reference Temperature | TEMPERATURE_VALUE | Input     | The same sensor's temperature. Optional. Exists while Reference Sensor is Enabled.  |

Connect Alert Contact to a contact sensor driver to see the alert as a device
and to run Control4 programming from its Opened and Closed events, or program on
this driver's own events. A room with several humidity sensors can combine them
with the Sensor Aggregator first.

The contact fires its programming once when an alert starts and once when it
ends. A controller restart, a driver update and a new connection tell the
contact its state without firing programming.

## Events

| Event                 | Fires                                                    |
| --------------------- | -------------------------------------------------------- |
| Alert Started         | When an alert starts                                     |
| Alert Cleared         | When an alert ends, for any reason                       |
| Alert Timed Out       | With Alert Cleared, when the Maximum Alert Time ended it |
| Humidity Sensor Stale | When no humidity report came within the Sensor Timeout   |

Every Alert Started is followed by exactly one Alert Cleared. Programming that
turns a device on at Alert Started and off at Alert Cleared never leaves it on.

## Conditionals

- **Alert is Active / Clear**: whether an alert is active.
- **Humidity sensor is Stale / Reporting**: whether the humidity sensor has been
  silent longer than the Sensor Timeout.

## Variables

| Variable      | Type   | Description                                                    |
| ------------- | ------ | -------------------------------------------------------------- |
| Alert Active  | BOOL   | True while an alert is active                                  |
| Alert Reason  | STRING | Rise, Threshold or Manual while an alert is active, else empty |
| Humidity Rise | NUMBER | Points the humidity is above the alert's start level, else 0   |

## Commands

| Command           | Description                                            |
| ----------------- | ------------------------------------------------------ |
| Start Alert       | Starts an alert for a number of minutes                |
| Clear Alert       | Ends the active alert now                              |
| Enable Detection  | Sets Detection to Enabled                              |
| Disable Detection | Sets Detection to Disabled, which ends an active alert |

<!-- #ifdef DRIVERCENTRAL -->

# <span style="color:#059669">Developer Information</span>

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
https://drivercentral.io/platforms/control4-drivers/utility/finite-labs-essentials

<!-- #endif -->

# <span style="color:#059669">Support</span>

<!-- #ifdef DRIVERCENTRAL -->

If you have any questions or issues integrating this driver with Control4, you
can contact us at [%%SUPPORT_EMAIL%%](mailto:__SUPPORT_EMAIL__) or call/text us
at [%%SUPPORT_PHONE%%](tel:__SUPPORT_PHONE__).

<!-- #else -->

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-finite-labs-essentials/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<!-- #endif -->

<!-- #embed-changelog -->
