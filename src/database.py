"""Database module for storing network statistics."""

import sqlite3
import os
from datetime import datetime, timedelta
from typing import Dict, List, Tuple
import threading


class NetworkDatabase:
    """SQLite database for storing network statistics."""
    
    def __init__(self, db_path: str = None):
        """Initialize database connection."""
        if db_path is None:
            # Default path based on OS
            if os.name == 'posix':
                db_dir = os.path.expanduser('~/.airtraffic')
            else:
                db_dir = os.path.expanduser('~/airtraffic')
            
            os.makedirs(db_dir, exist_ok=True)
            db_path = os.path.join(db_dir, 'network_stats.db')
        
        self.db_path = db_path
        self.lock = threading.Lock()
        self._init_database()
    
    def _init_database(self):
        """Initialize database schema."""
        with self.lock:
            conn = sqlite3.connect(self.db_path)
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
    
    def record_stats(self, stats: Dict[str, Dict[str, any]]):
        """Record network statistics to database.
        
        Args:
            stats: Dictionary of app statistics
        """
        if not stats:
            return
        
        timestamp = datetime.now()
        
        with self.lock:
            conn = sqlite3.connect(self.db_path)
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
            conn = sqlite3.connect(self.db_path)
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
        """Remove data older than specified days."""
        cutoff_date = datetime.now() - timedelta(days=days)
        
        with self.lock:
            conn = sqlite3.connect(self.db_path)
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
