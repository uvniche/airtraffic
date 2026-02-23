# AirTraffic

A **macOS-only** CLI that shows which apps are using how much network data, updated live in the terminal. No GUI, no Xcode project, no Apple Developer account — build and run from the command line.

## Requirements

- **macOS 13+** (Ventura or later)
- **Xcode Command Line Tools** (or Xcode). Install with: `xcode-select --install`

## Build & run

From the project directory:

```bash
# Build
swift build

# Run (live view, refresh every 2 seconds)
swift run airtraffic
# or
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
- Parses output and shows **top 20** processes by network usage
- Refreshes every **2 seconds** with:
  - **↓ Down** – bytes received in the last interval (and rate)
  - **↑ Up** – bytes sent in the last interval (and rate)
  - **Total/s** – combined rate

Only **Wi‑Fi** and **wired** interfaces are included (no loopback). No root/sudo needed.

## Open source

You can build and run this locally without an Apple Developer account or code signing. The project uses only the Swift toolchain and standard system tools (`nettop`).

## License

MIT
