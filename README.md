# AirTraffic

macOS CLI Network App

## About

macOS CLI network app that tracks per-app data usage, keeps persistent history, and supports built-in data limits.

- **Per-app usage**: live view plus `today`, `month`, and `since <date>` summaries.
- **Persistent history**: keep usage over time, export to CSV.
- **Built-in limits**: set daily caps (overall or per-app) with macOS notifications.

## Requirements

- **macOS 13+** (Ventura or later)
- **Xcode** ([Mac App Store](https://apps.apple.com/app/xcode/id497799835)) **or Xcode Command Line Tools** ([Apple downloads](https://developer.apple.com/download/more/), search “Command Line Tools”, or `xcode-select --install`)

## Build

From the project directory:

```bash
swift build
```

Or with Xcode:

- Open `Package.swift` in Xcode
- Product → Build (or press `⌘B`)

## Run

From the project directory:

```bash
swift run airtraffic
```

You can also launch it from **Applications** via `AirTraffic.app` (opens Terminal and runs AirTraffic).

Run commands inside the prompt:

```text
airtraffic> command
```

Or with Xcode:

- Open `Package.swift` in Xcode
- Product → Run (or press `⌘R`)

## Commands

`help` – list commands grouped by category (`Usage` and `Limits`).

`home` – return to the startup home screen shown after `swift run airtraffic`.

### Usage

`status` – show how long the app has been running.

`live` – live per-app view, refresh every second.

`today` – per-app usage since 12:00 AM today.

`month` – per-app usage since 12:00 AM on the first day of the current month.

`since <dd:MM:yyyy HH:mm>` – per-app usage since a specific date & time.

`export <today|month|since>` – export per-app usage as a CSV file.

### Limits

`limit <threshold>` – set an overall daily data cap. Sends a macOS notification when exceeded.

`limit <app> <threshold>` – set a daily per-app data cap.

`limits` – show all active limits with current usage vs cap.

`limit clear <app|threshold>` – remove a limit.

## Uninstall

From the project directory:

```bash
swift run airtraffic uninstall
```

Removes the app and all stored data.

## License

MIT