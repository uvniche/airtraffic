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

Release build (faster binary):

```bash
swift build -c release
.build/release/airtraffic
```

### Commands

**daemon** – start background collector and install login item (runs at login):

```bash
swift run airtraffic daemon
```

**status** – show since when the collector has been up (+ today’s top apps):

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

## License

MIT
