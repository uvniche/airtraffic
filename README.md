# AirTraffic

CLI Network Tool - Monitor and control network usage per application

## Install

```bash
pip install -e .
airtraffic install  # macOS/Linux: use sudo | Windows: run as Administrator
```

## Usage

### Monitor Network Usage

```bash
sudo airtraffic live                   # Live network monitor (requires sudo)
airtraffic since today                 # Show usage since today 12:00 AM
airtraffic since month                 # Show usage since first of month 12:00 AM
airtraffic since "17:01:2026 14:30:00" # Show usage since custom date/time (dd:mm:yyyy hh:mm:ss)
```

### Block Applications

```bash
sudo airtraffic block Chrome           # Block Chrome from using network
sudo airtraffic unblock Chrome         # Unblock Chrome
airtraffic list-blocked                # List all blocked applications
```

## Uninstall

```bash
airtraffic uninstall  # macOS/Linux: use sudo | Windows: run as Administrator
```
