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

<img alt="Source Volume" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#059669">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by Control4.

Hold a room at a fixed volume while one of the sources you picked is playing,
and put the room back to the level it had before when another source takes over.
It suits a source that controls its own volume, such as a computer whose sound
is already set where you want it. Sources you don't pick are left alone, so
Control4's own volume handling for them keeps working. There is nothing to
connect: the driver acts on the room it is added to.

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
    - [Volume Settings](#volume-settings)
    - [Status](#status)
  - [Driver Actions](#driver-actions)
- [How It Works](#how-it-works)
  - [Known Limits](#known-limits)
- [Programming](#programming)
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

- Any number of sources from any room, in up to eight groups that each have
  their own volume from 0 to 100
- Saves the room's volume when a picked source starts and restores it when an
  unpicked source takes over
- Going from one picked source to another keeps the level from before the first,
  so it still comes back at the end
- Leaves sources you don't pick alone, and never touches mute
- Steps aside when something else sets the volume as the source changes, such as
  Control4's default volumes
- Keeps a separate saved level for each volume device in a room with separate
  audio and video amplifiers
- Carries on across a controller restart or a driver update
- Events, a conditional, variables and commands for Control4 programming

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
1. Extract and install the `source_volume.c4z` driver.
1. Use the "Search" tab to find "Source Volume" and add it to the room it should
   act on.

<!-- #else -->

1. Download the latest `control4-finite-labs-essentials.zip` from
   [Github](https://github.com/finitelabs/control4-finite-labs-essentials/releases/latest).
1. Extract and install the `source_volume.c4z` driver.
1. Use the "Search" tab to find "Source Volume" and add it to the room it should
   act on.

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
report of each error it hits, at most 10 a minute, so problems in the driver can
be found and fixed. Set it to Disabled to send nothing.

A report holds the controller's MAC address and OS version, the driver's name,
version, device ID and DriverCentral license status, how much memory the driver
uses, and the sizes of its largest internal tables. An error report also holds
the error message and where in the driver it happened. Before a message is sent,
anything in it that looks like a password, token, key, network address or email
address is removed.

<!-- #endif -->

### Volume Settings

#### Volume Control \[ **_Enabled_** | Disabled \]

Turns the driver on or off. Disabled changes nothing and forgets any saved
volume, so the room keeps the level it has.

#### Room Status (read-only)

What the driver is doing in its room:

| Value                                           | Meaning                                                                        |
| ----------------------------------------------- | ------------------------------------------------------------------------------ |
| Holding 60 for Office Computer, will restore 35 | A picked source is playing. 35 comes back when an unpicked source takes over.  |
| Not holding: AirPlay is not picked              | The room is playing a source you didn't pick.                                  |
| Room is off                                     | The room is off, with no level saved.                                          |
| Room is off, will restore 35                    | The room is off, and 35 comes back when it turns on to an unpicked source.     |
| No sources picked                               | No group has a source checked.                                                 |
| Disabled                                        | Volume Control is Disabled.                                                    |
| This room's volume can't be set to a level      | The room's volume device takes only volume up and down, so nothing is changed. |
| Volume 60 was sent but didn't arrive            | The room didn't reach the level after it was sent twice.                       |

#### Group 1 Sources … Group 8 Sources

Lists the Watch and Listen sources of every room, a computer's UI button among
them, each marked `[X]` when the group holds it and `[  ]` when it doesn't. Pick
a source to check or uncheck it. A source is in one group at most, so checking
it in one group takes it out of any other. A group holds any number of sources,
and they all play at that group's volume.

A room that joins another room's audio session plays that room's source, so a
source that only another room lists can be checked too. Each source shows as its
room, then `>`, then its name, sorted by room and then name. A source added to a
room shows the next time this room's source changes, or at once with Refresh
List. Each group appears once the one before it has a source.

#### Group 1 Volume … Group 8 Volume \[ 0 - 100, default: **_50_** \]

Sets the room's volume while a source checked in that group plays.

## Driver Actions

<!-- #ifndef DRIVERCENTRAL -->

### Update Drivers

Triggers the driver to update from the latest release on GitHub, regardless of
the current version.

<!-- #endif -->

### Reset Driver

> [!WARNING]
> This unchecks every source, sets every group's volume back to 50, and forgets
> the saved volume.

Resets the driver: its variables and every setting return to their defaults, and
the driver forgets any saved level.

<!-- #ifdef DRIVERCENTRAL -->

It also turns Cloud Monitoring back on, as a fresh install has it.

<!-- #endif -->

**Parameters:**

- **Are You Sure?** \[ **_No_** | Yes \] - Confirmation to reset the driver.

### Enable Volume Control

Sets Volume Control to Enabled.

### Disable Volume Control

Sets Volume Control to Disabled.

<!-- #ifdef DRIVERCENTRAL -->

### Diagnostics Snapshot

Prints a report in the Lua output, and sends it to Finite Labs only while Cloud
Monitoring is Enabled.

<!-- #endif -->

# <span style="color:#059669">How It Works</span>

The driver watches its room's selected source, power, volume and volume device.
It waits until the room has been quiet for two seconds after a change, so that
Control4 has finished selecting the source and applying any default volume, and
then acts.

**A picked source starts.** The driver saves the room's volume and sets the
source's volume with the same command as the room's volume slider. If the level
hasn't arrived three seconds later, it sends it once more, and says so in Room
Status if it still doesn't arrive. When the room turns on straight to a picked
source, the saved level is the one the room had the last time it played an
unpicked source.

**Another picked source starts.** Its volume is set, and the saved level stays
the one from before the first picked source.

**An unpicked source starts.** The saved level is put back and then forgotten.
It is put back only while the room is still at the last level it had under the
picked source. If something else set the volume as the source changed, such as
Control4's default volumes or programming, that level is kept.

**The volume changes during a picked source.** The driver leaves it there, and
the level from before still comes back afterwards.

**The room turns off during a picked source.** The saved level is kept and put
back the next time the room plays an unpicked source, unless the room uses
Control4's default volumes, which set the level themselves when the room turns
on.

**Separate volume devices.** A room can use one amplifier for its audio sources
and a TV or receiver for its video sources. The driver keeps a saved level for
each and puts a level back only on the device it changed.

**Restarts.** The saved level and the picked source are stored. After a restart
the driver reads the room again and carries on.

**Updating from Source 1 … Source 8.** Earlier versions picked each source in
its own slot with its own volume. On its first start after the update, the
driver puts every picked source into a group, one group for each volume, in slot
order, so each source keeps its level.

## Known Limits

- The driver acts only on the room it is in. Add one Source Volume to each room
  that needs it.
- A room whose volume is linked to other rooms moves them together, so the fixed
  level reaches the linked rooms too.
- Services inside Digital Media, such as a streaming service, share one device.
  Digital Media can be picked as a whole, but not one service within it.
- A volume device that takes only volume up and down can't be set to a level,
  and the driver leaves that room alone.

# <span style="color:#059669">Programming</span>

## Events

| Event            | Fires                                  |
| ---------------- | -------------------------------------- |
| Fixed Volume Set | When a picked source's volume is set   |
| Volume Restored  | When the level from before is put back |

## Conditionals

- **Fixed volume is Active / Inactive**: whether a picked source holds the room.

## Variables

| Variable            | Type   | Description                                               |
| ------------------- | ------ | --------------------------------------------------------- |
| Fixed Volume Active | BOOL   | True while a picked source holds the room                 |
| Saved Volume        | NUMBER | The level that will be put back, or -1 when there is none |

## Commands

| Command                | Description                     |
| ---------------------- | ------------------------------- |
| Enable Volume Control  | Sets Volume Control to Enabled  |
| Disable Volume Control | Sets Volume Control to Disabled |

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
