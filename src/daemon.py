"""Daemon service for continuous network monitoring."""

import time
import signal
import sys
import os
import psutil
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
        
        # Set up signal handlers (Windows supports SIGINT, but not SIGTERM)
        if hasattr(signal, 'SIGTERM'):
            signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)
    
    def _signal_handler(self, signum, frame):
        """Handle shutdown signals."""
        print(f"\nReceived signal {signum}, shutting down gracefully...")
        self.running = False
    
    def _get_system_pid_file(self) -> str | None:
        """Return system-wide PID file path (Unix, when running as root). None on Windows."""
        import platform
        if platform.system() != 'Windows':
            return '/var/run/airtraffic/daemon.pid'
        return None

    def _get_pid_file(self) -> str:
        """Get path to PID file for current process (where we write our PID)."""
        import platform

        if platform.system() == 'Windows':
            pid_dir = os.path.join(os.getenv('APPDATA'), 'AirTraffic')
        else:
            # When running as root, use system-wide path so status/stop work for all users
            if os.geteuid() == 0:
                pid_dir = '/var/run/airtraffic'
            else:
                pid_dir = os.path.expanduser('~/.airtraffic')

        os.makedirs(pid_dir, exist_ok=True)
        if pid_dir == '/var/run/airtraffic':
            try:
                os.chmod(pid_dir, 0o755)
            except OSError:
                pass
        return os.path.join(pid_dir, 'daemon.pid')

    def _pid_file_candidates(self) -> list[str]:
        """Return list of PID file paths to check (system first, then user)."""
        import platform
        if platform.system() == 'Windows':
            return [self._get_pid_file()]
        candidates = []
        system_path = self._get_system_pid_file()
        if system_path:
            candidates.append(system_path)
        candidates.append(os.path.expanduser('~/.airtraffic/daemon.pid'))
        return candidates

    def _remove_pid_file(self, path: str) -> None:
        """Remove a specific PID file if it exists."""
        if os.path.exists(path):
            try:
                os.remove(path)
            except OSError:
                pass

    def _write_pid(self):
        """Write PID to file."""
        pid_file = self._get_pid_file()
        with open(pid_file, 'w') as f:
            f.write(str(os.getpid()))
        # When running as root, make readable so non-root 'airtraffic status' can find the daemon
        if hasattr(os, 'geteuid') and os.geteuid() == 0:
            try:
                os.chmod(pid_file, 0o644)
            except OSError:
                pass

    def _remove_pid(self):
        """Remove PID file(s) for this daemon (current process location)."""
        pid_file = self._get_pid_file()
        self._remove_pid_file(pid_file)
    
    def is_running(self) -> bool:
        """Check if daemon is already running."""
        return self.get_pid() is not None

    def get_pid(self):
        """Return daemon PID if running, else None. Checks system PID file first (e.g. when run with sudo)."""
        import platform
        for pid_file in self._pid_file_candidates():
            if not os.path.exists(pid_file):
                continue
            try:
                with open(pid_file, 'r') as f:
                    pid = int(f.read().strip())
            except (OSError, ValueError):
                self._remove_pid_file(pid_file)
                continue

            # Check if process exists
            try:
                if platform.system() == 'Windows':
                    import subprocess
                    result = subprocess.run(['tasklist', '/FI', f'PID eq {pid}'],
                                          capture_output=True, text=True)
                    if str(pid) in result.stdout:
                        return pid
                else:
                    os.kill(pid, 0)
                    return pid
            except (OSError, psutil.AccessDenied):
                pass
            self._remove_pid_file(pid_file)
        return None
    
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
    
    def stop(self, quiet: bool = False):
        """Stop the daemon."""
        import platform
        pid = self.get_pid()
        if pid is None:
            if not quiet:
                print("AirTraffic daemon is not running.")
            return

        try:
            if not quiet:
                print(f"Stopping AirTraffic daemon (PID: {pid})...")

            if platform.system() == 'Windows':
                import subprocess
                subprocess.run(['taskkill', '/PID', str(pid), '/F'],
                             capture_output=True, check=False)
            else:
                os.kill(pid, signal.SIGTERM)

            # Wait for process to stop
            for _ in range(10):
                if platform.system() == 'Windows':
                    import subprocess
                    result = subprocess.run(['tasklist', '/FI', f'PID eq {pid}'],
                                          capture_output=True, text=True)
                    if str(pid) not in result.stdout:
                        break
                else:
                    try:
                        os.kill(pid, 0)
                    except OSError:
                        break
                time.sleep(0.5)

            # Remove both possible PID files so next start is clean
            for path in self._pid_file_candidates():
                self._remove_pid_file(path)
            if not quiet:
                print("Daemon stopped.")

        except (OSError, ValueError) as e:
            if not quiet:
                print(f"Error stopping daemon: {e}")
            for path in self._pid_file_candidates():
                self._remove_pid_file(path)
    


def run_daemon():
    """Run the daemon in foreground mode."""
    daemon = AirTrafficDaemon(interval=60)
    daemon.start()


if __name__ == '__main__':
    run_daemon()
