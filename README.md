<p align="left">
  <img src="airtraffic-icon.png" alt="AirTraffic" width="128" />
</p>

# AirTraffic

A macOS network CLI app that tracks per-app data usage, maintains a persistent history, and supports built-in data limits.

## Requirements

- **macOS 13+** (Ventura or later)
- **Xcode Command Line Tools** (`xcode-select --install`)

## Build

From the project directory:

```bash
swift build
```

## Run

From the project directory:

```bash
swift run airtraffic
```

Enter commands at the prompt:

```text
airtraffic> command
```

To stop the background collector from the project directory, run:

```bash
swift run airtraffic stop
```

Run `swift run airtraffic` again to resume data collection.

## Commands

`help` – lists commands grouped by category (`Usage` and `Limits`).

`home` – returns to the startup home screen shown after `swift run airtraffic`.

`stop` – stops the background collector without removing stored data, limits, or the app.

### Usage

`status` – shows how long the app has been running.

`live` – shows a live per-app view that refreshes every second.

`today` – shows per-app usage since 12:00 AM today.

`month` – shows per-app usage since 12:00 AM on the first day of the current month.

`since <dd:MM:yyyy HH:mm>` – shows per-app usage since a specific date and time.

`export <today|month|since>` – exports per-app usage as a CSV file.

### Limits

`limit <threshold>` – sets an overall daily data cap and sends a macOS notification when the cap is exceeded.

`limit <app> <threshold>` – sets a daily per-app data cap.

`limits` – shows all active limits with current usage versus the cap.

`limit clear <app|threshold>` – removes a limit.

## Uninstall

From the project directory:

```bash
swift run airtraffic uninstall
```

This removes the app and all stored data.

## License

MIT
