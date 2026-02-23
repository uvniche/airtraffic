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

Run (live view, refresh every 2 seconds):

```bash
swift run airtraffic

# Or:
.build/debug/airtraffic
```
Release build (faster binary):

```bash
swift build -c release
.build/release/airtraffic
```

Stop with **Ctrl+C**.

## What it does

- Runs `nettop` (built-in macOS tool) in per-process, CSV mode
- Parses output and shows **top 20** apps by network usage
- Refreshes every **2 seconds** with:
  - **↓ Down** – bytes received in the last interval (and rate)
  - **↑ Up** – bytes sent in the last interval (and rate)
  - **Total/s** – combined rate

Only **Wi‑Fi** and **wired** interfaces are included (no loopback). No root/sudo needed.

## License

MIT
