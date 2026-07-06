#!/usr/bin/env python3
"""
Log Analysis Utilities
Common functions and configuration management for Windows event log analysis
"""

import json
import os
import pandas as pd
from datetime import datetime, timedelta
import logging

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class LogAnalysisConfig:
    """Configuration manager for log analysis tools"""
    
    def __init__(self, config_file='log_analysis_config.json'):
        self.config_file = config_file
        self.config = self.load_config()
    
    def load_config(self):
        """Load configuration from JSON file"""
        try:
            if os.path.exists(self.config_file):
                with open(self.config_file, 'r') as f:
                    return json.load(f)
            else:
                logger.warning(f"Config file {self.config_file} not found, using defaults")
                return self.get_default_config()
        except Exception as e:
            logger.error(f"Error loading config: {e}")
            return self.get_default_config()
    
    def get_default_config(self):
        """Return default configuration"""
        return {
            "time_ranges": {
                "recent_minutes": 30,
                "export_hours": 12,
                "analysis_window_minutes": 15,
                "cluster_gap_minutes": 5
            },
            "critical_event_ids": [41, 6008, 46],
            "error_levels": ["Error", "Critical"],
            "warning_levels": ["Warning"],
            "info_levels": ["Information"],
            "pattern_detection": {
                "wsl_keywords": ["WSL", "Windows Subsystem"],
                "dcom_keywords": ["DCOM", "COM Server"],
                "defender_keywords": ["MsMpEng", "Defender", "Antivirus"],
                "service_keywords": ["service.*terminated", "service.*failed"],
                "hardware_keywords": ["hardware", "disk", "storage", "NVMe"],
                "hyperv_keywords": ["Hyper-V", "virtualization", "vmms"],
                "startmenu_keywords": ["StartMenu", "Start.*Menu"],
                "bsod_keywords": ["Blue Screen", "BSOD", "STOP", "BugCheck"],
                "memory_keywords": ["memory", "RAM", "page file"],
                "network_keywords": ["network", "TCP", "UDP", "connection"]
            },
            "output_formats": {
                "csv": True,
                "json": False,
                "html": False,
                "console": True
            },
            "date_format": "%m/%d/%Y %I:%M:%S %p",
            "max_message_length": 100,
            "enable_caching": True,
            "cache_duration_minutes": 5
        }
    
    def get(self, key, default=None):
        """Get configuration value with dot notation support"""
        keys = key.split('.')
        value = self.config
        try:
            for k in keys:
                value = value[k]
            return value
        except (KeyError, TypeError):
            return default

def safe_datetime_parse(series, date_format=None):
    """Safely parse datetime series with fallback"""
    try:
        if date_format:
            return pd.to_datetime(series, format=date_format, errors='coerce')
        else:
            return pd.to_datetime(series, errors='coerce')
    except Exception as e:
        logger.warning(f"Date parsing warning: {e}")
        return pd.to_datetime(series, errors='coerce')

def detect_patterns(df, pattern_config, message_col='Message'):
    """Detect patterns in event messages"""
    patterns = {}
    
    for pattern_name, keywords in pattern_config.items():
        if isinstance(keywords, list):
            # Multiple keywords (OR logic)
            pattern_mask = df[message_col].str.contains('|'.join(keywords), case=False, na=False)
        else:
            # Single regex pattern
            pattern_mask = df[message_col].str.contains(keywords, case=False, na=False)
        
        patterns[pattern_name] = df[pattern_mask]
    
    return patterns

def format_message(message, max_length=100):
    """Format message for display"""
    if pd.isna(message):
        return "No message"
    
    message_str = str(message)
    if len(message_str) > max_length:
        return message_str[:max_length] + "..."
    return message_str

def get_health_rating(error_count, warning_count=0):
    """Calculate system health rating"""
    if error_count == 0 and warning_count <= 2:
        return "[EXCELLENT] EXCELLENT", "No critical issues detected"
    elif error_count <= 2 and warning_count <= 5:
        return "[GOOD] GOOD", "Minimal issues detected"
    elif error_count <= 5:
        return "🟠 FAIR", "Some issues require attention"
    else:
        return "[CONCERN] POOR", "Multiple critical issues detected"

def save_analysis_results(results, filename, format_type='csv'):
    """Save analysis results in specified format"""
    try:
        if format_type == 'csv':
            results.to_csv(filename, index=False)
        elif format_type == 'json':
            results.to_json(filename, orient='records', date_format='iso')
        elif format_type == 'html':
            results.to_html(filename, escape=False, index=False)
        
        logger.info(f"Results saved to {filename}")
        return True
    except Exception as e:
        logger.error(f"Error saving results: {e}")
        return False

def validate_csv_files(system_file='system_events.csv', app_file='app_events.csv'):
    """Validate that required CSV files exist and are readable"""
    files_status = {}
    
    for file_name in [system_file, app_file]:
        if os.path.exists(file_name):
            try:
                df = pd.read_csv(file_name)
                files_status[file_name] = {
                    'exists': True,
                    'readable': True,
                    'rows': len(df),
                    'columns': list(df.columns)
                }
            except Exception as e:
                files_status[file_name] = {
                    'exists': True,
                    'readable': False,
                    'error': str(e)
                }
        else:
            files_status[file_name] = {
                'exists': False,
                'readable': False,
                'error': 'File not found'
            }
    
    return files_status

def print_analysis_header(title, width=60):
    """Print formatted analysis header"""
    print("\n" + "=" * width)
    print(title)
    print("=" * width)

def print_section_header(title, width=50):
    """Print formatted section header"""
    print(f"\n{'-' * width}")
    print(title)
    print(f"{'-' * width}")

def print_event_summary(events, title="Event Summary"):
    """Print formatted event summary"""
    if events.empty:
        print(f"{title}: No events found")
        return
    
    print(f"{title}: {len(events)} events")
    
    # Group by level
    level_counts = events['LevelDisplayName'].value_counts()
    for level, count in level_counts.items():
        print(f"  {level}: {count}")
    
    # Show recent events
    if len(events) > 0:
        print(f"\nRecent events:")
        for _, event in events.tail(3).iterrows():
            time_str = event['TimeCreated'].strftime('%H:%M:%S') if pd.notna(event['TimeCreated']) else 'Unknown'
            level = event.get('LevelDisplayName', 'Unknown')
            event_id = event.get('Id', 'Unknown')
            message = format_message(event.get('Message', ''))
            print(f"  {time_str} - ID:{event_id} - {level} - {message}")

# Global config instance
config = LogAnalysisConfig()

