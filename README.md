# AirTraffic

macOS CLI Network Tool

## Requirements

- **macOS 13+** (Ventura or later)
- **Xcode Command Line Tools** (or Xcode). Install with: `xcode-select --install`

## Build & run

From the project directory:

Build:

```bash
swift build
```

### Commands

**daemon** – start the daemon and install a login item so it runs at login:

```bash
swift run airtraffic daemon
```

**status** – show how long the daemon has been running:

```bash
swift run airtraffic status
```

**live** – live per-app view, refresh every 2 seconds:

```bash
swift run airtraffic live
```

**today** – per-app usage since 12:00 AM today:

```bash
swift run airtraffic today
```

**month** – per-app usage since 12:00 AM on the first day of the current month:

```bash
swift run airtraffic month
```

**since** – per-app usage since a specific date & time (format: `dd:MM:yyyy HH:mm`):

```bash
swift run airtraffic since 01:01:2026 00:00
```

**uninstall** – remove the login item and delete all stored data:

```bash
swift run airtraffic uninstall
```

## License

MIT
