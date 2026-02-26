# CLAUDE.md - Finite Labs Essentials

## Project Overview

This is a suite of Control4 DriverWorks drivers (Lua) for sensor management. The
drivers are built for two distribution targets using a preprocessor system:

- **`oss`** - Open-source distribution (GitHub releases, self-updating via
  GitHub API)
- **`drivercentral`** - Commercial distribution (DriverCentral cloud licensing)

## Repository Structure

```
drivers/                  # Driver source directories (one per driver)
  {name}/
    driver.lua            # Main driver source
    driver.xml            # Device metadata, properties, actions, commands
    driver.c4zproj        # Package manifest for .c4z bundling
    squishy               # Lua module bundling config (squish)
    www/
      documentation/      # Driver-specific docs
        index.md
        images/           # header.png, finite-labs-logo.png
      icons/              # PNG icons at standard sizes
src/
  constants.lua           # Shared constants (SHOW_PROPERTY, HIDE_PROPERTY, etc.)
  lib/                    # Shared libraries
vendor/                   # Third-party dependencies
tools/
  preprocess              # Python preprocessor for conditional compilation
  pandoc-remove-style.lua # Pandoc filter for README generation
documentation/            # Suite-level documentation
  index.md                # Generates README.md via pandoc
build/                    # (generated) Preprocessed output per distribution
dist/                     # (generated) Packaged .c4z files and PDFs
```

## Build System

### Prerequisites

```sh
npm install
npm run init    # Creates Python venv, installs tools, clones driverpackager
```

### Full Build

```sh
npm run build
```

Pipeline: `fmt` -> `preprocess` -> `update-driver.xml` -> `docs` -> `package` ->
`zip`

### Key Scripts

| Script                 | Purpose                                            |
| ---------------------- | -------------------------------------------------- |
| `npm run fmt`          | Format Lua (stylua) and Markdown (prettier)        |
| `npm run preprocess`   | Run preprocessor for all distributions             |
| `npm run build`        | Full build pipeline                                |
| `npm run build:nodocs` | Build without generating documentation             |
| `npm run clean`        | Remove all generated files, node_modules, and venv |

### Formatting Rules

- **Lua**: stylua - 2-space indent, 120 column width, double quotes preferred,
  Unix line endings
- **Markdown**: prettier with `--prose-wrap always`

## Existing Drivers

| Driver               | Purpose                                                                            | Key Shared Libs                                                 |
| -------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `sensor_aggregator`  | Combines multiple sensor inputs into one output using aggregation funcs            | bindings, values, persist, logging, utils                       |
| `sensor_multiplexer` | Switches between named sensor input groups (e.g., Home/Away)                       | bindings, values, persist, events, conditionals, logging, utils |
| `device_programmer`  | Creates programmable virtual sensors and relays settable from Control4 programming | bindings, persist, logging, utils                               |

## Shared Library Reference

### `src/lib/utils.lua`

Global utility functions: `SendToProxy`, `SendToDevice`, `ParseXml`,
`CheckMinimumVersion`, `GetPropertyResetValues`, `GetDeviceBindings`, `round`,
`c2f`/`f2c`, `toboolean`, `tointeger`, `IsEmpty`, `TableDeepCopy`,
`Serialize`/`Deserialize`, and many more. Required by all drivers via
`require("lib.utils")`.

### `src/lib/bindings.lua`

Manages dynamic bindings (runtime-created connections). Handles namespace+key
addressing, persistent storage, ID allocation, and restore-on-boot. Binding
types: `CONTROL` (temperature, humidity values) and `PROXY` (contact sensors).

### `src/lib/values.lua`

Manages dynamic values with optional Control4 variable and property support.
Handles variable creation/deletion, property display with suffixes, persistent
storage with index ordering, and soft-delete with placeholder preservation.

### `src/lib/persist.lua`

Key-value persistence wrapper with in-memory caching. Wraps Control4's
`PersistGetValue`/ `PersistSetValue` API. Supports encrypted values and data
migrations.

### `src/lib/events.lua`

Manages dynamic events (namespace+key addressed). Handles creation, firing,
deletion, and restore-on-boot with cleanup of stale event IDs.

### `src/lib/conditionals.lua`

Manages dynamic conditionals for Control4 programming. Supports creation,
deletion, and test functions (`TC[]` table). Also provides global
`GetConditionals()`.

### `src/lib/logging.lua`

Logging with configurable levels (Fatal through Ultra) and output modes (Print,
Log, or both). Auto-expires after 3 hours via timer set in `OPC.Log_Mode`.

### `src/lib/http.lua`

HTTP client returning Deferred promises. Wraps Control4's `urlDo` with
GET/POST/PUT/DELETE. **OSS only** (excluded from DriverCentral builds).

### `src/lib/github-updater.lua`

Self-update mechanism via GitHub releases API. Checks versions, downloads
assets, and installs via TCP to local Director. **OSS only**.

### `src/constants.lua`

Shared constants: `SHOW_PROPERTY` (0), `HIDE_PROPERTY` (1), `SELECT_OPTION`,
button IDs/actions.

## Patterns for Adding a New Driver

### File Checklist

Every driver needs these files:

```
drivers/{name}/
  driver.lua              # Main source (see boilerplate below)
  driver.xml              # Device metadata (see template below)
  driver.c4zproj          # Package manifest
  squishy                 # Module bundling config
  www/
    documentation/
      index.md            # Driver documentation
      images/
        header.png        # Copy from existing driver
        finite-labs-logo.png
    icons/                # PNG icons (copy from existing driver)
      device_sm.png, device_lg.png
      experience_{20,30,40,50,60,70,80,90,100,110,120,130,140,300,512,1024}.png
```

### Registration in package.json

Add to `config.drivers` (space-separated) and `config.driver_names`:

```json
{
  "config": {
    "drivers": "sensor_aggregator sensor_multiplexer device_programmer your_driver",
    "driver_names": {
      "your_driver": "Your Driver"
    }
  }
}
```

### driver.lua Boilerplate

```lua
--- Your Driver Name
--#ifdef DRIVERCENTRAL
DC_PID = nil
DC_X = nil
DC_FILENAME = "your_driver.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-finite-labs-essentials"
DRIVER_FILENAMES = { "your_driver.c4z" }
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local bindings = require("lib.bindings")
local persist = require("lib.persist")
-- Add other shared libs as needed:
-- local values = require("lib.values")
-- local events = require("lib.events")
-- local conditionals = require("lib.conditionals")
local constants = require("constants")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

-- ... driver-specific code ...

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  -- Restore persisted state (add as needed)
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Fire OnPropertyChanged for all properties
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    if toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver updates")
      UpdateDrivers()
    end
  end, true)
  --#endif

  gInitialized = true
  UpdateProperty("Driver Status", "Ready")
end

--------------------------------------------------------------------------------
-- Standard OPC Handlers (required for all drivers)
--------------------------------------------------------------------------------

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
    return
  end
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    UpdateProperty("Log Level", "3 - Info", true)
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
  OnPropertyChanged("Log Level")
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
    DEBUG_WEBSOCKET = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
    DEBUG_WEBSOCKET = false
  end
end

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
end
--#endif

--------------------------------------------------------------------------------
-- Standard EC Handlers
--------------------------------------------------------------------------------

function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")
  bindings:reset()
  -- Reset other state as needed
  local resetValues = GetPropertyResetValues({})
  for propName, defaultValue in pairs(resetValues) do
    UpdateProperty(propName, defaultValue, true)
  end
end

--#ifndef DRIVERCENTRAL
function EC.Update_Drivers()
  log:trace("EC.Update_Drivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end

function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if not IsEmpty(updatedDrivers) then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      else
        log:info("No driver updates available")
      end
    end, function(error)
      log:error("An error occurred updating drivers: %s", error)
    end)
end
--#endif
```

### driver.xml Template

Standard structure with required properties:

```xml
<devicedata>
  <name>Your Driver Name</name>
  <version/>
  <manufacturer>Finite Labs</manufacturer>
  <model>Your Driver Name</model>
  <creator>Derek Miller</creator>
  <small image_source="c4z">icons/device_sm.png</small>
  <large image_source="c4z">icons/device_lg.png</large>
  <control>lua_gen</control>
  <driver>DriverWorks</driver>
  <copyright>Copyright 2026 Finite Labs, LLC. All rights reserved.</copyright>
  <created>MM/DD/YYYY 12:00:00 PM</created>
  <modified/>
  <combo>true</combo>
  <minimum_os_version>3.3.0</minimum_os_version>
  <composer_categories>
    <category>Sensors</category>
  </composer_categories>
  <conditionals/>
  <events/>
  <config>
    <script file="driver.lua" jit="1"/>
    <documentation file="www/documentation/index.html"/>
    <properties>
      <!-- === Standard properties (required for all drivers) === -->
      <property>
        <name>Cloud Settings</name>
        <type>LABEL</type>
        <default>Cloud Settings</default>
      </property>
      <!-- #ifdef DRIVERCENTRAL -->
      <property>
        <name>Cloud Status</name>
        <default/>
        <type>STRING</type>
        <readonly>true</readonly>
      </property>
      <!-- #endif -->
      <property>
        <name>Automatic Updates</name>
        <type>LIST</type>
        <items>
          <item>Off</item>
          <item>On</item>
        </items>
        <default>On</default>
      </property>
      <!-- #ifndef DRIVERCENTRAL -->
      <property>
        <name>Update Channel</name>
        <type>LIST</type>
        <default>Production</default>
        <items>
          <item>Production</item>
          <item>Prerelease</item>
        </items>
      </property>
      <!-- #endif -->
      <property>
        <name>Driver Settings</name>
        <type>LABEL</type>
        <default>Driver Settings</default>
      </property>
      <property>
        <name>Driver Status</name>
        <type>STRING</type>
        <default/>
        <readonly>true</readonly>
      </property>
      <property>
        <name>Driver Version</name>
        <type>STRING</type>
        <default/>
        <readonly>true</readonly>
      </property>
      <property>
        <name>Log Level</name>
        <type>LIST</type>
        <default>3 - Info</default>
        <items>
          <item>0 - Fatal</item>
          <item>1 - Error</item>
          <item>2 - Warning</item>
          <item>3 - Info</item>
          <item>4 - Debug</item>
          <item>5 - Trace</item>
          <item>6 - Ultra</item>
        </items>
      </property>
      <property>
        <name>Log Mode</name>
        <type>LIST</type>
        <default>Off</default>
        <items>
          <item>Off</item>
          <item>Print</item>
          <item>Log</item>
          <item>Print and Log</item>
        </items>
      </property>
      <!-- === Add driver-specific properties below === -->
    </properties>
    <actions>
      <!-- #ifndef DRIVERCENTRAL -->
      <action>
        <name>Update Drivers</name>
        <command>Update_Drivers</command>
      </action>
      <!-- #endif -->
      <action>
        <name>Reset Driver</name>
        <command>Reset_Driver</command>
        <params>
          <param>
            <name>Are You Sure?</name>
            <type>LIST</type>
            <items>
              <item>No</item>
              <item>Yes</item>
            </items>
          </param>
        </params>
      </action>
      <!-- Add driver-specific actions below -->
    </actions>
    <commands>
      <!-- Add driver-specific commands below -->
    </commands>
  </config>
  <capabilities/>
  <connections/>
</devicedata>
```

### squishy Template

```
Main "driver.lua"

#ifdef DRIVERCENTRAL
Module "cloud-client-byte" "../../vendor/cloud-client-byte.lua"
#endif
Module "deferred" "../../vendor/deferred.lua"
Module "drivers-common-public.global.handlers" "../../vendor/drivers-common-public/global/handlers.lua"
Module "drivers-common-public.global.lib" "../../vendor/drivers-common-public/global/lib.lua"
Module "drivers-common-public.global.timer" "../../vendor/drivers-common-public/global/timer.lua"
Module "drivers-common-public.global.url" "../../vendor/drivers-common-public/global/url.lua"
Module "JSON" "../../vendor/JSON.lua"
Module "xml.xml2lua" "../../vendor/xml/xml2lua.lua"
Module "xml.xmlhandler.dom" "../../vendor/xml/xmlhandler/dom.lua"
Module "xml.xmlhandler.print" "../../vendor/xml/xmlhandler/print.lua"
Module "xml.xmlhandler.tree" "../../vendor/xml/xmlhandler/tree.lua"
Module "xml.XmlParser" "../../vendor/xml/XmlParser.lua"

Module "lib.bindings" "../../src/lib/bindings.lua"
# Add driver-specific shared libs here, e.g.:
# Module "lib.conditionals" "../../src/lib/conditionals.lua"
# Module "lib.events" "../../src/lib/events.lua"
# Module "lib.values" "../../src/lib/values.lua"
#ifndef DRIVERCENTRAL
Module "lib.github-updater" "../../src/lib/github-updater.lua"
Module "lib.http" "../../src/lib/http.lua"
Module "version" "../../vendor/version.lua"
#endif
Module "lib.logging" "../../src/lib/logging.lua"
Module "lib.persist" "../../src/lib/persist.lua"
Module "lib.utils" "../../src/lib/utils.lua"

Module "constants" "../../src/constants.lua"

#ifdef DRIVERCENTRAL
Output "../../../../dist/drivercentral/your_driver.lua"
#else
Output "../../../../dist/oss/your_driver.lua"
#endif
Option "minify" "true"
Option "minify_level" "none"
Option "minify_comments" "true"
Option "minify_emptylines" "true"
```

### driver.c4zproj Template

```xml
<Driver type="c4z" name="your_driver" squishLua="true">
  <Items>
    <Item type="dir" c4zDir="www" name="www" recurse="true" exclude="false"/>
    <Item type="file" name="driver.lua"/>
    <Item type="file" name="driver.xml"/>
  </Items>
</Driver>
```

## Key Conventions

### Preprocessor Directives

Conditional compilation for distribution-specific code:

- **Lua**: `--#ifdef DRIVERCENTRAL` / `--#ifndef DRIVERCENTRAL` / `--#else` /
  `--#endif`
- **XML/MD**: `<!-- #ifdef DRIVERCENTRAL -->` / `<!-- #ifndef DRIVERCENTRAL -->`
  / `<!-- #else -->` / `<!-- #endif -->`
- **Squishy**: `#ifdef DRIVERCENTRAL` / `#ifndef DRIVERCENTRAL` / `#else` /
  `#endif`

### Handler Tables

| Table    | Purpose                               | Naming Convention                                |
| -------- | ------------------------------------- | ------------------------------------------------ |
| `OPC.X`  | Property change handlers              | `OPC.Property_Name` (spaces become underscores)  |
| `EC.X`   | Action/command execute handlers       | `EC.CommandName` (from `<command>` in XML)       |
| `RFP[]`  | Receive-from-proxy (binding messages) | Indexed by binding ID                            |
| `OBC[]`  | On-binding-changed                    | Indexed by binding ID                            |
| `GCPL.X` | Dynamic command parameter lists       | `GCPL.Command_Name` (matches command name)       |
| `TC[]`   | Test conditionals                     | Indexed by conditional name                      |
| `OVC[]`  | On-variable-changed                   | Indexed by variable name (spaces to underscores) |

### Dynamic Bindings

- Use namespace+key pattern via `lib/bindings.lua`
- Binding types: `CONTROL` for temperature/humidity values, `PROXY` for contact
  sensors
- All bindings are output (provider) bindings unless explicitly created as input
  (consumer)

### Contact Sensor State

- Runtime state changes: `CLOSED`/`OPENED` (triggers programming events)
- Init/bind state: `STATE_CLOSED`/`STATE_OPENED` (sets state without triggering
  programming)
- Use `gInitialized` flag to distinguish init vs runtime

### Persistence

- All dynamic state persisted via `lib/persist.lua`
- Bindings auto-persist and restore via `bindings:restoreBindings()`
- Values auto-persist and restore via `values:restoreValues()`
- Events restore via `events:restoreEvents()`

## Diagnostics

- `C4`, `Properties`, `Variables`, and other Control4 globals are provided by
  the Control4 runtime. LSP warnings about undefined globals for these are
  expected.
- `.emmyrc.json` configures EmmyLua LSP with Control4 type stubs from a separate
  `lua-addons` repository.
- Ignored directories: `.claude`, `.git`, `.idea`, `.venv`, `build`, `dist`,
  `node_modules`

## Documentation

- Each driver has `www/documentation/index.md` following the style conventions
  in `.claude/skills/fix-docs/SKILL.md`
- Suite-level docs are in `documentation/index.md`, which auto-generates
  `README.md` via pandoc
- Use the `/fix-docs` skill to validate and fix driver documentation
