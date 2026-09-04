<p align="left">
  <img src="airtraffic-icon.png" alt="AirTraffic" width="128" />
</p>

# AirTraffic

A macOS network CLI app that tracks per-app data usage, maintains a persistent history, and supports built-in data limits.

## Requirements

- **Apple silicon Mac running macOS 13 or later**
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

Run one AirTraffic command at a time in your terminal:

```bash
airtraffic <command>
```

Running `airtraffic` without a command prints a usage hint and exits. Run the
single help command to see all usage and limit commands:

```bash
airtraffic help
```

For example, to show today's usage:

```bash
airtraffic today
```

Commands that collect or display usage start the background collector automatically.

## Commands

`help` – shows all usage and limit commands.

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
