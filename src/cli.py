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
    """Completely uninstall AirTraffic - service, data, and package."""
    import shutil
    import subprocess
    
    print("Uninstalling AirTraffic...")
    print()
    
    system = platform.system()
    
    # Step 1: Stop and remove service
    print("1. Stopping and removing service...")
    daemon = AirTrafficDaemon()
    daemon.stop()
    
    if system == "Darwin":  # macOS
        uninstall_launchd_service()
    elif system == "Linux":
        uninstall_systemd_service()
    else:
        print(f"   Service uninstallation not supported on {system}")
    
    # Step 2: Remove all data
    print("\n2. Removing all data...")
    data_dir = os.path.expanduser('~/.airtraffic')
    if os.path.exists(data_dir):
        shutil.rmtree(data_dir)
        print(f"   ✓ Removed {data_dir}")
    else:
        print(f"   No data directory found")
    
    # Step 3: Uninstall package
    print("\n3. Uninstalling package...")
    try:
        subprocess.run([sys.executable, '-m', 'pip', 'uninstall', '-y', 'airtraffic'], 
                      check=True, capture_output=True)
        print("   ✓ Package uninstalled")
    except subprocess.CalledProcessError:
        print("   ✓ Package already uninstalled or not found")
    
    print("\n" + "=" * 50)
    print("✓ AirTraffic completely removed!")
    print("=" * 50)


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
    # Get the actual user (not root) for LaunchAgents
    actual_user = os.getenv('SUDO_USER') or os.getenv('USER')
    user_home = os.path.expanduser(f"~{actual_user}")
    
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
    <string>{user_home}/.airtraffic/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>{user_home}/.airtraffic/daemon.error.log</string>
</dict>
</plist>
"""
    
    plist_path = f"{user_home}/Library/LaunchAgents/com.airtraffic.daemon.plist"
    os.makedirs(os.path.dirname(plist_path), exist_ok=True)
    
    with open(plist_path, 'w') as f:
        f.write(plist_content)
    
    print("Installing launchd service...")
    
    # Use bootstrap instead of load (modern approach), suppress all output
    domain = f"gui/{os.getuid()}" if os.getenv('SUDO_USER') else f"gui/{os.getuid()}"
    os.system(f"launchctl bootstrap {domain} {plist_path} >/dev/null 2>&1 || launchctl load {plist_path} >/dev/null 2>&1")
    
    # Give it a moment to start
    time.sleep(2)
    
    print("✓ Service installed and started!")
    print("  The daemon is now running and will start automatically on boot.")


def uninstall_launchd_service():
    """Uninstall launchd service on macOS."""
    actual_user = os.getenv('SUDO_USER') or os.getenv('USER')
    user_home = os.path.expanduser(f"~{actual_user}")
    plist_path = f"{user_home}/Library/LaunchAgents/com.airtraffic.daemon.plist"
    
    print("Uninstalling launchd service...")
    
    # Try both bootstrap and unload methods
    domain = f"gui/{os.getuid()}"
    os.system(f"launchctl bootout {domain} {plist_path} 2>/dev/null || launchctl unload {plist_path} 2>/dev/null")
    
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
        print("  today       Show network usage since midnight")
        print("  week        Show network usage since Monday midnight")
        print("  month       Show network usage since 1st of month")
        print("  live        Show real-time network statistics")
        print("\nThe daemon runs automatically after installation.")
        print("Use 'today', 'week', or 'month' to view historical usage.")
        sys.exit(0)
    
    elif command == 'install':
        install_service()
    
    elif command == 'uninstall':
        uninstall_service()
    
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
