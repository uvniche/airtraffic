# Airtraff

CLI Network Tool

## Install

```bash
pip install -e .
airtraff install  # macOS/Linux: use sudo | Windows: run as Administrator
```

## Usage

### Monitor Network Usage

```bash
airtraff live                        # macOS/Linux: use sudo | Windows: run as Administrator
airtraff since today                 # Show usage since today 12:00 AM
airtraff since month                 # Show usage since first of month 12:00 AM
airtraff since "17:01:2026 14:30:00" # Show usage since custom date/time (dd:mm:yyyy hh:mm:ss)
```

### Allow/Block Applications

```bash
airtraff block Application           # macOS/Linux: use sudo | Windows: run as Administrator
airtraff allow Application           # macOS/Linux: use sudo | Windows: run as Administrator
airtraff block all                   # macOS/Linux: use sudo | Windows: run as Administrator
airtraff allow all                   # macOS/Linux: use sudo | Windows: run as Administrator
airtraff blocked                     # List blocked applications
airtraff allowed                     # List allowed applications
```

## Uninstall

```bash
airtraff uninstall  # macOS/Linux: use sudo | Windows: run as Administrator
```
