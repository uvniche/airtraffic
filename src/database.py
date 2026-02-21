"""Database module for storing network statistics."""

import sqlite3
import os
from datetime import datetime, timedelta
from typing import Dict, List, Tuple
import threading


def _get_db_dir() -> str:
    """Return the data directory for the database (shared between daemon and CLI on Unix)."""
    import platform
    if platform.system() == 'Windows':
        return os.path.join(os.getenv('APPDATA', ''), 'AirTraffic')
    # Use system-wide path when running as root so CLI (non-root) can read same DB
    if hasattr(os, 'geteuid') and os.geteuid() == 0:
        return '/var/lib/airtraffic'
    # When not root: use system path if it exists and we can read it (daemon was run with sudo)
    system_dir = '/var/lib/airtraffic'
    if os.path.isdir(system_dir) and os.access(system_dir, os.R_OK):
        return system_dir
    return os.path.expanduser('~/.airtraffic')


class NetworkDatabase:
    """SQLite database for storing network statistics."""
    
    def __init__(self, db_path: str = None):
        """Initialize database connection.
        
        Args:
            db_path: Path to SQLite database file
        """
        if db_path is None:
            db_dir = _get_db_dir()
            # Only create directory when we have permission (root or user's ~/.airtraffic)
            can_create = (
                not (db_dir == '/var/lib/airtraffic' and hasattr(os, 'geteuid') and os.geteuid() != 0)
            )
            if can_create:
                try:
                    os.makedirs(db_dir, exist_ok=True)
                    if db_dir == '/var/lib/airtraffic' and hasattr(os, 'geteuid') and os.geteuid() == 0:
                        os.chmod(db_dir, 0o755)
                except OSError as e:
                    raise OSError(f"Cannot create data directory {db_dir!r}: {e}") from e
            db_path = os.path.join(db_dir, 'network_stats.db')
        
        self.db_path = os.path.abspath(db_path)
        db_dir = os.path.dirname(self.db_path)
        # Non-root reading system DB (e.g. `airtraffic status`) only needs read access
        self._read_only = (
            db_dir == '/var/lib/airtraffic'
            and hasattr(os, 'geteuid')
            and os.geteuid() != 0
        )
        self.lock = threading.Lock()
        self._init_database()
    
    def _init_database(self):
        """Initialize database schema."""
        with self.lock:
            db_dir = os.path.dirname(self.db_path)
            if not os.path.isdir(db_dir):
                raise OSError(f"Data directory does not exist: {db_dir!r}")
            if not self._read_only and not os.access(db_dir, os.W_OK):
                raise OSError(f"Cannot write to data directory: {db_dir!r}")
            if self._read_only:
                if not os.path.exists(self.db_path):
                    raise OSError(
                        f"Database not found at {self.db_path!r}. "
                        "Start the daemon with 'sudo airtraffic run' first."
                    ) from None
                try:
                    conn = sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True)
                except sqlite3.OperationalError as e:
                    raise OSError(
                        f"Cannot open database at {self.db_path!r}. "
                        "Ensure the daemon has been run with 'sudo airtraffic run'."
                    ) from e
                conn.close()
                return
            try:
                conn = sqlite3.connect(self.db_path)
            except sqlite3.OperationalError as e:
                raise OSError(
                    f"Cannot open database at {self.db_path!r}. "
                    f"Check that the directory exists and is writable."
                ) from e
            cursor = conn.cursor()
            
            # Create table for network statistics
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS network_stats (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp DATETIME NOT NULL,
                    app_name TEXT NOT NULL,
                    bytes_sent INTEGER DEFAULT 0,
                    bytes_recv INTEGER DEFAULT 0,
                    connections INTEGER DEFAULT 0
                )
            ''')
            
            # Create index for faster queries
            cursor.execute('''
                CREATE INDEX IF NOT EXISTS idx_timestamp 
                ON network_stats(timestamp)
            ''')
            
            cursor.execute('''
                CREATE INDEX IF NOT EXISTS idx_app_name 
                ON network_stats(app_name)
            ''')
            
            conn.commit()
            conn.close()
            # When running as root, make DB readable so non-root 'airtraffic status' can read it
            if hasattr(os, 'geteuid') and os.geteuid() == 0 and os.path.exists(self.db_path):
                try:
                    os.chmod(self.db_path, 0o644)
                except OSError:
                    pass
    
    def _connect(self):
        """Return a database connection (read-only when self._read_only)."""
        if self._read_only:
            return sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True)
        return sqlite3.connect(self.db_path)
    
    def record_stats(self, stats: Dict[str, Dict[str, any]]):
        """Record network statistics to database.
        
        Args:
            stats: Dictionary of app statistics
        """
        if self._read_only or not stats:
            return
        
        timestamp = datetime.now()
        
        with self.lock:
            conn = self._connect()
            cursor = conn.cursor()
            
            for app_name, app_stats in stats.items():
                cursor.execute('''
                    INSERT INTO network_stats 
                    (timestamp, app_name, bytes_sent, bytes_recv, connections)
                    VALUES (?, ?, ?, ?, ?)
                ''', (
                    timestamp,
                    app_name,
                    int(app_stats.get('sent', 0)),
                    int(app_stats.get('recv', 0)),
                    app_stats.get('connections', 0)
                ))
            
            conn.commit()
            conn.close()
    
    def get_stats_since(self, start_time: datetime) -> Dict[str, Dict[str, int]]:
        """Get aggregated statistics since a specific time.
        
        Args:
            start_time: Start datetime for query
            
        Returns:
            Dictionary mapping app names to their total stats
        """
        with self.lock:
            conn = self._connect()
            cursor = conn.cursor()
            
            cursor.execute('''
                SELECT 
                    app_name,
                    SUM(bytes_sent) as total_sent,
                    SUM(bytes_recv) as total_recv,
                    MAX(connections) as max_connections
                FROM network_stats
                WHERE timestamp >= ?
                GROUP BY app_name
                ORDER BY (total_sent + total_recv) DESC
            ''', (start_time,))
            
            results = {}
            for row in cursor.fetchall():
                app_name, sent, recv, connections = row
                results[app_name] = {
                    'sent': sent or 0,
                    'recv': recv or 0,
                    'connections': connections or 0
                }
            
            conn.close()
            return results
    
    def get_today_stats(self) -> Dict[str, Dict[str, int]]:
        """Get statistics for today (since midnight)."""
        today_start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
        return self.get_stats_since(today_start)
    
    def get_week_stats(self) -> Dict[str, Dict[str, int]]:
        """Get statistics for this week (since Monday midnight)."""
        now = datetime.now()
        # Calculate days since Monday (0 = Monday, 6 = Sunday)
        days_since_monday = now.weekday()
        week_start = now.replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=days_since_monday)
        return self.get_stats_since(week_start)
    
    def get_month_stats(self) -> Dict[str, Dict[str, int]]:
        """Get statistics for this month (since 1st midnight)."""
        month_start = datetime.now().replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        return self.get_stats_since(month_start)
    
    def cleanup_old_data(self, days: int = 90):
        """Remove data older than specified days.
        
        Args:
            days: Number of days to keep (default: 90)
        """
        if self._read_only:
            return
        cutoff_date = datetime.now() - timedelta(days=days)
        
        with self.lock:
            conn = self._connect()
            cursor = conn.cursor()
            
            cursor.execute('''
                DELETE FROM network_stats
                WHERE timestamp < ?
            ''', (cutoff_date,))
            
            conn.commit()
            conn.close()
    
    def get_database_size(self) -> int:
        """Get database file size in bytes."""
        if os.path.exists(self.db_path):
            return os.path.getsize(self.db_path)
        return 0
