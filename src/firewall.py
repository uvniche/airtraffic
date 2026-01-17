"""Firewall management module for blocking/unblocking network access."""

import os
import platform
import subprocess
import json
from typing import List, Dict
import psutil


class FirewallManager:
    """Manage firewall rules to block/unblock applications."""
    
    def __init__(self):
        self.system = platform.system()
        self.blocked_apps_file = self._get_blocked_apps_file()
    
    def _get_blocked_apps_file(self) -> str:
        """Get the path to the blocked apps tracking file."""
        if self.system == 'Windows':
            data_dir = os.path.join(os.getenv('APPDATA'), 'AirTraffic')
        else:
            data_dir = os.path.expanduser('~/.airtraffic')
        
        os.makedirs(data_dir, exist_ok=True)
        return os.path.join(data_dir, 'blocked_apps.json')
    
    def _load_blocked_apps(self) -> Dict[str, str]:
        """Load the list of blocked applications from file.
        
        Returns:
            Dictionary mapping app names to their executable paths
        """
        if os.path.exists(self.blocked_apps_file):
            try:
                with open(self.blocked_apps_file, 'r') as f:
                    return json.load(f)
            except:
                return {}
        return {}
    
    def _save_blocked_apps(self, blocked_apps: Dict[str, str]):
        """Save the list of blocked applications to file.
        
        Args:
            blocked_apps: Dictionary mapping app names to their executable paths
        """
        with open(self.blocked_apps_file, 'w') as f:
            json.dump(blocked_apps, f, indent=2)
    
    def _find_process_path(self, process_name: str) -> str:
        """Find the executable path for a running process.
        
        Args:
            process_name: Name of the process to find
            
        Returns:
            Full path to the executable
            
        Raises:
            ValueError: If process not found or multiple processes found
        """
        matches = []
        process_name_lower = process_name.lower()
        
        for proc in psutil.process_iter(['name', 'exe']):
            try:
                proc_name = proc.info['name']
                if proc_name and process_name_lower in proc_name.lower():
                    exe_path = proc.info['exe']
                    if exe_path and exe_path not in matches:
                        matches.append(exe_path)
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
        
        if not matches:
            raise ValueError(f"Process '{process_name}' not found. Make sure it's running.")
        
        if len(matches) > 1:
            raise ValueError(
                f"Multiple processes matching '{process_name}' found:\n" + 
                "\n".join(f"  - {m}" for m in matches) +
                "\n\nPlease be more specific or provide the full path."
            )
        
        return matches[0]
    
    def block_app(self, app_identifier: str):
        """Block an application from accessing the network.
        
        Args:
            app_identifier: Process name or full path to executable
        """
        # Check if we have root/admin privileges
        if self.system != 'Windows' and os.geteuid() != 0:
            raise PermissionError("Root privileges required. Run with: sudo airtraffic block <process>")
        
        # Determine if it's a path or process name
        if os.path.exists(app_identifier):
            exe_path = os.path.abspath(app_identifier)
            app_name = os.path.basename(exe_path)
        else:
            exe_path = self._find_process_path(app_identifier)
            app_name = app_identifier
        
        # Block based on platform
        if self.system == "Darwin":  # macOS
            self._block_macos(exe_path, app_name)
        elif self.system == "Linux":
            self._block_linux(exe_path, app_name)
        elif self.system == "Windows":
            self._block_windows(exe_path, app_name)
        else:
            raise NotImplementedError(f"Blocking not supported on {self.system}")
        
        # Save to tracking file
        blocked_apps = self._load_blocked_apps()
        blocked_apps[app_name] = exe_path
        self._save_blocked_apps(blocked_apps)
        
        print(f"✓ Blocked: {app_name}")
        print(f"  Path: {exe_path}")
    
    def unblock_app(self, app_identifier: str):
        """Unblock an application from accessing the network.
        
        Args:
            app_identifier: Process name or full path to executable
        """
        # Check if we have root/admin privileges
        if self.system != 'Windows' and os.geteuid() != 0:
            raise PermissionError("Root privileges required. Run with: sudo airtraffic unblock <process>")
        
        blocked_apps = self._load_blocked_apps()
        
        # Find the app in blocked list
        exe_path = None
        app_name = None
        
        if os.path.exists(app_identifier):
            exe_path = os.path.abspath(app_identifier)
            app_name = os.path.basename(exe_path)
        else:
            # Search in blocked apps
            for name, path in blocked_apps.items():
                if app_identifier.lower() in name.lower():
                    app_name = name
                    exe_path = path
                    break
        
        if not exe_path:
            raise ValueError(f"Application '{app_identifier}' is not blocked or not found.")
        
        # Unblock based on platform
        if self.system == "Darwin":  # macOS
            self._unblock_macos(exe_path, app_name)
        elif self.system == "Linux":
            self._unblock_linux(exe_path, app_name)
        elif self.system == "Windows":
            self._unblock_windows(exe_path, app_name)
        else:
            raise NotImplementedError(f"Unblocking not supported on {self.system}")
        
        # Remove from tracking file
        if app_name in blocked_apps:
            del blocked_apps[app_name]
            self._save_blocked_apps(blocked_apps)
        
        print(f"✓ Unblocked: {app_name}")
        print(f"  Path: {exe_path}")
    
    def list_blocked(self) -> List[Dict[str, str]]:
        """List all blocked applications.
        
        Returns:
            List of dictionaries with app info
        """
        blocked_apps = self._load_blocked_apps()
        return [{"name": name, "path": path} for name, path in blocked_apps.items()]
    
    def list_allowed(self) -> List[Dict[str, str]]:
        """List all allowed (not blocked) applications with active network connections.
        
        Returns:
            List of dictionaries with app info
        """
        blocked_apps = self._load_blocked_apps()
        blocked_paths = set(blocked_apps.values())
        
        allowed_apps = {}
        
        # Get all processes with network connections
        try:
            connections = psutil.net_connections(kind='inet')
            connection_pids = set(conn.pid for conn in connections if conn.pid)
            
            for proc in psutil.process_iter(['pid', 'name', 'exe']):
                try:
                    if proc.info['pid'] in connection_pids:
                        exe_path = proc.info['exe']
                        if exe_path and exe_path not in blocked_paths:
                            app_name = proc.info['name']
                            if app_name not in allowed_apps:
                                allowed_apps[app_name] = exe_path
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue
        except psutil.AccessDenied:
            # If we can't get connections, just list all running apps not blocked
            for proc in psutil.process_iter(['name', 'exe']):
                try:
                    exe_path = proc.info['exe']
                    if exe_path and exe_path not in blocked_paths:
                        app_name = proc.info['name']
                        if app_name not in allowed_apps:
                            allowed_apps[app_name] = exe_path
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue
        
        return [{"name": name, "path": path} for name, path in allowed_apps.items()]
    
    def block_all(self):
        """Block all currently running applications from accessing the network."""
        # Check if we have root/admin privileges
        if self.system != 'Windows' and os.geteuid() != 0:
            raise PermissionError("Root privileges required. Run with: sudo airtraffic block all")
        
        blocked_count = 0
        errors = []
        
        # Get all unique running processes
        processes = {}
        for proc in psutil.process_iter(['name', 'exe']):
            try:
                exe_path = proc.info['exe']
                app_name = proc.info['name']
                if exe_path and app_name:
                    processes[app_name] = exe_path
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
        
        print(f"Found {len(processes)} applications to block...")
        print()
        
        for app_name, exe_path in processes.items():
            try:
                # Block based on platform
                if self.system == "Darwin":  # macOS
                    self._block_macos(exe_path, app_name)
                elif self.system == "Linux":
                    self._block_linux(exe_path, app_name)
                elif self.system == "Windows":
                    self._block_windows(exe_path, app_name)
                
                blocked_count += 1
                print(f"✓ Blocked: {app_name}")
            except Exception as e:
                errors.append(f"✗ Failed to block {app_name}: {e}")
        
        # Save all to tracking file
        blocked_apps = self._load_blocked_apps()
        blocked_apps.update(processes)
        self._save_blocked_apps(blocked_apps)
        
        print()
        print("=" * 70)
        print(f"Blocked {blocked_count} application(s)")
        if errors:
            print(f"Failed {len(errors)} application(s)")
            print()
            for error in errors[:5]:  # Show first 5 errors
                print(error)
            if len(errors) > 5:
                print(f"... and {len(errors) - 5} more errors")
        print("=" * 70)
    
    def allow_all(self):
        """Allow all currently blocked applications to access the network."""
        # Check if we have root/admin privileges
        if self.system != 'Windows' and os.geteuid() != 0:
            raise PermissionError("Root privileges required. Run with: sudo airtraffic allow all")
        
        blocked_apps = self._load_blocked_apps()
        
        if not blocked_apps:
            print("No applications are currently blocked.")
            return
        
        allowed_count = 0
        errors = []
        
        print(f"Found {len(blocked_apps)} blocked application(s) to allow...")
        print()
        
        for app_name, exe_path in list(blocked_apps.items()):
            try:
                # Unblock based on platform
                if self.system == "Darwin":  # macOS
                    self._unblock_macos(exe_path, app_name)
                elif self.system == "Linux":
                    self._unblock_linux(exe_path, app_name)
                elif self.system == "Windows":
                    self._unblock_windows(exe_path, app_name)
                
                allowed_count += 1
                print(f"✓ Allowed: {app_name}")
            except Exception as e:
                errors.append(f"✗ Failed to allow {app_name}: {e}")
        
        # Clear tracking file
        self._save_blocked_apps({})
        
        print()
        print("=" * 70)
        print(f"Allowed {allowed_count} application(s)")
        if errors:
            print(f"Failed {len(errors)} application(s)")
            print()
            for error in errors[:5]:  # Show first 5 errors
                print(error)
            if len(errors) > 5:
                print(f"... and {len(errors) - 5} more errors")
        print("=" * 70)
    
    def _block_macos(self, exe_path: str, app_name: str):
        """Block application on macOS using launchd to prevent execution.
        
        macOS doesn't provide simple per-app network filtering without system extensions.
        This implementation prevents the app from running entirely.
        """
        try:
            # Kill all running instances
            killed_count = 0
            for proc in psutil.process_iter(['exe', 'pid', 'name']):
                try:
                    if proc.info['exe'] == exe_path:
                        proc.kill()
                        killed_count += 1
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue
            
            if killed_count > 0:
                print(f"  Terminated {killed_count} running instance(s)")
            
            # Set file permissions to prevent execution
            try:
                import stat
                current_mode = os.stat(exe_path).st_mode
                # Remove execute permissions
                os.chmod(exe_path, current_mode & ~stat.S_IXUSR & ~stat.S_IXGRP & ~stat.S_IXOTH)
                print(f"  Removed execute permissions from {app_name}")
                print(f"  ✓ Application is now blocked")
            except (OSError, PermissionError) as e:
                print(f"  ⚠️  Could not remove execute permissions: {e}")
                print(f"  Process was killed but may restart")
            
        except Exception as e:
            raise RuntimeError(f"Failed to block app: {str(e)}")
    
    def _unblock_macos(self, exe_path: str, app_name: str):
        """Unblock application on macOS by restoring execute permissions."""
        try:
            # Restore execute permissions
            import stat
            current_mode = os.stat(exe_path).st_mode
            # Add back execute permissions
            os.chmod(exe_path, current_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            print(f"  Restored execute permissions")
            print(f"  ✓ Application is now allowed")
        except (OSError, PermissionError) as e:
            print(f"  ⚠️  Could not restore execute permissions: {e}")
            # Still remove from blocked list
        pass
    
    def _block_linux(self, exe_path: str, app_name: str):
        """Block application on Linux using file permissions (same as macOS)."""
        try:
            # Kill all running instances
            killed_count = 0
            for proc in psutil.process_iter(['exe', 'pid', 'name']):
                try:
                    if proc.info['exe'] == exe_path:
                        proc.kill()
                        killed_count += 1
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue
            
            if killed_count > 0:
                print(f"  Terminated {killed_count} running instance(s)")
            
            # Remove execute permissions
            import stat
            current_mode = os.stat(exe_path).st_mode
            os.chmod(exe_path, current_mode & ~stat.S_IXUSR & ~stat.S_IXGRP & ~stat.S_IXOTH)
            print(f"  Removed execute permissions from {app_name}")
            print(f"  ✓ Application is now blocked")
            
        except (OSError, PermissionError) as e:
            raise RuntimeError(f"Failed to block app: {str(e)}")
    
    def _unblock_linux(self, exe_path: str, app_name: str):
        """Unblock application on Linux by restoring execute permissions."""
        try:
            # Restore execute permissions
            import stat
            current_mode = os.stat(exe_path).st_mode
            os.chmod(exe_path, current_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            print(f"  Restored execute permissions")
            print(f"  ✓ Application is now allowed")
        except (OSError, PermissionError) as e:
            raise RuntimeError(f"Failed to allow app: {str(e)}")
    
    def _block_windows(self, exe_path: str, app_name: str):
        """Block application on Windows using Windows Firewall."""
        rule_name = f"AirTraffic_Block_{app_name}"
        
        try:
            # Kill all running instances first
            killed_count = 0
            for proc in psutil.process_iter(['exe', 'pid', 'name']):
                try:
                    if proc.info['exe'] and proc.info['exe'].lower() == exe_path.lower():
                        proc.kill()
                        killed_count += 1
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue
            
            if killed_count > 0:
                print(f"  Terminated {killed_count} running instance(s)")
            
            # Block outbound connections
            result = subprocess.run([
                'netsh', 'advfirewall', 'firewall', 'add', 'rule',
                f'name={rule_name}',
                'dir=out',
                'action=block',
                f'program={exe_path}',
                'enable=yes'
            ], check=True, capture_output=True, text=True)
            
            # Block inbound connections
            subprocess.run([
                'netsh', 'advfirewall', 'firewall', 'add', 'rule',
                f'name={rule_name}_In',
                'dir=in',
                'action=block',
                f'program={exe_path}',
                'enable=yes'
            ], check=True, capture_output=True, text=True)
            
            print(f"  Created firewall rules (inbound & outbound)")
            print(f"  ✓ Application is now blocked from network access")
            
        except subprocess.CalledProcessError as e:
            stderr = e.stderr if e.stderr else str(e)
            if 'denied' in stderr.lower() or 'access' in stderr.lower():
                raise RuntimeError("Failed to create firewall rule. Run as Administrator.")
            raise RuntimeError(f"Failed to block app: {stderr}")
    
    def _unblock_windows(self, exe_path: str, app_name: str):
        """Unblock application on Windows."""
        rule_name = f"AirTraffic_Block_{app_name}"
        
        try:
            # Remove outbound rule
            result_out = subprocess.run([
                'netsh', 'advfirewall', 'firewall', 'delete', 'rule',
                f'name={rule_name}'
            ], capture_output=True, text=True)
            
            # Remove inbound rule
            result_in = subprocess.run([
                'netsh', 'advfirewall', 'firewall', 'delete', 'rule',
                f'name={rule_name}_In'
            ], capture_output=True, text=True)
            
            print(f"  Removed firewall rules")
            print(f"  ✓ Application can now access network")
            
        except subprocess.CalledProcessError as e:
            # Rules might not exist, that's okay
            print(f"  ✓ Application can now access network")
            pass
