#!/usr/bin/env python3
"""
Recent Windows Events Analysis
Analyzes recent events (default last 30 minutes) with configurable parameters,
driven by an optional log_analysis_config.json (falls back to sensible defaults).
"""

import pandas as pd
import subprocess
import json
import os
from datetime import datetime, timedelta

# Import our utilities
try:
    from log_analysis_utils import (
        LogAnalysisConfig, safe_datetime_parse, detect_patterns, 
        format_message, get_health_rating, print_analysis_header,
        print_section_header, print_event_summary
    )
    config = LogAnalysisConfig()
except ImportError:
    print("Warning: log_analysis_utils not found, using basic functionality")
    config = None

def get_recent_events(minutes_back=None):
    """Get recent events using PowerShell with enhanced error handling"""
    if minutes_back is None:
        minutes_back = config.get('time_ranges.recent_minutes', 30) if config else 30
    
    print(f"Fetching recent events from the last {minutes_back} minutes...")
    
    # Enhanced PowerShell command with better error handling
    ps_cmd = f"""
    $startTime = (Get-Date).AddMinutes(-{minutes_back})
    $ErrorActionPreference = "Stop"
    
    try {{
        $systemEvents = Get-WinEvent -FilterHashtable @{{LogName='System'; StartTime=$startTime}} | 
            Select-Object TimeCreated, Id, LevelDisplayName, @{{Name='Message';Expression={{$_.Message -replace "`n", " " -replace "`r", " "}}}} |
            Sort-Object TimeCreated
        
        $appEvents = Get-WinEvent -FilterHashtable @{{LogName='Application'; StartTime=$startTime}} | 
            Select-Object TimeCreated, Id, LevelDisplayName, @{{Name='Message';Expression={{$_.Message -replace "`n", " " -replace "`r", " "}}}} |
            Sort-Object TimeCreated
        
        $systemEvents | Export-Csv -Path "recent_system.csv" -NoTypeInformation -Encoding UTF8
        $appEvents | Export-Csv -Path "recent_app.csv" -NoTypeInformation -Encoding UTF8
        
        Write-Host "System Events: $($systemEvents.Count)"
        Write-Host "Application Events: $($appEvents.Count)"
    }} catch {{
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }}
    """
    
    try:
        result = subprocess.run(['powershell', '-Command', ps_cmd], 
                              capture_output=True, text=True, timeout=120)
        
        if result.returncode != 0:
            print(f"[ERROR] PowerShell error: {result.stderr}")
            return None, None
        
        print(result.stdout)
        if result.stderr:
            print(f"[WARNING]️ PowerShell warnings: {result.stderr}")
            
    except subprocess.TimeoutExpired:
        print("[ERROR] PowerShell command timed out")
        return None, None
    except Exception as e:
        print(f"[ERROR] Error running PowerShell: {e}")
        return None, None
    
    # Load the CSV files with enhanced error handling
    try:
        system_df = pd.read_csv('recent_system.csv')
        app_df = pd.read_csv('recent_app.csv')
        
        # Enhanced date parsing
        date_format = config.get('date_format') if config else None
        system_df['TimeCreated'] = safe_datetime_parse(system_df['TimeCreated'], date_format)
        app_df['TimeCreated'] = safe_datetime_parse(app_df['TimeCreated'], date_format)
        
        return system_df, app_df
    except Exception as e:
        print(f"[ERROR] Error loading CSV files: {e}")
        return None, None

def analyze_recent_events(system_df, app_df):
    """Enhanced recent events analysis with configurable parameters"""
    if config:
        print_analysis_header("RECENT SYSTEM ANALYSIS")
    else:
        print("\n" + "="*60)
        print("RECENT SYSTEM ANALYSIS")
        print("="*60)
    
    if system_df is None or system_df.empty:
        print("No system events found in the specified time range.")
        return
    
    print(f"Total System Events: {len(system_df)}")
    print(f"Total Application Events: {len(app_df) if app_df is not None else 0}")
    
    # Get configuration values
    error_levels = config.get('error_levels', ['Error', 'Critical']) if config else ['Error', 'Critical']
    warning_levels = config.get('warning_levels', ['Warning']) if config else ['Warning']
    info_levels = config.get('info_levels', ['Information']) if config else ['Information']
    
    # Filter events by level
    errors = system_df[system_df['LevelDisplayName'].isin(error_levels)]
    warnings = system_df[system_df['LevelDisplayName'].isin(warning_levels)]
    info = system_df[system_df['LevelDisplayName'].isin(info_levels)]
    
    print(f"\nEvent Breakdown:")
    print(f"  Errors/Critical: {len(errors)}")
    print(f"  Warnings: {len(warnings)}")
    print(f"  Information: {len(info)}")
    
    # Enhanced error analysis
    if len(errors) > 0:
        if config:
            print_section_header("[ALERT] ERRORS FOUND IN RECENT PERIOD")
        else:
            print(f"\n[ALERT] ERRORS FOUND IN RECENT PERIOD:")
            print("-" * 50)
        
        # Group errors by type
        error_counts = errors['Id'].value_counts()
        print(f"\nError Summary:")
        for error_id, count in error_counts.items():
            print(f"  Event ID {error_id}: {count} occurrences")
        
        # Show recent errors with enhanced formatting
        print(f"\nRecent Error Details:")
        for _, error in errors.iterrows():
            time_str = error['TimeCreated'].strftime('%H:%M:%S') if pd.notna(error['TimeCreated']) else 'Unknown'
            level = error.get('LevelDisplayName', 'Unknown')
            event_id = error.get('Id', 'Unknown')
            message = format_message(error.get('Message', ''))
            print(f"  {time_str} - ID:{event_id} - {level}")
            print(f"    {message}")
            print()
        
        # Enhanced pattern analysis
        if config:
            print_section_header("[ANALYSIS] PATTERN ANALYSIS")
            pattern_config = config.get('pattern_detection', {})
            patterns = detect_patterns(errors, pattern_config)
            
            for pattern_name, pattern_events in patterns.items():
                if not pattern_events.empty:
                    print(f"  [ERROR] {pattern_name.replace('_', ' ').title()}: {len(pattern_events)} events")
                    if len(pattern_events) <= 3:  # Show details for small numbers
                        for _, event in pattern_events.iterrows():
                            time_str = event['TimeCreated'].strftime('%H:%M:%S')
                            print(f"    {time_str} - ID:{event['Id']} - {format_message(event['Message'])}")
        else:
            # Basic pattern analysis
            print("[ANALYSIS] PATTERN ANALYSIS:")
            
            # DCOM errors
            dcom_errors = errors[errors['Id'] == 10005]
            if len(dcom_errors) > 0:
                print(f"  [ERROR] DCOM Service Failures: {len(dcom_errors)} (still occurring)")
            else:
                print(f"  [SUCCESS] DCOM Service Failures: 0 (resolved)")
            
            # Crash dump errors
            crash_errors = errors[errors['Id'] == 46]
            if len(crash_errors) > 0:
                print(f"  [ERROR] Crash Dump Failures: {len(crash_errors)} (page file may not be working)")
            else:
                print(f"  [SUCCESS] Crash Dump Failures: 0 (page file working)")
            
            # Service termination errors
            service_errors = errors[errors['Id'] == 7034]
            if len(service_errors) > 0:
                print(f"  [ERROR] Service Terminations: {len(service_errors)}")
                for _, error in service_errors.iterrows():
                    print(f"    - {format_message(error.get('Message', ''))}")
            else:
                print(f"  [SUCCESS] Service Terminations: 0")
    
    else:
        print(f"\n[SUCCESS] NO ERRORS FOUND IN RECENT PERIOD!")
        print("System appears to be stable.")
    
    # Enhanced success analysis
    if len(info) > 0:
        success_events = info[info['Message'].str.contains('successfully|started|completed', case=False, na=False)]
        print(f"\n[SUCCESS] Successful Operations: {len(success_events)}")
        
        if len(success_events) > 0:
            print(f"\nRecent Successful Operations:")
            for _, event in success_events.tail(5).iterrows():
                time_str = event['TimeCreated'].strftime('%H:%M:%S') if pd.notna(event['TimeCreated']) else 'Unknown'
                message = format_message(event.get('Message', ''))
                print(f"  {time_str} - {message}")
    
    # Update-related events
    update_events = system_df[system_df['Message'].str.contains('update|install|KB', case=False, na=False)]
    if len(update_events) > 0:
        print(f"\n📦 Update-Related Events: {len(update_events)}")
        for _, event in update_events.iterrows():
            time_str = event['TimeCreated'].strftime('%H:%M:%S') if pd.notna(event['TimeCreated']) else 'Unknown'
            message = format_message(event.get('Message', ''))
            print(f"  {time_str} - {message}")
    
    # Overall health assessment
    if config:
        print_analysis_header("OVERALL HEALTH ASSESSMENT")
        health_rating, health_message = get_health_rating(len(errors), len(warnings))
        print(f"{health_rating} {health_message}")
        
        if len(errors) == 0:
            print("   - System stability is excellent")
            print("   - No critical issues detected")
        elif len(errors) <= 3:
            print("   - System is mostly stable")
            print("   - Monitor for any recurring patterns")
        else:
            print("   - Multiple issues detected")
            print("   - Further investigation recommended")
    else:
        # Basic health assessment
        print(f"\n" + "="*60)
        print("OVERALL ASSESSMENT")
        print("="*60)
        
        if len(errors) == 0:
            print("[EXCELLENT] EXCELLENT: No errors in the recent period!")
            print("   - System stability is excellent")
        elif len(errors) <= 3:
            print("[GOOD] GOOD: Minimal errors detected")
            print("   - System is mostly stable")
        else:
            print("[CONCERN] CONCERN: Multiple errors detected")
            print("   - Further investigation recommended")

def generate_health_report(system_df, app_df):
    """Generate a comprehensive health report"""
    if not config:
        return
    
    print_analysis_header("DETAILED HEALTH REPORT")
    
    # Event frequency analysis
    print("[STATS] Event Frequency Analysis:")
    level_counts = system_df['LevelDisplayName'].value_counts()
    for level, count in level_counts.items():
        print(f"  {level}: {count}")
    
    # Time-based analysis
    if not system_df.empty:
        time_range = system_df['TimeCreated'].max() - system_df['TimeCreated'].min()
        print(f"\n[TIME] Time Range: {time_range}")
        
        # Events per hour
        events_per_hour = len(system_df) / (time_range.total_seconds() / 3600) if time_range.total_seconds() > 0 else 0
        print(f"[RATE] Events per hour: {events_per_hour:.1f}")
    
    # Critical event proximity
    critical_events = system_df[system_df['Id'].isin([41, 6008, 46])]
    if not critical_events.empty:
        print(f"\n[ALERT] Critical Events Timeline:")
        for _, event in critical_events.iterrows():
            time_str = event['TimeCreated'].strftime('%Y-%m-%d %H:%M:%S')
            print(f"  {time_str} - ID:{event['Id']} - {event['LevelDisplayName']}")

def main():
    """Main analysis function"""
    print("Recent Windows Event Analysis Tool")
    print("=" * 50)
    
    # Check for configuration
    if config:
        print(f"Configuration loaded from {config.config_file}")
        minutes_back = config.get('time_ranges.recent_minutes', 30)
        print(f"  Analysis period: {minutes_back} minutes")
    else:
        print("Using default configuration (log_analysis_utils not available)")
        minutes_back = 30
    
    try:
        # Get recent events
        system_df, app_df = get_recent_events(minutes_back)
        
        if system_df is not None:
            # Perform analyses
            analyze_recent_events(system_df, app_df)
            
            if config:
                generate_health_report(system_df, app_df)
            
            print(f"\n[SUCCESS] Analysis complete!")
        else:
            print("[ERROR] Failed to retrieve recent events.")
    
    except Exception as e:
        print(f"[ERROR] Error during analysis: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()
