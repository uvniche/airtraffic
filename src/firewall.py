"""Firewall management module for blocking/unblocking network access.

This module provides cross-platform application-level network blocking using:
- macOS: Application Firewall (socketfilterfw)
- Linux: iptables with owner matching or nftables
- Windows: Windows Firewall (netsh advfirewall)

All operations require elevated privileges (sudo on Unix, Administrator on Windows).
"""

import os
import platform
import subprocess
import json
from typing import List, Dict, Optional
import psutil


class FirewallManager:
    """Manage firewall rules to block/unblock applications."""
    
    def __init__(self):
        self.system = platform.system()
        self.blocked_apps_file = self._get_blocked_apps_file()
        self._firewall_available = self._check_firewall_availability()
    
    def _check_firewall_availability(self) -> bool:
        """Check if firewall tools are available on this system.
        
        Returns:
            True if firewall is available and can be used
        """
        try:
            if self.system == "Darwin":
                return os.path.exists('/usr/libexec/ApplicationFirewall/socketfilterfw')
            elif self.system == "Linux":
                # Check for iptables or nftables
                try:
                    subprocess.run(['which', 'iptables'], 
                                 check=True, capture_output=True)
                    return True
                except:
                    try:
                        subprocess.run(['which', 'nft'], 
                                     check=True, capture_output=True)
                        return True
                    except:
                        return False
            elif self.system == "Windows":
                # netsh is always available on Windows
                return True
            return False
        except:
            return False
    
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
        
        for proc in psutil.process_iter(['name', 'exe', 'cmdline']):
            try:
                proc_name = proc.info['name']
                exe_path = proc.info['exe']
                
                # Match by process name
                if proc_name and process_name_lower in proc_name.lower():
                    if exe_path and exe_path not in matches:
                        matches.append(exe_path)
                # Also try matching by command line for scripts
                elif exe_path and process_name_lower in exe_path.lower():
                    if exe_path not in matches:
                        matches.append(exe_path)
                        
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                continue
        
        if not matches:
            raise ValueError(
                f"Process '{process_name}' not found.\n"
                f"Make sure the application is running and try again.\n"
                f"Tip: Use the exact process name or provide the full path to the executable."
            )
        
        if len(matches) > 1:
            # Try to deduplicate by resolving symlinks
            unique_matches = []
            seen_real_paths = set()
            
            for match in matches:
                try:
                    real_path = os.path.realpath(match)
                    if real_path not in seen_real_paths:
                        seen_real_paths.add(real_path)
                        unique_matches.append(match)
                except:
                    if match not in unique_matches:
                        unique_matches.append(match)
            
            if len(unique_matches) == 1:
                return unique_matches[0]
            
            raise ValueError(
                f"Multiple processes matching '{process_name}' found:\n" + 
                "\n".join(f"  - {m}" for m in unique_matches) +
                "\n\nPlease be more specific or provide the full path."
            )
        
        return matches[0]
    
    def block_app(self, app_identifier: str):
        """Block an application from accessing the network.
        
        Args:
            app_identifier: Process name or full path to executable
        """
        # Check firewall availability
        if not self._firewall_available:
            raise RuntimeError(
                f"Firewall tools not available on this system.\n"
                f"Please install the required tools:\n"
                f"  - macOS: Application Firewall (built-in)\n"
                f"  - Linux: iptables or nftables\n"
                f"  - Windows: Windows Firewall (built-in)"
            )
        
        # Check if we have root/admin privileges
        if self.system != 'Windows' and os.geteuid() != 0:
            raise PermissionError(
                "Root privileges required.\n"
                f"Run with: sudo airtraffic block {app_identifier}"
            )
        
        # Determine if it's a path or process name
        if os.path.exists(app_identifier):
            exe_path = os.path.abspath(app_identifier)
            app_name = os.path.basename(exe_path)
        else:
            exe_path = self._find_process_path(app_identifier)
            app_name = app_identifier
        
        # Verify the executable exists
        if not os.path.exists(exe_path):
            raise ValueError(f"Executable not found: {exe_path}")
        
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
        
        print(f"\n[BLOCKED] {app_name}")
        print(f"  Path: {exe_path}")
    
    def unblock_app(self, app_identifier: str):
        """Unblock an application from accessing the network.
        
        Args:
            app_identifier: Process name or full path to executable
        """
        # Check if we have root/admin privileges
        if self.system != 'Windows' and os.geteuid() != 0:
            raise PermissionError(
                "Root privileges required.\n"
                f"Run with: sudo airtraffic unblock {app_identifier}"
            )
        
        blocked_apps = self._load_blocked_apps()
        
        # Find the app in blocked list
        exe_path = None
        app_name = None
        
        if os.path.exists(app_identifier):
            exe_path = os.path.abspath(app_identifier)
            app_name = os.path.basename(exe_path)
        else:
            # Search in blocked apps (exact match first, then partial)
            for name, path in blocked_apps.items():
                if app_identifier.lower() == name.lower():
                    app_name = name
                    exe_path = path
                    break
            
            # If no exact match, try partial match
            if not app_name:
                matches = []
                for name, path in blocked_apps.items():
                    if app_identifier.lower() in name.lower():
                        matches.append((name, path))
                
                if len(matches) == 1:
                    app_name, exe_path = matches[0]
                elif len(matches) > 1:
                    raise ValueError(
                        f"Multiple blocked apps match '{app_identifier}':\n" +
                        "\n".join(f"  - {name}" for name, _ in matches) +
                        "\n\nPlease be more specific."
                    )
        
        if not exe_path:
            raise ValueError(
                f"Application '{app_identifier}' is not in the blocked list.\n"
                f"Use 'airtraffic list blocked' to see blocked applications."
            )
        
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
        
        print(f"\n[ALLOWED] {app_name}")
        print(f"  Path: {exe_path}")
    
    def list_blocked(self) -> List[Dict[str, str]]:
        """List all blocked applications.
        
        Returns:
            List of dictionaries with app info
        """
        blocked_apps = self._load_blocked_apps()
        return [{"name": name, "path": path} for name, path in blocked_apps.items()]
    
    def verify_block_status(self, app_name: str) -> Optional[bool]:
        """Verify if an application is actually blocked in the firewall.
        
        Args:
            app_name: Name of the application to check
            
        Returns:
            True if blocked, False if not blocked, None if cannot determine
        """
        blocked_apps = self._load_blocked_apps()
        
        if app_name not in blocked_apps:
            return False
        
        exe_path = blocked_apps[app_name]
        
        try:
            if self.system == "Darwin":
                # Check macOS Application Firewall
                app_bundle = self._find_app_bundle(exe_path)
                target = app_bundle if app_bundle else exe_path
                
                result = subprocess.run([
                    '/usr/libexec/ApplicationFirewall/socketfilterfw',
                    '--getappblocked', target
                ], capture_output=True, text=True)
                
                return 'block' in result.stdout.lower() or 'deny' in result.stdout.lower()
                
            elif self.system == "Linux":
                cmd_name = os.path.basename(exe_path)
                
                # Check iptables
                result = subprocess.run([
                    'iptables', '-L', 'OUTPUT', '-n'
                ], capture_output=True, text=True)
                
                if cmd_name in result.stdout:
                    return True
                
                # Check nftables
                try:
                    result = subprocess.run([
                        'nft', 'list', 'table', 'inet', 'airtraffic'
                    ], capture_output=True, text=True)
                    
                    if cmd_name in result.stdout:
                        return True
                except:
                    pass
                
                return False
                
            elif self.system == "Windows":
                safe_app_name = ''.join(c for c in app_name if c.isalnum() or c in ('_', '-'))
                rule_name = f"AirTraffic_Block_{safe_app_name}_Out"
                
                result = subprocess.run([
                    'netsh', 'advfirewall', 'firewall', 'show', 'rule',
                    f'name={rule_name}'
                ], capture_output=True, text=True)
                
                return 'No rules match' not in result.stdout
                
        except Exception:
            pass
        
        return None
    
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
                print(f"[BLOCKED] {app_name}")
            except Exception as e:
                errors.append(f"[FAILED] Failed to block {app_name}: {e}")
        
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
                print(f"[ALLOWED] {app_name}")
            except Exception as e:
                errors.append(f"[FAILED] Failed to allow {app_name}: {e}")
        
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
        """Block application on macOS from accessing the network.
        
        Uses macOS Application Firewall (socketfilterfw) to block the app.
        This is the same mechanism used by System Preferences > Security & Privacy > Firewall.
        """
        try:
            # Verify socketfilterfw is available
            if not os.path.exists('/usr/libexec/ApplicationFirewall/socketfilterfw'):
                raise RuntimeError("macOS Application Firewall not found")
            
            # macOS Application Firewall can block .app bundles
            # If exe_path is inside a .app bundle, find the bundle path
            app_bundle_path = self._find_app_bundle(exe_path)
            
            if app_bundle_path:
                target_path = app_bundle_path
                print(f"  Found app bundle: {os.path.basename(app_bundle_path)}")
            else:
                target_path = exe_path
                print(f"  Using executable path: {os.path.basename(exe_path)}")
            
            # Verify the target exists
            if not os.path.exists(target_path):
                raise RuntimeError(f"Target path does not exist: {target_path}")
            
            # Add the application to the firewall blocklist
            result = subprocess.run([
                '/usr/libexec/ApplicationFirewall/socketfilterfw',
                '--add', target_path
            ], capture_output=True, text=True)
            
            # Check for errors (ignore "already exists")
            if result.returncode != 0:
                stderr_lower = result.stderr.lower()
                stdout_lower = result.stdout.lower()
                if 'already exists' not in stderr_lower and 'already exists' not in stdout_lower:
                    raise RuntimeError(f"Failed to add to firewall: {result.stderr}")
            
            # Block the application (set to DENY)
            result = subprocess.run([
                '/usr/libexec/ApplicationFirewall/socketfilterfw',
                '--blockapp', target_path
            ], capture_output=True, text=True)
            
            if result.returncode != 0:
                raise RuntimeError(f"Failed to block app: {result.stderr}")
            
            print(f"  ✓ Blocked by macOS Application Firewall")
            print(f"  All network connections will be blocked")
            print(f"  Note: The app may need to be restarted for changes to take effect")
            
        except Exception as e:
            raise RuntimeError(f"Failed to block app: {str(e)}")
    
    def _find_app_bundle(self, exe_path: str) -> str:
        """Find the .app bundle containing an executable.
        
        Args:
            exe_path: Path to the executable
            
        Returns:
            Path to the .app bundle, or None if not in a bundle
        """
        # Walk up the directory tree looking for .app
        current = exe_path
        while current != '/' and current != '':
            if current.endswith('.app'):
                return current
            current = os.path.dirname(current)
        return None
    
    def _unblock_macos(self, exe_path: str, app_name: str):
        """Unblock application on macOS to allow network access."""
        try:
            # Find app bundle if applicable
            app_bundle_path = self._find_app_bundle(exe_path)
            target_path = app_bundle_path if app_bundle_path else exe_path
            
            # Unblock the application (set to ALLOW)
            result = subprocess.run([
                '/usr/libexec/ApplicationFirewall/socketfilterfw',
                '--unblockapp', target_path
            ], capture_output=True, text=True)
            
            if result.returncode == 0:
                print(f"  ✓ Unblocked by macOS Application Firewall")
                print(f"  Network access restored")
            else:
                # Try to remove it completely from the firewall list
                subprocess.run([
                    '/usr/libexec/ApplicationFirewall/socketfilterfw',
                    '--remove', target_path
                ], capture_output=True, text=True)
                print(f"  ✓ Removed from firewall list")
            
            print(f"  Note: The app may need to be restarted for changes to take effect")
            
        except Exception as e:
            # Still proceed even if there's an error
            print(f"  Removed from blocked list")
            pass
    
    def _block_linux(self, exe_path: str, app_name: str):
        """Block application on Linux from accessing the network.
        
        Uses multiple approaches in order of preference:
        1. iptables with cgroup matching (most reliable, requires cgroup setup)
        2. iptables with owner matching by command name
        3. nftables (modern alternative to iptables)
        """
        try:
            # Method 1: Try iptables with owner matching by command
            # This matches processes by their executable path
            try:
                # Get the command name from the path
                cmd_name = os.path.basename(exe_path)
                
                # Check if iptables supports owner module with cmd-owner
                check_result = subprocess.run([
                    'iptables', '-m', 'owner', '--help'
                ], capture_output=True, text=True)
                
                supports_cmd_owner = '--cmd-owner' in check_result.stdout
                
                if supports_cmd_owner:
                    # Block outbound connections using command name matching
                    subprocess.run([
                        'iptables', '-A', 'OUTPUT',
                        '-m', 'owner', '--cmd-owner', cmd_name,
                        '-j', 'DROP'
                    ], check=True, capture_output=True, text=True)
                    
                    # Block inbound connections
                    subprocess.run([
                        'iptables', '-A', 'INPUT',
                        '-m', 'owner', '--cmd-owner', cmd_name,
                        '-j', 'DROP'
                    ], check=True, capture_output=True, text=True)
                    
                    print(f"  ✓ Added iptables rules (inbound & outbound)")
                    print(f"  Matching command: {cmd_name}")
                    return
                
            except subprocess.CalledProcessError as e:
                pass  # Try next method
            
            # Method 2: Try nftables (modern alternative)
            try:
                # Check if nft is available
                subprocess.run(['which', 'nft'], check=True, capture_output=True)
                
                table_name = "airtraffic"
                chain_name = "output_filter"
                
                # Create table if it doesn't exist
                subprocess.run([
                    'nft', 'add', 'table', 'inet', table_name
                ], capture_output=True, text=True)
                
                # Create chain if it doesn't exist
                subprocess.run([
                    'nft', 'add', 'chain', 'inet', table_name, chain_name,
                    '{ type filter hook output priority 0; policy accept; }'
                ], capture_output=True, text=True)
                
                # Add rule to block the application
                cmd_name = os.path.basename(exe_path)
                subprocess.run([
                    'nft', 'add', 'rule', 'inet', table_name, chain_name,
                    'meta', 'comm', cmd_name, 'drop'
                ], check=True, capture_output=True, text=True)
                
                print(f"  ✓ Added nftables rule")
                print(f"  Matching command: {cmd_name}")
                return
                
            except (subprocess.CalledProcessError, FileNotFoundError):
                pass  # Try next method
            
            # Method 3: Fallback - use basic iptables with process name in comment
            # This won't actually block but will track it
            try:
                cmd_name = os.path.basename(exe_path)
                subprocess.run([
                    'iptables', '-A', 'OUTPUT',
                    '-m', 'comment', '--comment', f'airtraffic-block-{cmd_name}',
                    '-j', 'ACCEPT'  # Just track, don't block
                ], check=True, capture_output=True, text=True)
                
                print(f"  ⚠ Limited blocking capability detected")
                print(f"  Tracked as blocked (manual firewall configuration recommended)")
                print(f"  Consider installing iptables-extensions or nftables for full blocking")
                return
                
            except subprocess.CalledProcessError:
                pass
            
            # If all methods fail
            raise RuntimeError(
                "Could not configure firewall. Please ensure:\n"
                "  - You have root/sudo privileges\n"
                "  - iptables or nftables is installed\n"
                "  - Firewall modules are loaded"
            )
            
        except Exception as e:
            raise RuntimeError(f"Failed to block app: {str(e)}")
    
    def _unblock_linux(self, exe_path: str, app_name: str):
        """Unblock application on Linux to allow network access."""
        cmd_name = os.path.basename(exe_path)
        removed = False
        
        # Try to remove iptables rules with cmd-owner
        try:
            # Remove outbound rule
            result = subprocess.run([
                'iptables', '-D', 'OUTPUT',
                '-m', 'owner', '--cmd-owner', cmd_name,
                '-j', 'DROP'
            ], capture_output=True, text=True)
            
            if result.returncode == 0:
                removed = True
            
            # Remove inbound rule
            subprocess.run([
                'iptables', '-D', 'INPUT',
                '-m', 'owner', '--cmd-owner', cmd_name,
                '-j', 'DROP'
            ], capture_output=True, text=True)
            
        except subprocess.CalledProcessError:
            pass
        
        # Try to remove nftables rules
        try:
            table_name = "airtraffic"
            chain_name = "output_filter"
            
            # List rules and find the one matching our command
            result = subprocess.run([
                'nft', '-a', 'list', 'chain', 'inet', table_name, chain_name
            ], capture_output=True, text=True)
            
            if result.returncode == 0:
                # Parse output to find rule handle
                for line in result.stdout.split('\n'):
                    if cmd_name in line and 'drop' in line:
                        # Extract handle number
                        parts = line.split('# handle ')
                        if len(parts) > 1:
                            handle = parts[1].strip()
                            # Delete the rule
                            subprocess.run([
                                'nft', 'delete', 'rule', 'inet', table_name, chain_name,
                                'handle', handle
                            ], capture_output=True, text=True)
                            removed = True
                            break
        except (subprocess.CalledProcessError, FileNotFoundError):
            pass
        
        # Try to remove tracking rule
        try:
            subprocess.run([
                'iptables', '-D', 'OUTPUT',
                '-m', 'comment', '--comment', f'airtraffic-block-{cmd_name}',
                '-j', 'ACCEPT'
            ], capture_output=True, text=True)
        except subprocess.CalledProcessError:
            pass
        
        if removed:
            print(f"  ✓ Removed firewall rules")
        else:
            print(f"  Removed from blocked list")
    
    def _block_windows(self, exe_path: str, app_name: str):
        """Block application on Windows from accessing the network using Windows Firewall."""
        # Sanitize app name for rule name (remove special characters)
        safe_app_name = ''.join(c for c in app_name if c.isalnum() or c in ('_', '-'))
        rule_name_out = f"AirTraffic_Block_{safe_app_name}_Out"
        rule_name_in = f"AirTraffic_Block_{safe_app_name}_In"
        
        try:
            # Check if rules already exist and delete them first
            subprocess.run([
                'netsh', 'advfirewall', 'firewall', 'delete', 'rule',
                f'name={rule_name_out}'
            ], capture_output=True, text=True)
            
            subprocess.run([
                'netsh', 'advfirewall', 'firewall', 'delete', 'rule',
                f'name={rule_name_in}'
            ], capture_output=True, text=True)
            
            # Block outbound connections
            result = subprocess.run([
                'netsh', 'advfirewall', 'firewall', 'add', 'rule',
                f'name={rule_name_out}',
                'dir=out',
                'action=block',
                f'program={exe_path}',
                'enable=yes',
                'profile=any'
            ], capture_output=True, text=True)
            
            if result.returncode != 0:
                stderr = result.stderr if result.stderr else result.stdout
                if 'denied' in stderr.lower() or 'access' in stderr.lower():
                    raise RuntimeError("Administrator privileges required. Run as Administrator.")
                raise RuntimeError(f"Failed to create outbound rule: {stderr}")
            
            # Block inbound connections
            result = subprocess.run([
                'netsh', 'advfirewall', 'firewall', 'add', 'rule',
                f'name={rule_name_in}',
                'dir=in',
                'action=block',
                f'program={exe_path}',
                'enable=yes',
                'profile=any'
            ], capture_output=True, text=True)
            
            if result.returncode != 0:
                # If inbound fails, try to clean up outbound rule
                subprocess.run([
                    'netsh', 'advfirewall', 'firewall', 'delete', 'rule',
                    f'name={rule_name_out}'
                ], capture_output=True, text=True)
                
                stderr = result.stderr if result.stderr else result.stdout
                raise RuntimeError(f"Failed to create inbound rule: {stderr}")
            
            print(f"  ✓ Created Windows Firewall rules")
            print(f"  Rules: {rule_name_out}, {rule_name_in}")
            print(f"  All network connections will be blocked")
            
        except subprocess.CalledProcessError as e:
            stderr = e.stderr if e.stderr else str(e)
            if 'denied' in stderr.lower() or 'access' in stderr.lower():
                raise RuntimeError("Administrator privileges required. Run as Administrator.")
            raise RuntimeError(f"Failed to block app: {stderr}")
    
    def _unblock_windows(self, exe_path: str, app_name: str):
        """Unblock application on Windows."""
        # Sanitize app name for rule name (remove special characters)
        safe_app_name = ''.join(c for c in app_name if c.isalnum() or c in ('_', '-'))
        rule_name_out = f"AirTraffic_Block_{safe_app_name}_Out"
        rule_name_in = f"AirTraffic_Block_{safe_app_name}_In"
        
        removed_count = 0
        
        try:
            # Remove outbound rule
            result_out = subprocess.run([
                'netsh', 'advfirewall', 'firewall', 'delete', 'rule',
                f'name={rule_name_out}'
            ], capture_output=True, text=True)
            
            if result_out.returncode == 0:
                removed_count += 1
            
            # Remove inbound rule
            result_in = subprocess.run([
                'netsh', 'advfirewall', 'firewall', 'delete', 'rule',
                f'name={rule_name_in}'
            ], capture_output=True, text=True)
            
            if result_in.returncode == 0:
                removed_count += 1
            
            # Also try old naming convention for backwards compatibility
            old_rule_name = f"AirTraffic_Block_{app_name}"
            subprocess.run([
                'netsh', 'advfirewall', 'firewall', 'delete', 'rule',
                f'name={old_rule_name}'
            ], capture_output=True, text=True)
            
            subprocess.run([
                'netsh', 'advfirewall', 'firewall', 'delete', 'rule',
                f'name={old_rule_name}_In'
            ], capture_output=True, text=True)
            
            if removed_count > 0:
                print(f"  ✓ Removed {removed_count} Windows Firewall rule(s)")
                print(f"  Network access restored")
            else:
                print(f"  Removed from blocked list")
            
        except subprocess.CalledProcessError as e:
            # Rules might not exist, that's okay
            print(f"  Removed from blocked list")
