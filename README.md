# AirTraffic

A background network monitoring tool that continuously tracks network usage per application on macOS and Linux.

## Features

- Background service runs from boot
- Query usage by day, week, or month
- Local SQLite storage (no cloud/internet)
- Cross-platform (macOS, Linux)
- Real-time monitoring

## Installation

```bash
pip install -e .
```

## Quick Start

### 1. Install as Background Service

```bash
sudo airtraffic install
```

Installs as system service with auto-start on boot.

### 2. Query Network Usage

```bash
# Today's usage (since midnight)
airtraffic today

# This week's usage (since Monday midnight)
airtraffic week

# This month's usage (since 1st of month)
airtraffic month
```

### 3. Live Monitoring (Optional)

```bash
sudo airtraffic live
```

Real-time statistics, updates every 2 seconds.

## Commands

| Command | Description |
|---------|-------------|
| `airtraffic install` | Install and start background service (auto-start on boot) |
| `airtraffic uninstall` | Stop and remove background service |
| `airtraffic start` | Manually start the daemon |
| `airtraffic stop` | Manually stop the daemon |
| `airtraffic status` | Check if daemon is running |
| `airtraffic today` | Show today's network usage |
| `airtraffic week` | Show this week's network usage |
| `airtraffic month` | Show this month's network usage |
| `airtraffic live` | Show real-time network statistics |

## How It Works

Daemon collects stats every 60 seconds, stores in `~/.airtraffic/network_stats.db`, and aggregates for daily/weekly/monthly queries.

## Requirements

- Python 3.7+
- Root/sudo privileges (for network monitoring)
- macOS or Linux

## Data Storage

- Database: `~/.airtraffic/network_stats.db`
- Logs: `~/.airtraffic/daemon.log` (macOS only)
- PID file: `~/.airtraffic/daemon.pid`

## Uninstalling

```bash
sudo airtraffic uninstall
rm -rf ~/.airtraffic
pip uninstall airtraffic
```

## License

MIT
