# AirTraffic

macOS CLI Network App

## Requirements

- **macOS 13+** (Ventura or later)
- **Xcode Command Line Tools** (or Xcode). Install with: `xcode-select --install`
- **terminal-notifier**. Install with: `brew install terminal-notifier`

## Build & Run

From the project directory:

```bash
swift build
```

## Commands

### Daemon

**daemon** – start the daemon and install a login item so it runs at login:

```bash
swift run airtraffic daemon
```

**status** – show how long the daemon has been running:

```bash
swift run airtraffic status
```

**uninstall** – remove the login item and delete all stored data:

```bash
swift run airtraffic uninstall
```

### Usage

**live** – live per-app view, refresh every second:

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

**export** – export per-app usage as a CSV file (period: `today`, `month`, or `since`):

```bash
swift run airtraffic export today
```

### Limits

**limit** – set a daily data cap (overall or per-app). Sends a macOS notification when exceeded:

```bash
swift run airtraffic limit 2GB
swift run airtraffic limit "Google Chrome" 500MB
```

**limits** – show all active limits with current usage vs cap:

```bash
swift run airtraffic limits
```

**limit clear** – remove a limit:

```bash
swift run airtraffic limit clear 2GB
swift run airtraffic limit clear "Google Chrome"
```

## License

MIT