<p><img src="FACTS-STRIP-URL" alt="" width="1200" height="68" /></p>

## Overview

*This software is neither affiliated with nor endorsed by Control4.*

Utility drivers that fill common gaps in Control4 programming. Combine or switch
sensors, make virtual sensors and relays, run relay devices from a light switch,
build text and math from variables, and send network commands to devices that
have no driver. Each driver installs on its own, so a project adds only the ones
it needs, and each runs on the controller with no cloud service or extra
hardware.

## Features

- Several sensors combined into one reading, or one named group of sensors
  passed through at a time
- Virtual temperature, humidity and contact sensors and relays that programming
  sets
- Relay devices controlled from a light switch, with their state kept in step
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

Passes one of several named groups of sensors through to its outputs, picked
from programming, to give a thermostat a different temperature source in each
mode.

### Device Programmer

Virtual temperature, humidity and contact sensors and relays, named in its
properties and set from programming, that keep their values across restarts.

### Light Relay

Gives each light you pick a relay connection, so a light switch runs a relay
device, with the state kept in step both ways. One driver covers every light.

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
