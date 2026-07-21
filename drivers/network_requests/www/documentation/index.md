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

<img alt="Network Requests" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#109EFF">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by Control4.

<!-- #endif -->

Network Requests sends HTTP, raw TCP, UDP, and Wake-on-LAN commands to devices
and services that have no Control4 driver. Requests are defined once, by name,
in a dedicated Composer tab, and fired from programming with a single Send
Request command. Request URLs, bodies, headers, and payloads can reference any
Control4 variable, so the same named request can carry live values from the
project.

# <span style="color:#109EFF">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Installer Setup](#installer-setup)
  <!-- #ifdef DRIVERCENTRAL -->
  - [DriverCentral Cloud Setup](#drivercentral-cloud-setup)
  <!-- #endif -->
  - [Adding the Driver](#adding-the-driver)
  - [Requests Tab](#requests-tab)
  - [Driver Properties](#driver-properties)
    - [Cloud Settings](#cloud-settings)
    - [Driver Settings](#driver-settings)
  - [Driver Actions](#driver-actions)
- [Programming](#programming)
  - [Request Types](#request-types)
  - [Referencing Variables](#referencing-variables)
  - [Commands](#commands)
  - [Events and the Response Variable](#events-and-the-response-variable)
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

- Named requests managed from a dedicated Requests tab in Composer, with a
  searchable variable browser, insert at cursor, and per-request send history
- Fire any request from programming by name with the Send Request command
- HTTP and HTTPS with any method (GET, POST, PUT, PATCH, DELETE, HEAD),
  arbitrary custom headers, request bodies, and basic auth via the URL
- Raw TCP and UDP payloads as text (with `\r`, `\n`, `\t`, `\xNN` escapes) or
  hex bytes
- TCP requests can wait for the device's response
- Wake-on-LAN magic packets by MAC address
- Insert live Control4 variable values into URLs, bodies, headers, and payloads
  with `PARAM{}` tokens
- Each request fires a `<Name> Sent` or `<Name> Failed` event after every send;
  HTTP and response-waiting TCP requests also publish the last response body to
  a `<Name> Response` variable
- Inbound webhooks: external systems (cameras, iPhone Shortcuts, Home Assistant)
  call a URL to fire a `<Name> Received` event, with the request body published
  to a `<Name> Payload` variable and an optional shared key
- Requests, webhooks, and last results persist across driver restarts

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
1. Extract and install the `network_requests.c4z` driver.
1. Use the "Search" tab to find "Network Requests" and add it to your project.

<!-- #else -->

1. Download the latest `control4-finite-labs-essentials.zip` from
   [Github](https://github.com/finitelabs/control4-finite-labs-essentials/releases/latest).
1. Extract and install the `network_requests.c4z` driver.
1. Use the "Search" tab to find "Network Requests" and add it to your project.

<!-- #endif -->

## Requests Tab

The Requests tab in Composer (select the driver, then the Requests tab) is the
primary way to create and manage named requests.

### Request list

Every named request appears as a row with its type, target, and the result of
its last send. Results update live as requests fire, whether from programming or
the Send button on the row.

### Editor

- **Type**: HTTP, TCP, UDP, or WOL. The form shows the fields for the selected
  type.
- **Variables browser**: search across rooms, devices, and variable names. Click
  a device to load its variables with their current values. Click a variable to
  insert its `PARAM{}` token into the focused field.
- **HTTP**: method, URL (basic auth supported as
  `http://user:pass@host:port/path`), optional headers, and an optional body.
  TLS certificates are only validated when **Validate TLS certificate** is
  checked, so self-signed LAN devices work by default.
- **TCP / UDP**: host, port, and a payload. Text payloads decode `\r`, `\n`,
  `\t`, `\0`, `\\`, and `\xNN` escapes; hex payloads are written as hex bytes
  (`02 41 54 0d`, `0x02,0x41`, or `0241540d`). TCP requests can optionally wait
  for the device's response with a configurable timeout.
- **WOL**: the MAC address of the device to wake.
- **Save & Send**: saves the request and sends it immediately, showing the
  result and any captured response in the editor.

### Outputs

Saving a request named `Projector Power On` creates:

- An event `Projector Power On Sent` that fires after every successful send
- An event `Projector Power On Failed` that fires when a send fails
- For HTTP and response-waiting TCP requests, a read-only variable
  `Projector Power On Response` holding the last response body

Request names are permanent: programming, events, and the Response variable all
reference the request by name, so the editor does not allow renaming. To rename,
create a new request and delete the old one, then update any programming that
referenced it. Names must be unique - saving a new request with a name that is
already taken is rejected. Deleting a request removes its events and variable.

### Webhooks

The Webhooks card manages inbound HTTP endpoints. Adding a webhook named
`Doorbell Motion` creates:

- A URL like `http://<controller>:<port>/Doorbell%20Motion` (Copy puts it on the
  clipboard), answering GET and POST
- An event `Doorbell Motion Received` that fires on every accepted call
- A read-only variable `Doorbell Motion Payload` holding the request body (or
  query string), updated before the event fires

An optional per-webhook **key** requires callers to append `?key=<value>`; calls
with a missing or wrong key are rejected with HTTP 403 and fire nothing. The
listen port is set by the `Webhook Port` driver property.

## Driver Properties

### Cloud Settings

<!-- #ifdef DRIVERCENTRAL -->

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

#### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates via DriverCentral.

<!-- #else -->

#### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates from GitHub releases.

#### Update Channel \[ **_Production_** | Prerelease \]

Sets the update channel for which releases are considered during automatic
updates from GitHub releases.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

Displays the current status of the driver.

#### Driver Version (read-only)

Displays the current version of the driver.

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

## Driver Actions

<!-- #ifndef DRIVERCENTRAL -->

### Update Drivers

Triggers the driver to update from the latest release on GitHub, regardless of
the current version.

<!-- #endif -->

### Reset Driver

Deletes every request along with its events and response variable, and clears
all persisted state.

**Parameters:**

- **Are You Sure?** \[ **_No_** | Yes \] - Confirmation to reset the driver.

<div style="page-break-after: always"></div>

# <span style="color:#109EFF">Programming</span>

## Request Types

- **HTTP**: any method, HTTPS supported, custom headers, request body, and basic
  auth encoded in the URL. The response body is captured. TLS certificate
  validation is off by default (opt in per request), so self-signed LAN
  endpoints work without extra setup.
- **TCP**: opens a connection, sends the payload, and either disconnects
  immediately or waits for the response (with a timeout) before disconnecting.
- **UDP**: sends the payload as a single datagram, fire and forget. Broadcast
  addresses are not supported.
- **WOL**: broadcasts a standard Wake-on-LAN magic packet for the configured MAC
  address. The target device must have Wake-on-LAN enabled.

## Referencing Variables

Reference a variable anywhere in a URL, body, header value, or text payload with
a `PARAM{}` token:

```
PARAM{DEVICE_ID,VARIABLE_ID}
```

`DEVICE_ID` is the numeric id of the device that owns the variable.
`VARIABLE_ID` is either the numeric id of the variable or its name (matched
exactly, case-sensitive), for example `PARAM{96,1002}` or `PARAM{96,Humidity}`.
The token is replaced with the variable's current value each time the request is
sent.

You rarely need to build a token by hand: click a variable in the Requests tab
browser and its token is inserted into the focused field. If a referenced
variable cannot be found when the request fires, the send fails and the
`<Name> Failed` event fires.

Tokens are not substituted in hex payloads.

## Commands

### Send Request

Send a named request now. The Request dropdown lists every request defined in
the Requests tab. Sends are asynchronous: programming continues immediately and
the `<Name> Sent` / `<Name> Failed` event fires when the send completes.

## Events and the Response Variable

Each request owns a `<Name> Sent` event, a `<Name> Failed` event, and, for HTTP
and response-waiting TCP requests, a read-only `<Name> Response` variable.

- `<Name> Sent` fires after every successful send. For HTTP this means the
  server responded (any status code, including errors like 404 - check the
  response variable when the status matters).
- `<Name> Failed` fires when the send itself fails: connection refused, host
  unreachable, timeout waiting for a TCP response, or an unresolved `PARAM{}`
  reference.
- `<Name> Response` updates before the `Sent` event fires, so programming
  triggered by the event can read the fresh response.

Responses are capped at 8 KB.

## Webhook Events

Each webhook owns a `<Name> Received` event and a read-only `<Name> Payload`
variable. When an external system calls the webhook's URL:

1. The request body (or, for calls without a body, the query string) is
   published to `<Name> Payload`, capped at 8 KB.
1. The `<Name> Received` event fires.
1. The caller gets a `200 {"ok":true}` JSON response.

Program off the `<Name> Received` event; read `<Name> Payload` for the data.
Pair with the Variable Expressions driver to parse values out of a JSON or
query-string payload.

Webhooks are unauthenticated LAN endpoints unless a key is set. For anything
that triggers meaningful automation, set a key and treat the full URL as a
secret.

## Examples

**Turn on rack LCDs** (HTTP GET with basic auth):

1. In the Requests tab, add an HTTP request named `Rack LCD 1 On` with URL
   `http://pi:secret@192.168.1.5:9080/api/v1/uctronics-lcd/start`.
1. In programming, fire it with `Send Request` -> `Rack LCD 1 On`.

**Set a subwoofer level from a variable** (HTTP POST with a JSON body):

```
URL:  http://192.168.2.16/request.cgi
Body: {"type":"http_set","packet":[{"id":62,"feature":"level.SW","value":PARAM{100001,2500}}]}
```

**PJLink projector power on** (TCP with a response):

```
Host: 192.168.1.30   Port: 4352
Payload: %1POWR 1\r
Wait for a response: enabled
```

The projector's `OK` lands in `Projector Power On Response`.

**Wake a computer**: add a WOL request with the computer's MAC address and fire
it from any scene or schedule.

<!-- #ifdef DRIVERCENTRAL -->

<div style="page-break-after: always"></div>

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
