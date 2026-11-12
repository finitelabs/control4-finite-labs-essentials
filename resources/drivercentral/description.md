<p><img src="https://drivercentral.io/images/companies/61/Essentials/facts-strip-2400x136.png?1794365656000" alt="" width="1200" height="68" /></p>

## Overview

*This software is neither affiliated with nor endorsed by Control4.*

Utility drivers that fill common gaps in Control4 programming. Combine or switch
sensors, make virtual sensors and relays, use lights as relays, build text and
math from variables, and send network commands to devices that have no driver.
Each driver installs on its own, so a project adds only the ones it needs, and
each runs on the controller with no cloud service or extra hardware.

## Features

- Several sensors combined into one reading, or one named group of sensors
  passed through at a time
- Virtual temperature, humidity, contact and relay devices that programming sets
- Lights used as relays by other drivers, with their state kept in step
- Text and math built from Control4 variables, recalculated when they change
- HTTP, TCP, UDP and Wake-on-LAN commands sent from programming
- Inbound webhooks that fire programming events with what they carry
- Composer tabs for expressions and requests, with a searchable variable browser

## Included drivers

### Sensor Aggregator

Combines up to 20 temperature, 20 humidity and 20 contact sensors into one
output of each kind, by the average, median, lowest, highest or another function
you choose.

### Sensor Multiplexer

Passes one of several named groups of sensors through to a single set of
outputs, switched from programming.

### Humidity Alert

Raises an alert when something adds moisture to a room and its humidity rises,
and holds it until the room has dried out, in a dry winter and a humid summer
alike. It closes a contact for Control4 programming, and can switch a device
itself, a bathroom exhaust fan for example, by a relay, light switches or a fan
speed controller.

### Device Programmer

Virtual temperature, humidity, contact and relay devices, named in its
properties and set from programming, that keep their values across restarts.

### Light Relay

Gives each light you pick a relay connection, so a driver that switches a relay
can switch the light instead, and the light's state reports back as the relay's.
One driver covers every light.

### Variable Expressions

Named expressions that build text or do math from Control4 variables, each with
its own result variable and event, recalculated when a variable it reads
changes. Written in a Composer tab with a variable browser and a live preview.

### Network Requests

Named HTTP, TCP, UDP and Wake-on-LAN requests, sent from programming with one
command, with Sent and Failed events and the last response in a variable.
Inbound webhooks fire events with their payload.

## System requirements

- Control4 OS 3.3+
