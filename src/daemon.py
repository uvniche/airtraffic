"""Daemon service for continuous network monitoring."""

import time
import signal
import sys
import os
from datetime import datetime
from airtraffic.monitor import NetworkMonitor
from airtraffic.database import NetworkDatabase


class AirTrafficDaemon:
    """Background daemon for continuous network monitoring."""
    
    def __init__(self, interval: int = 60):
        """Initialize daemon.
        
        Args:
            interval: Collection interval in seconds (default: 60)
        """
        self.interval = interval
        self.monitor = NetworkMonitor()
        self.database = NetworkDatabase()
        self.running = False
        
        # Set up signal handlers
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)
    
    def _signal_handler(self, signum, frame):
        """Handle shutdown signals."""
        print(f"\nReceived signal {signum}, shutting down gracefully...")
        self.running = False
    
    def _get_pid_file(self) -> str:
        """Get path to PID file."""
        if os.name == 'posix':
            pid_dir = os.path.expanduser('~/.airtraffic')
        else:
            pid_dir = os.path.expanduser('~/airtraffic')
        
        os.makedirs(pid_dir, exist_ok=True)
        return os.path.join(pid_dir, 'daemon.pid')
    
    def _write_pid(self):
        """Write PID to file."""
        pid_file = self._get_pid_file()
        with open(pid_file, 'w') as f:
            f.write(str(os.getpid()))
    
    def _remove_pid(self):
        """Remove PID file."""
        pid_file = self._get_pid_file()
        if os.path.exists(pid_file):
            os.remove(pid_file)
    
    def is_running(self) -> bool:
        """Check if daemon is already running."""
        pid_file = self._get_pid_file()
        
        if not os.path.exists(pid_file):
            return False
        
        try:
            with open(pid_file, 'r') as f:
                pid = int(f.read().strip())
            
            # Check if process exists
            os.kill(pid, 0)
            return True
        except (OSError, ValueError):
            # Process doesn't exist or PID file is invalid
            self._remove_pid()
            return False
    
    def start(self):
        """Start the daemon."""
        if self.is_running():
            print("AirTraffic daemon is already running.")
            return
        
        print("Starting AirTraffic daemon...")
        self._write_pid()
        self.running = True
        
        # Initial collection
        self.monitor.get_network_stats()
        time.sleep(1)
        
        print(f"Daemon started. Collecting data every {self.interval} seconds.")
        print(f"Database: {self.database.db_path}")
        
        try:
            while self.running:
                # Collect network statistics
                stats = self.monitor.get_network_stats(interval=self.interval)
                
                # Store in database
                if stats:
                    self.database.record_stats(stats)
                
                # Sleep until next collection
                time.sleep(self.interval)
                
        except Exception as e:
            print(f"Error in daemon: {e}")
        finally:
            self._remove_pid()
            print("Daemon stopped.")
    
    def stop(self):
        """Stop the daemon."""
        pid_file = self._get_pid_file()
        
        if not os.path.exists(pid_file):
            print("AirTraffic daemon is not running.")
            return
        
        try:
            with open(pid_file, 'r') as f:
                pid = int(f.read().strip())
            
            print(f"Stopping AirTraffic daemon (PID: {pid})...")
            os.kill(pid, signal.SIGTERM)
            
            # Wait for process to stop
            for _ in range(10):
                try:
                    os.kill(pid, 0)
                    time.sleep(0.5)
                except OSError:
                    break
            
            self._remove_pid()
            print("Daemon stopped.")
            
        except (OSError, ValueError) as e:
            print(f"Error stopping daemon: {e}")
            self._remove_pid()
    
    def status(self):
        """Check daemon status."""
        if self.is_running():
            pid_file = self._get_pid_file()
            with open(pid_file, 'r') as f:
                pid = int(f.read().strip())
            print(f"AirTraffic daemon is running (PID: {pid})")
            print(f"Database: {self.database.db_path}")
            print(f"Database size: {self.database.get_database_size() / 1024:.2f} KB")
        else:
            print("AirTraffic daemon is not running.")


def run_daemon():
    """Run the daemon in foreground mode."""
    daemon = AirTrafficDaemon(interval=60)
    daemon.start()


if __name__ == '__main__':
    run_daemon()
