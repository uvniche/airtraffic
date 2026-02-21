"""CLI interface for AirTraffic."""

import sys
import time
import os
import platform
from datetime import datetime, timedelta
from airtraffic.monitor import NetworkMonitor
from airtraffic.database import NetworkDatabase
from airtraffic.daemon import AirTrafficDaemon


def clear_screen():
    """Clear the terminal screen."""
    os.system('clear' if os.name != 'nt' else 'cls')


def check_elevated_privileges() -> bool:
    """Check if running with elevated privileges.
    
    Returns:
        True if running with sudo/administrator privileges
    """
    system = platform.system()
    
    if system == "Windows":
        try:
            import ctypes
            return ctypes.windll.shell32.IsUserAnAdmin() != 0
        except:
            return False
    else:  # Unix-like (macOS, Linux)
        return os.geteuid() == 0


def require_elevated_privileges(command: str):
    """Check for elevated privileges and exit with message if not available.
    
    Args:
        command: The command being executed (for error message)
    """
    if not check_elevated_privileges():
        system = platform.system()
        
        print("=" * 70)
        print("ERROR: Elevated Privileges Required")
        print("=" * 70)
        print()
        
        if system == "Windows":
            print("This command requires Administrator privileges.")
            print()
            print("Please run this command as Administrator:")
            print(f"  1. Right-click on Command Prompt or PowerShell")
            print(f"  2. Select 'Run as administrator'")
            print(f"  3. Run: airtraffic {command}")
        else:  # Unix-like (macOS, Linux)
            print("This command requires root privileges.")
            print()
            print("Please run this command with sudo:")
            print(f"  sudo airtraffic {command}")
        
        print()
        sys.exit(1)


def format_bytes(bytes_val: int) -> str:
    """Format bytes to human-readable format."""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_val < 1024.0:
            return f"{bytes_val:.2f} {unit}"
        bytes_val /= 1024.0
    return f"{bytes_val:.2f} PB"


def format_uptime(seconds: float) -> str:
    """Format seconds as human-readable uptime (e.g. '2 hours 15 minutes')."""
    if seconds < 60:
        return f"{int(seconds)} second{'s' if int(seconds) != 1 else ''}"
    minutes = int(seconds // 60)
    if minutes < 60:
        return f"{minutes} minute{'s' if minutes != 1 else ''}"
    hours = minutes // 60
    minutes = minutes % 60
    if hours < 24:
        parts = [f"{hours} hour{'s' if hours != 1 else ''}"]
        if minutes:
            parts.append(f"{minutes} minute{'s' if minutes != 1 else ''}")
        return " ".join(parts)
    days = hours // 24
    hours = hours % 24
    parts = [f"{days} day{'s' if days != 1 else ''}"]
    if hours:
        parts.append(f"{hours} hour{'s' if hours != 1 else ''}")
    if minutes:
        parts.append(f"{minutes} minute{'s' if minutes != 1 else ''}")
    return " ".join(parts)


def show_status():
    """Show whether the background daemon is running and for how long."""
    import psutil
    daemon = AirTrafficDaemon()
    pid = daemon.get_pid()
    if pid is None:
        print("AirTraffic is not running.")
        return
    try:
        proc = psutil.Process(pid)
        start_ts = proc.create_time()
        start_dt = datetime.fromtimestamp(start_ts)
        uptime_seconds = time.time() - start_ts
        uptime_str = format_uptime(uptime_seconds)
        print(f"AirTraffic is running.")
        print(f"Started at {start_dt.strftime('%Y-%m-%d %H:%M:%S')} ({uptime_str} ago).")
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        print("AirTraffic is not running.")


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
        if AirTrafficDaemon().get_pid() is not None:
            print("The app is running; data will appear after it has been collecting for a while.")
        else:
            print("Run 'airtraffic install' to install and start the app.")
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


def parse_since_datetime(since_arg: str) -> datetime:
    """Parse the 'since' argument to a datetime object.
    
    Args:
        since_arg: The time specification (e.g., 'today', 'month', or 'dd:mm:yyyy hh:mm:ss')
    
    Returns:
        datetime object representing the start time
    
    Raises:
        ValueError: If the format is invalid
    """
    since_arg = since_arg.lower().strip()
    
    if since_arg == 'today':
        # Today at 12:00 AM
        return datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    
    elif since_arg == 'month':
        # First day of this month at 12:00 AM
        return datetime.now().replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    
    else:
        # Try to parse as "dd:mm:yyyy hh:mm:ss"
        try:
            return datetime.strptime(since_arg, "%d:%m:%Y %H:%M:%S")
        except ValueError:
            raise ValueError(
                f"Invalid date format: '{since_arg}'\n"
                "Use one of:\n"
                "  - 'today' (since today 12:00 AM)\n"
                "  - 'month' (since first of month 12:00 AM)\n"
                "  - 'dd:mm:yyyy hh:mm:ss' (custom date/time)"
            )


def show_since(since_arg: str):
    """Show network statistics since a specified time.
    
    Args:
        since_arg: Time specification string
    """
    try:
        start_time = parse_since_datetime(since_arg)
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)
    
    db = NetworkDatabase()
    stats = db.get_stats_since(start_time)
    
    # Format the period description
    now = datetime.now()
    duration = now - start_time
    
    if duration.days > 0:
        duration_str = f"{duration.days} day{'s' if duration.days != 1 else ''}"
    elif duration.seconds >= 3600:
        hours = duration.seconds // 3600
        duration_str = f"{hours} hour{'s' if hours != 1 else ''}"
    elif duration.seconds >= 60:
        minutes = duration.seconds // 60
        duration_str = f"{minutes} minute{'s' if minutes != 1 else ''}"
    else:
        duration_str = f"{duration.seconds} second{'s' if duration.seconds != 1 else ''}"
    
    start_str = start_time.strftime("%A, %B %d, %Y at %I:%M:%S %p")
    period = f"Since {start_str} ({duration_str} ago)"
    
    display_historical_stats(stats, "Network Usage", period)


def live_monitor(interval: int = 2):
    """Display live network statistics.
    
    Args:
        interval: Update interval in seconds (default: 2)
    """
    # Check if running with sufficient privileges
    if not check_elevated_privileges():
        system = platform.system()
        
        print("=" * 70)
        print("WARNING: Elevated Privileges Required")
        print("=" * 70)
        print()
        print("The live monitor requires elevated privileges to see network")
        print("connections and track per-application usage.")
        print()
        
        if system == "Windows":
            print("Please run this command as Administrator:")
            print("  1. Right-click on Command Prompt or PowerShell")
            print("  2. Select 'Run as administrator'")
            print("  3. Run: airtraffic live")
        else:  # Unix-like (macOS, Linux)
            print("Please run this command with sudo:")
            print("  sudo airtraffic live")
        
        print()
        print("Continuing anyway (limited functionality)...")
        print()
        time.sleep(2)
    
    monitor = NetworkMonitor()
    
    print("AirTraffic - CLI Network Tool")
    print("Press Ctrl+C to exit\n")
    
    try:
        # Initial stats collection
        monitor.get_network_stats()
        time.sleep(1)  # Wait a bit for initial measurement
        
        while True:
            clear_screen()
            
            print("=" * 72)
            print("AirTraffic - CLI Network Tool")
            print("=" * 72)
            print(f"Last updated: {time.strftime('%Y-%m-%d %H:%M:%S')}")
            
            # Show privilege warning in header if not elevated
            if not check_elevated_privileges():
                print("[WARNING] Limited mode - run with sudo for full stats")
            
            print()
            
            # Get and display stats
            stats = monitor.get_network_stats(interval=interval)
            lines = monitor.format_stats(stats)
            
            for line in lines:
                print(line)
            
            print()
            print("=" * 72)
            print("Press Ctrl+C to exit")
            
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
    elif system == "Windows":
        install_windows_service()
    else:
        print(f"Service installation not supported on {system}")


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
    elif system == "Windows":
        uninstall_windows_service()
    else:
        print(f"   Service uninstallation not supported on {system}")
    
    # Step 2: Remove all data
    print("\n2. Removing all data...")
    if system == "Windows":
        data_dir = os.path.join(os.getenv('APPDATA'), 'AirTraffic')
    else:
        data_dir = os.path.expanduser('~/.airtraffic')
    
    if os.path.exists(data_dir):
        shutil.rmtree(data_dir)
        print(f"   Removed {data_dir}")
    else:
        print(f"   No data directory found")
    
    # Step 3: Uninstall package
    print("\n3. Uninstalling package...")
    try:
        subprocess.run([sys.executable, '-m', 'pip', 'uninstall', '-y', 'airtraffic'], 
                      check=True, capture_output=True)
        print("   Package uninstalled")
    except subprocess.CalledProcessError:
        print("   Package already uninstalled or not found")
    
    print("\n" + "=" * 50)
    print("AirTraffic completely removed!")
    print("=" * 50)


def install_systemd_service():
    """Install systemd service on Linux."""
    service_content = f"""[Unit]
Description=AirTraffic - CLI Network Tool
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
    print("Service installed and started!")
    print("The daemon will now start automatically on boot.")


def uninstall_systemd_service():
    """Uninstall systemd service on Linux."""
    print("Uninstalling systemd service...")
    os.system("systemctl --user stop airtraffic.service")
    os.system("systemctl --user disable airtraffic.service")
    
    service_path = os.path.expanduser("~/.config/systemd/user/airtraffic.service")
    if os.path.exists(service_path):
        os.remove(service_path)
    
    os.system("systemctl --user daemon-reload")
    print("Service uninstalled!")


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
    
    # If file exists and is owned by root, use sudo to remove it
    if os.path.exists(plist_path):
        try:
            # Try to write normally first
            with open(plist_path, 'w') as f:
                f.write(plist_content)
        except PermissionError:
            # File is owned by root, need to use sudo to remove it
            print("Existing service file requires elevated permissions to update...")
            os.system(f"sudo rm -f {plist_path}")
            with open(plist_path, 'w') as f:
                f.write(plist_content)
    else:
        with open(plist_path, 'w') as f:
            f.write(plist_content)
    
    print("Installing AirTraffic...")
    
    # Use bootstrap instead of load (modern approach), suppress all output
    domain = f"gui/{os.getuid()}" if os.getenv('SUDO_USER') else f"gui/{os.getuid()}"
    os.system(f"launchctl bootstrap {domain} {plist_path} >/dev/null 2>&1 || launchctl load {plist_path} >/dev/null 2>&1")
    
    # Give it a moment to start
    time.sleep(2)
    
    print("AirTraffic installed.")


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
    
    print("Service uninstalled!")


def install_windows_service():
    """Install Windows Task Scheduler service."""
    import subprocess
    
    print("Installing Windows Task Scheduler service...")
    
    # Get the Python executable and script path
    python_exe = sys.executable
    script_path = os.path.join(os.path.dirname(__file__), 'daemon.py')
    
    # Create a batch file to run the daemon
    appdata = os.getenv('APPDATA')
    airtraffic_dir = os.path.join(appdata, 'AirTraffic')
    os.makedirs(airtraffic_dir, exist_ok=True)
    
    batch_file = os.path.join(airtraffic_dir, 'run_daemon.bat')
    with open(batch_file, 'w') as f:
        f.write(f'@echo off\n')
        f.write(f'"{python_exe}" -m airtraffic.daemon\n')
    
    # Create a VBS file to run the batch file hidden (no console window)
    vbs_file = os.path.join(airtraffic_dir, 'run_daemon.vbs')
    with open(vbs_file, 'w') as f:
        f.write(f'Set WshShell = CreateObject("WScript.Shell")\n')
        f.write(f'WshShell.Run """"{batch_file}"""", 0, False\n')
    
    # Create scheduled task using schtasks
    task_name = "AirTrafficDaemon"
    
    try:
        # Delete existing task if it exists
        subprocess.run(['schtasks', '/Delete', '/TN', task_name, '/F'], 
                      capture_output=True, check=False)
        
        # Create new task that runs at startup and stays running
        subprocess.run([
            'schtasks', '/Create',
            '/TN', task_name,
            '/TR', f'wscript.exe "{vbs_file}"',
            '/SC', 'ONLOGON',
            '/RL', 'HIGHEST',
            '/F'
        ], check=True, capture_output=True)
        
        # Start the task immediately
        subprocess.run(['schtasks', '/Run', '/TN', task_name], 
                      check=True, capture_output=True)
        
        # Give it a moment to start
        time.sleep(2)
        
        print("Service installed and started!")
        print("The daemon is now running and will start automatically on login.")
        print(f"Data directory: {airtraffic_dir}")
        
    except subprocess.CalledProcessError as e:
        print(f"[FAILED] Failed to install service: {e}")
        print("  You may need to run this command as Administrator.")
        print("  Run 'airtraffic install' as Administrator to install and start the app.")


def uninstall_windows_service():
    """Uninstall Windows Task Scheduler service."""
    import subprocess
    
    print("Uninstalling Windows Task Scheduler service...")
    
    task_name = "AirTrafficDaemon"
    
    try:
        # Stop and delete the scheduled task
        subprocess.run(['schtasks', '/End', '/TN', task_name], 
                      capture_output=True, check=False)
        subprocess.run(['schtasks', '/Delete', '/TN', task_name, '/F'], 
                      capture_output=True, check=False)
        
        print("Service uninstalled!")
        
    except Exception as e:
        print(f"Note: {e}")


def main():
    """Main entry point for the CLI."""
    if len(sys.argv) < 2:
        print("AirTraffic - CLI Network Tool")
        print("\nUsage:")
        print("  airtraffic install            Install and start app")
        print("  airtraffic uninstall          Stop and uninstall app")
        print("  airtraffic status             Show if app is running")
        print("  airtraffic since <timespec>   Show network usage since specified time")
        print("  airtraffic live               Show live network statistics")
        print("\nTime specifications for 'since':")
        print("  today                         Since today at 12:00 AM")
        print("  month                         Since first of this month at 12:00 AM")
        print("  dd:mm:yyyy hh:mm:ss          Custom date and time")
        print("\nExamples:")
        print("  airtraffic since today")
        print("  airtraffic since month")
        print("\nOptions:")
        print("  -h, --help                    Show this help message")
        sys.exit(0)
    
    command = sys.argv[1].lower()
    
    if command in ['-h', '--help', 'help']:
        print("AirTraffic - CLI Network Tool")
        print("\nCommands:")
        print("  install              Install app (auto-start on boot)")
        print("  uninstall            Remove app and stop monitoring")
        print("  status               Show if app is running (and uptime)")
        print("  since <timespec>     Show network usage since specified time")
        print("  live                 Show real-time network statistics")
        print("\nTime specifications for 'since':")
        print("  today                Since today at 12:00 AM")
        print("  month                Since first of this month at 12:00 AM")
        print("  dd:mm:yyyy hh:mm:ss  Custom date and time (e.g., '17:01:2026 14:30:00')")
        print("\nExamples:")
        print("  airtraffic since today")
        print("  airtraffic since month")
        print("\nThe app runs automatically after installation.")
        print("Use 'since' to view historical usage from any point in time.")
        sys.exit(0)
    
    elif command == 'install':
        install_service()

    elif command == 'uninstall':
        uninstall_service()

    elif command == 'status':
        show_status()

    elif command == 'since':
        if len(sys.argv) < 3:
            print("Error: 'since' command requires a time specification.")
            print("\nUsage: airtraffic since <timespec>")
            print("\nTime specifications:")
            print("  today              Since today at 12:00 AM")
            print("  month              Since first of this month at 12:00 AM")
            print("  dd:mm:yyyy hh:mm:ss   Custom date and time")
            print("\nExamples:")
            print("  airtraffic since today")
            print("  airtraffic since month")
            print("  airtraffic since '17:01:2026 14:30:00'")
            sys.exit(1)
        
        # Join remaining arguments in case the datetime has spaces
        since_arg = ' '.join(sys.argv[2:])
        show_since(since_arg)
    
    elif command == 'live':
        live_monitor()
    
    else:
        print(f"Unknown command: {command}")
        print("Use 'airtraffic --help' for usage information.")
        sys.exit(1)


if __name__ == '__main__':
    main()
