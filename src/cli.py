"""CLI interface for AirTraffic."""

import sys
import time
import os
import platform
from datetime import datetime
from airtraffic.monitor import NetworkMonitor
from airtraffic.database import NetworkDatabase
from airtraffic.daemon import AirTrafficDaemon


def clear_screen():
    """Clear the terminal screen."""
    os.system('clear' if os.name != 'nt' else 'cls')


def format_bytes(bytes_val: int) -> str:
    """Format bytes to human-readable format."""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_val < 1024.0:
            return f"{bytes_val:.2f} {unit}"
        bytes_val /= 1024.0
    return f"{bytes_val:.2f} PB"


def display_historical_stats(stats: dict, title: str, period: str):
    """Display historical network statistics.
    
    Args:
        stats: Dictionary of app statistics
        title: Title to display
        period: Time period description
    """
    print("=" * 80)
    print(f"AirTraffic - {title}")
    print(f"Period: {period}")
    print("=" * 80)
    print()
    
    if not stats:
        print("No data available for this period.")
        print("Make sure the daemon is running: airtraffic start")
        return
    
    # Sort by total traffic
    sorted_apps = sorted(
        stats.items(),
        key=lambda x: x[1]["sent"] + x[1]["recv"],
        reverse=True
    )
    
    print(f"{'Application':<35} {'Upload':<15} {'Download':<15} {'Total':<15}")
    print("-" * 80)
    
    total_sent = 0
    total_recv = 0
    
    for app_name, app_stats in sorted_apps:
        upload = format_bytes(app_stats["sent"])
        download = format_bytes(app_stats["recv"])
        total = format_bytes(app_stats["sent"] + app_stats["recv"])
        
        print(f"{app_name:<35} {upload:<15} {download:<15} {total:<15}")
        
        total_sent += app_stats["sent"]
        total_recv += app_stats["recv"]
    
    print("-" * 80)
    print(f"{'TOTAL':<35} {format_bytes(total_sent):<15} {format_bytes(total_recv):<15} {format_bytes(total_sent + total_recv):<15}")
    print()


def show_today():
    """Show today's network statistics."""
    db = NetworkDatabase()
    stats = db.get_today_stats()
    today = datetime.now().strftime("%A, %B %d, %Y")
    display_historical_stats(stats, "Today's Usage", f"Since midnight (12:00 AM) - {today}")


def show_week():
    """Show this week's network statistics."""
    db = NetworkDatabase()
    stats = db.get_week_stats()
    now = datetime.now()
    days_since_monday = now.weekday()
    monday = now.replace(hour=0, minute=0, second=0, microsecond=0)
    monday = monday.replace(day=now.day - days_since_monday)
    period = f"Since Monday, {monday.strftime('%B %d')} at 12:00 AM"
    display_historical_stats(stats, "This Week's Usage", period)


def show_month():
    """Show this month's network statistics."""
    db = NetworkDatabase()
    stats = db.get_month_stats()
    month_start = datetime.now().replace(day=1).strftime("%B %d, %Y")
    display_historical_stats(stats, "This Month's Usage", f"Since {month_start} at 12:00 AM")


def live_monitor(interval: int = 2):
    """Display live network statistics.
    
    Args:
        interval: Update interval in seconds (default: 2)
    """
    monitor = NetworkMonitor()
    
    print("AirTraffic - Live Network Monitor")
    print("Press Ctrl+C to exit\n")
    
    # Check if running with sufficient privileges
    if hasattr(os, 'geteuid') and os.geteuid() != 0:
        print("Warning: Running without root privileges.")
        print("Some network statistics may not be available.")
        print("Try running with: sudo airtraffic live\n")
    
    try:
        # Initial stats collection
        monitor.get_network_stats()
        time.sleep(1)  # Wait a bit for initial measurement
        
        while True:
            clear_screen()
            
            print("=" * 72)
            print("AirTraffic - Live Network Monitor")
            print(f"Update interval: {interval} seconds | Press Ctrl+C to exit")
            print("=" * 72)
            print()
            
            # Get and display stats
            stats = monitor.get_network_stats(interval=interval)
            lines = monitor.format_stats(stats)
            
            for line in lines:
                print(line)
            
            print()
            print("=" * 72)
            print(f"Last updated: {time.strftime('%Y-%m-%d %H:%M:%S')}")
            
            time.sleep(interval)
            
    except KeyboardInterrupt:
        print("\n\nExiting AirTraffic...")
        sys.exit(0)
    except Exception as e:
        print(f"\nError: {e}")
        sys.exit(1)


def install_service():
    """Install AirTraffic as a system service."""
    system = platform.system()
    
    if system == "Darwin":  # macOS
        install_launchd_service()
    elif system == "Linux":
        install_systemd_service()
    else:
        print(f"Service installation not supported on {system}")
        print("You can manually start the daemon with: airtraffic start")


def uninstall_service():
    """Uninstall AirTraffic system service."""
    system = platform.system()
    
    # Stop daemon first
    daemon = AirTrafficDaemon()
    daemon.stop()
    
    if system == "Darwin":  # macOS
        uninstall_launchd_service()
    elif system == "Linux":
        uninstall_systemd_service()
    else:
        print(f"Service uninstallation not supported on {system}")


def install_systemd_service():
    """Install systemd service on Linux."""
    service_content = f"""[Unit]
Description=AirTraffic Network Monitor
After=network.target

[Service]
Type=simple
ExecStart={sys.executable} -m airtraffic.daemon
Restart=always
RestartSec=10
User={os.getenv('USER')}

[Install]
WantedBy=multi-user.target
"""
    
    service_path = os.path.expanduser("~/.config/systemd/user/airtraffic.service")
    os.makedirs(os.path.dirname(service_path), exist_ok=True)
    
    with open(service_path, 'w') as f:
        f.write(service_content)
    
    print("Installing systemd service...")
    os.system("systemctl --user daemon-reload")
    os.system("systemctl --user enable airtraffic.service")
    os.system("systemctl --user start airtraffic.service")
    print("✓ Service installed and started!")
    print("  The daemon will now start automatically on boot.")


def uninstall_systemd_service():
    """Uninstall systemd service on Linux."""
    print("Uninstalling systemd service...")
    os.system("systemctl --user stop airtraffic.service")
    os.system("systemctl --user disable airtraffic.service")
    
    service_path = os.path.expanduser("~/.config/systemd/user/airtraffic.service")
    if os.path.exists(service_path):
        os.remove(service_path)
    
    os.system("systemctl --user daemon-reload")
    print("✓ Service uninstalled!")


def install_launchd_service():
    """Install launchd service on macOS."""
    plist_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.airtraffic.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>{sys.executable}</string>
        <string>-m</string>
        <string>airtraffic.daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{os.path.expanduser('~/.airtraffic/daemon.log')}</string>
    <key>StandardErrorPath</key>
    <string>{os.path.expanduser('~/.airtraffic/daemon.error.log')}</string>
</dict>
</plist>
"""
    
    plist_path = os.path.expanduser("~/Library/LaunchAgents/com.airtraffic.daemon.plist")
    os.makedirs(os.path.dirname(plist_path), exist_ok=True)
    
    with open(plist_path, 'w') as f:
        f.write(plist_content)
    
    print("Installing launchd service...")
    os.system(f"launchctl load {plist_path}")
    print("✓ Service installed and started!")
    print("  The daemon will now start automatically on boot.")


def uninstall_launchd_service():
    """Uninstall launchd service on macOS."""
    plist_path = os.path.expanduser("~/Library/LaunchAgents/com.airtraffic.daemon.plist")
    
    print("Uninstalling launchd service...")
    os.system(f"launchctl unload {plist_path}")
    
    if os.path.exists(plist_path):
        os.remove(plist_path)
    
    print("✓ Service uninstalled!")


def main():
    """Main entry point for the CLI."""
    if len(sys.argv) < 2:
        print("AirTraffic - Network Monitoring Tool")
        print("\nUsage:")
        print("  airtraffic install     Install and start background service")
        print("  airtraffic uninstall   Stop and uninstall background service")
        print("  airtraffic start       Start the background daemon")
        print("  airtraffic stop        Stop the background daemon")
        print("  airtraffic status      Check daemon status")
        print("  airtraffic today       Show today's network usage")
        print("  airtraffic week        Show this week's network usage")
        print("  airtraffic month       Show this month's network usage")
        print("  airtraffic live        Show live network statistics")
        print("\nOptions:")
        print("  -h, --help             Show this help message")
        sys.exit(0)
    
    command = sys.argv[1].lower()
    
    if command in ['-h', '--help', 'help']:
        print("AirTraffic - Network Monitoring Tool")
        print("\nCommands:")
        print("  install     Install as system service (auto-start on boot)")
        print("  uninstall   Remove system service and stop monitoring")
        print("  start       Start the background daemon manually")
        print("  stop        Stop the background daemon")
        print("  status      Check if daemon is running")
        print("  today       Show network usage since midnight")
        print("  week        Show network usage since Monday midnight")
        print("  month       Show network usage since 1st of month")
        print("  live        Show real-time network statistics")
        print("\nThe daemon collects network data in the background.")
        print("Use 'today', 'week', or 'month' to view historical usage.")
        sys.exit(0)
    
    elif command == 'install':
        install_service()
    
    elif command == 'uninstall':
        uninstall_service()
    
    elif command == 'start':
        daemon = AirTrafficDaemon()
        daemon.start()
    
    elif command == 'stop':
        daemon = AirTrafficDaemon()
        daemon.stop()
    
    elif command == 'status':
        daemon = AirTrafficDaemon()
        daemon.status()
    
    elif command == 'today':
        show_today()
    
    elif command == 'week':
        show_week()
    
    elif command == 'month':
        show_month()
    
    elif command == 'live':
        live_monitor()
    
    else:
        print(f"Unknown command: {command}")
        print("Use 'airtraffic --help' for usage information.")
        sys.exit(1)


if __name__ == '__main__':
    main()
