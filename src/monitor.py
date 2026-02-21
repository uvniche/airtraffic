"""Network monitoring module for AirTraffic."""

import os
import platform
import psutil
import time
from collections import defaultdict
from typing import Dict, Tuple


class NetworkMonitor:
    """Monitor network usage per application."""
    
    def __init__(self):
        self.system = platform.system()
        self.last_stats = {}
        
    def _get_app_name(self, proc: psutil.Process) -> str:
        """Get application name from process.
        
        On macOS, tries to get the app bundle name.
        On Linux and Windows, uses the executable name.
        """
        try:
            if self.system == "Darwin":  # macOS
                # Try to get the app bundle name
                exe = proc.exe()
                if ".app/" in exe:
                    # Extract app name from path like /Applications/Safari.app/Contents/MacOS/Safari
                    app_path = exe.split(".app/")[0] + ".app"
                    app_name = os.path.basename(app_path).replace(".app", "")
                    return app_name
                else:
                    return proc.name()
            elif self.system == "Windows":
                # On Windows, try to get the executable name without .exe
                name = proc.name()
                if name.endswith('.exe'):
                    return name[:-4]
                return name
            else:  # Linux and others
                return proc.name()
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            return "Unknown"
    
    def _format_bytes(self, bytes_val: int) -> str:
        """Format bytes to human-readable format."""
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_val < 1024.0:
                return f"{bytes_val:.2f} {unit}"
            bytes_val /= 1024.0
        return f"{bytes_val:.2f} PB"
    
    def _format_rate(self, bytes_per_sec: float) -> str:
        """Format bytes per second to human-readable format."""
        for unit in ['B/s', 'KB/s', 'MB/s', 'GB/s']:
            if bytes_per_sec < 1024.0:
                return f"{bytes_per_sec:.2f} {unit}"
            bytes_per_sec /= 1024.0
        return f"{bytes_per_sec:.2f} TB/s"
    
    def get_network_stats(self, interval: float = 0) -> Dict[str, Dict[str, any]]:
        """Get network statistics per application.
        
        Args:
            interval: Time interval for rate calculation (0 for instantaneous)
            
        Returns:
            Dictionary mapping app names to their network stats
        """
        app_stats = defaultdict(lambda: {"sent": 0, "recv": 0, "connections": 0})
        
        try:
            # Get all network connections
            try:
                connections = psutil.net_connections(kind='inet')
            except psutil.AccessDenied:
                # If we don't have permission, try without filtering
                connections = []
            
            connection_pids = defaultdict(int)
            
            for conn in connections:
                if conn.pid:
                    connection_pids[conn.pid] += 1
            
            # Iterate through all processes
            for proc in psutil.process_iter(['pid', 'name']):
                try:
                    pid = proc.info['pid']
                    
                    # Get app name
                    app_name = self._get_app_name(proc)
                    
                    # Count connections for this process
                    if pid in connection_pids:
                        app_stats[app_name]["connections"] += connection_pids[pid]
                    
                except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                    continue
            
            # Get system-wide network stats and try to attribute them
            # This is a simplified approach - we'll track changes over time
            net_io = psutil.net_io_counters(pernic=False)
            current_time = time.time()
            
            current_stats = {
                'bytes_sent': net_io.bytes_sent,
                'bytes_recv': net_io.bytes_recv,
                'time': current_time
            }
            
            # Calculate rates if we have previous stats
            if self.last_stats and interval > 0:
                time_delta = current_stats['time'] - self.last_stats['time']
                if time_delta > 0:
                    sent_rate = (current_stats['bytes_sent'] - self.last_stats['bytes_sent']) / time_delta
                    recv_rate = (current_stats['bytes_recv'] - self.last_stats['bytes_recv']) / time_delta
                    # Delta bytes (for recording total in this interval)
                    sent_delta = current_stats['bytes_sent'] - self.last_stats['bytes_sent']
                    recv_delta = current_stats['bytes_recv'] - self.last_stats['bytes_recv']

                    total_connections = sum(app["connections"] for app in app_stats.values())
                    if total_connections > 0:
                        for app_name, stats in app_stats.items():
                            if stats["connections"] > 0:
                                proportion = stats["connections"] / total_connections
                                app_stats[app_name]["sent"] = sent_rate * proportion
                                app_stats[app_name]["recv"] = recv_rate * proportion
                    else:
                        # No per-app connections (e.g. running without root): record system total
                        app_stats["System"]["sent"] = sent_delta
                        app_stats["System"]["recv"] = recv_delta
            
            self.last_stats = current_stats
            
        except Exception as e:
            # Silently handle errors - they'll be shown in the display
            pass
        
        return dict(app_stats)
    
    def format_stats(self, stats: Dict[str, Dict[str, any]]) -> list:
        """Format network statistics for display.
        
        Args:
            stats: Dictionary of app statistics
            
        Returns:
            List of formatted strings for display
        """
        if not stats:
            return ["No active network connections found."]
        
        # Sort by total traffic (sent + recv)
        sorted_apps = sorted(
            stats.items(),
            key=lambda x: x[1]["sent"] + x[1]["recv"],
            reverse=True
        )
        
        lines = []
        lines.append(f"{'Application':<30} {'Upload':<15} {'Download':<15} {'Connections':<12}")
        lines.append("-" * 72)
        
        for app_name, app_stats in sorted_apps:
            if app_stats["connections"] > 0 or app_stats["sent"] > 0 or app_stats["recv"] > 0:
                upload = self._format_rate(app_stats["sent"])
                download = self._format_rate(app_stats["recv"])
                connections = app_stats["connections"]
                
                lines.append(f"{app_name:<30} {upload:<15} {download:<15} {connections:<12}")
        
        return lines
