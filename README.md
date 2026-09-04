<p align="left">
  <img src="airtraffic-icon.png" alt="AirTraffic" width="128" />
</p>

# AirTraffic

A macOS network CLI app that tracks per-app data usage, maintains a persistent history, and supports built-in data limits.

## Requirements

- **macOS 13+** (Ventura or later)
- **Apple silicon Mac**
- **Xcode Command Line Tools** (`xcode-select --install`)
- **Homebrew** ([brew.sh](https://brew.sh/))

## Install

```bash
brew tap uvniche/airtraffic https://github.com/uvniche/airtraffic
brew install uvniche/airtraffic/airtraffic
```

## Update

```bash
brew upgrade uvniche/airtraffic/airtraffic
```

## Run

Run AirTraffic in your terminal:

```bash
airtraffic
```

Then enter commands at the prompt:

```text
airtraffic> command
```

To quit the app, run:

```bash
airtraffic quit
```

Run `airtraffic` again to restart the app.

## Commands

`help` – lists commands grouped by category (`Usage` and `Limits`).

`home` – returns to the startup home screen in interactive mode.

`quit` – quits the app without removing its stored data or limits.

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

First quit AirTraffic and remove its stored data and login item:

```bash
airtraffic uninstall
```

Then remove the Homebrew package:

```bash
brew uninstall airtraffic
brew untap uvniche/airtraffic
```

## License

MIT
