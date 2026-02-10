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

### Allow/Block Applications Network Access

**macOS**: Uses Application Firewall (`socketfilterfw`) to block apps at the kernel level  
**Linux**: Uses `iptables`/`nftables` to block network traffic  
**Windows**: Uses Windows Firewall (`netsh`) to block network traffic

Works reliably across all platforms with automatic fallback methods.

```bash
sudo airtraffic block Application      # Block app from accessing network (requires sudo/admin)
sudo airtraffic allow Application      # Allow app to access network (requires sudo/admin)
sudo airtraffic block all              # Block all running apps (requires sudo/admin)
sudo airtraffic allow all              # Allow all blocked apps (requires sudo/admin)
airtraffic blocked                     # List blocked applications
airtraffic allowed                     # List allowed applications
```

## Uninstall

```bash
airtraffic uninstall  # macOS/Linux: use sudo | Windows: run as Administrator
```
