# AirTraffic

CLI Network Tool

## Install

```bash
pip install -e .
airtraffic install  # macOS/Linux: use sudo | Windows: run as Administrator
```

## Usage

### Monitor Network Usage

```bash
airtraffic live                        # macOS/Linux: use sudo | Windows: run as Administrator
airtraffic since today                 # Show usage since today 12:00 AM
airtraffic since month                 # Show usage since first of month 12:00 AM
airtraffic since "17:01:2026 14:30:00" # Show usage since custom date/time (dd:mm:yyyy hh:mm:ss)
```

### Allow/Block Applications

```bash
airtraffic block Application           # macOS/Linux: use sudo | Windows: run as Administrator
airtraffic allow Application           # macOS/Linux: use sudo | Windows: run as Administrator
airtraffic block all                   # macOS/Linux: use sudo | Windows: run as Administrator
airtraffic allow all                   # macOS/Linux: use sudo | Windows: run as Administrator
airtraffic blocked                     # List blocked applications
airtraffic allowed                     # List allowed applications
```

## Uninstall

```bash
airtraffic uninstall  # macOS/Linux: use sudo | Windows: run as Administrator
```
