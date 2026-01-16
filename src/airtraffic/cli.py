"""CLI interface for AirTraffic."""

import sys
import time
import os
from airtraffic.monitor import NetworkMonitor


def clear_screen():
    """Clear the terminal screen."""
    os.system('clear' if os.name != 'nt' else 'cls')


def live_monitor(interval: int = 2):
    """Display live network statistics.
    
    Args:
        interval: Update interval in seconds (default: 2)
    """
    monitor = NetworkMonitor()
    
    print("AirTraffic - Live Network Monitor")
    print("Press Ctrl+C to exit\n")
    
    # Check if running with sufficient privileges
    if os.geteuid() != 0:
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


def main():
    """Main entry point for the CLI."""
    if len(sys.argv) < 2:
        print("AirTraffic - Network Monitoring Tool")
        print("\nUsage:")
        print("  airtraffic live    Show live network statistics")
        print("\nOptions:")
        print("  -h, --help         Show this help message")
        sys.exit(0)
    
    command = sys.argv[1].lower()
    
    if command in ['-h', '--help', 'help']:
        print("AirTraffic - Network Monitoring Tool")
        print("\nUsage:")
        print("  airtraffic live    Show live network statistics")
        print("\nThe live command displays network usage per application,")
        print("updating every 2 seconds.")
        print("\nNote: Root/sudo privileges may be required for full functionality.")
        sys.exit(0)
    
    elif command == 'live':
        live_monitor()
    
    else:
        print(f"Unknown command: {command}")
        print("Use 'airtraffic --help' for usage information.")
        sys.exit(1)


if __name__ == '__main__':
    main()
