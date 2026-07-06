#!/usr/bin/env python3
"""
Windows Event Log Critical Event Analysis
Analyzes system behavior around critical error events (41, 6008, 46) within
configurable windows. Reads CSV exported by export_events.ps1 and is driven by
an optional log_analysis_config.json (falls back to sensible defaults).
"""

import pandas as pd
import numpy as np
from datetime import datetime, timedelta
import sys
import os
from collections import defaultdict
import json

# Import our utilities
try:
    from log_analysis_utils import (
        LogAnalysisConfig, safe_datetime_parse, detect_patterns, 
        format_message, get_health_rating, print_analysis_header,
        print_section_header, print_event_summary, validate_csv_files
    )
    config = LogAnalysisConfig()
except ImportError:
    print("Warning: log_analysis_utils not found, using basic functionality")
    config = None

def load_event_data(system_file='system_events.csv', app_file='app_events.csv'):
    """Load event data from CSV files with enhanced error handling"""
    print("Loading event data from CSV files...")
    
    # Validate files first
    if config:
        file_status = validate_csv_files(system_file, app_file)
        for file_name, status in file_status.items():
            if not status['exists']:
                print(f"[ERROR] Error: {file_name} not found. Run export_events.ps1 first.")
                return None, None
            elif not status['readable']:
                print(f"[ERROR] Error: {file_name} is corrupted: {status.get('error', 'Unknown error')}")
                return None, None
            else:
                print(f"[OK] {file_name}: {status['rows']} rows, {len(status['columns'])} columns")
    
    try:
        system_df = pd.read_csv(system_file)
        app_df = pd.read_csv(app_file)
        
        # Enhanced date parsing
        date_format = config.get('date_format') if config else None
        system_df['TimeCreated'] = safe_datetime_parse(system_df['TimeCreated'], date_format)
        app_df['TimeCreated'] = safe_datetime_parse(app_df['TimeCreated'], date_format)
        
        # Sort by time
        system_df = system_df.sort_values('TimeCreated').reset_index(drop=True)
        app_df = app_df.sort_values('TimeCreated').reset_index(drop=True)
        
        print(f"[OK] Loaded {len(system_df)} System events and {len(app_df)} Application events")
        return system_df, app_df
        
    except Exception as e:
        print(f"[ERROR] Error loading data: {e}")
        return None, None

def analyze_critical_events(system_df, app_df):
    """Enhanced critical event analysis with configurable parameters"""
    if config:
        print_analysis_header("CRITICAL EVENT CLUSTER ANALYSIS")
    else:
        print("\n" + "="*60)
        print("CRITICAL EVENT CLUSTER ANALYSIS")
        print("="*60)
    
    # Get configuration values
    critical_event_ids = config.get('critical_event_ids', [41, 6008, 46]) if config else [41, 6008, 46]
    error_levels = config.get('error_levels', ['Error', 'Critical']) if config else ['Error', 'Critical']
    cluster_gap_minutes = config.get('time_ranges.cluster_gap_minutes', 5) if config else 5
    analysis_window_minutes = config.get('time_ranges.analysis_window_minutes', 15) if config else 15
    
    # Filter for critical events
    critical_events = system_df[
        (system_df['Id'].isin(critical_event_ids)) & 
        (system_df['LevelDisplayName'].isin(error_levels))
    ].copy()
    
    if critical_events.empty:
        print("No critical events found in the specified time range.")
        return
    
    print(f"\nFound {len(critical_events)} critical events:")
    print(critical_events[['TimeCreated', 'Id', 'LevelDisplayName', 'Message']].to_string(index=False))
    
    # Group events into clusters based on proximity
    clusters = []
    current_cluster = []
    last_time = None
    
    for _, event in critical_events.iterrows():
        if last_time is None or (event['TimeCreated'] - last_time).total_seconds() <= (cluster_gap_minutes * 60):
            current_cluster.append(event)
        else:
            if current_cluster:
                clusters.append(current_cluster)
            current_cluster = [event]
        last_time = event['TimeCreated']
    
    if current_cluster:
        clusters.append(current_cluster)
    
    print(f"\nIdentified {len(clusters)} critical event clusters")
    
    # Analyze each cluster
    for i, cluster in enumerate(clusters, 1):
        if config:
            print_section_header(f"CLUSTER {i}: {cluster[0]['TimeCreated'].strftime('%H:%M:%S')} - {cluster[-1]['TimeCreated'].strftime('%H:%M:%S')}")
        else:
            print(f"\n{'='*50}")
            print(f"CLUSTER {i}: {cluster[0]['TimeCreated'].strftime('%H:%M:%S')} - {cluster[-1]['TimeCreated'].strftime('%H:%M:%S')}")
            print(f"{'='*50}")
        
        cluster_start = cluster[0]['TimeCreated'] - timedelta(minutes=analysis_window_minutes)
        cluster_end = cluster[-1]['TimeCreated'] + timedelta(minutes=analysis_window_minutes)
        
        print(f"Analysis window: {cluster_start.strftime('%H:%M:%S')} to {cluster_end.strftime('%H:%M:%S')}")
        
        # Get all events in the analysis window
        window_events = system_df[
            (system_df['TimeCreated'] >= cluster_start) & 
            (system_df['TimeCreated'] <= cluster_end)
        ].copy()
        
        # Add application events in the same window
        app_window_events = app_df[
            (app_df['TimeCreated'] >= cluster_start) & 
            (app_df['TimeCreated'] <= cluster_end)
        ].copy()
        
        # Categorize events by timing
        before_critical = window_events[window_events['TimeCreated'] < cluster[0]['TimeCreated']]
        during_critical = window_events[
            (window_events['TimeCreated'] >= cluster[0]['TimeCreated']) & 
            (window_events['TimeCreated'] <= cluster[-1]['TimeCreated'])
        ]
        after_critical = window_events[window_events['TimeCreated'] > cluster[-1]['TimeCreated']]
        
        # Print event summaries
        if config:
            print_event_summary(before_critical, f"Events BEFORE critical cluster ({len(before_critical)} events)")
            print_event_summary(during_critical, f"Events DURING critical cluster ({len(during_critical)} events)")
            print_event_summary(after_critical, f"Events AFTER critical cluster ({len(after_critical)} events)")
        else:
            print(f"\nEvents BEFORE critical cluster ({len(before_critical)} events):")
            if not before_critical.empty:
                error_events = before_critical[before_critical['LevelDisplayName'].isin(['Error', 'Critical', 'Warning'])]
                if not error_events.empty:
                    print("ERRORS/WARNINGS:")
                    for _, event in error_events.iterrows():
                        print(f"  {event['TimeCreated'].strftime('%H:%M:%S')} - ID:{event['Id']} - {event['LevelDisplayName']} - {format_message(event['Message'])}")
                else:
                    print("  No errors/warnings found")
            else:
                print("  No events found")
        
        # Enhanced pattern analysis
        if config:
            pattern_config = config.get('pattern_detection', {})
            patterns = detect_patterns(window_events, pattern_config)
            
            print(f"\n[ANALYSIS] PATTERN ANALYSIS:")
            for pattern_name, pattern_events in patterns.items():
                if not pattern_events.empty:
                    print(f"  - Found {len(pattern_events)} {pattern_name.replace('_', ' ')} events in this window")
                    if len(pattern_events) <= 3:  # Show details for small numbers
                        for _, event in pattern_events.iterrows():
                            time_str = event['TimeCreated'].strftime('%H:%M:%S')
                            print(f"    {time_str} - ID:{event['Id']} - {format_message(event['Message'])}")
        else:
            # Basic pattern analysis
            print(f"\nPATTERN ANALYSIS:")
            
            # Check for WSL-related events
            wsl_events = window_events[window_events['Message'].str.contains('WSL|Windows Subsystem', case=False, na=False)]
            if not wsl_events.empty:
                print(f"  - Found {len(wsl_events)} WSL-related events in this window")
            
            # Check for DCOM events
            dcom_events = window_events[window_events['Id'] == 10005]
            if not dcom_events.empty:
                print(f"  - Found {len(dcom_events)} DCOM service failures in this window")

def analyze_timeline_patterns(system_df, app_df):
    """Enhanced timeline pattern analysis"""
    if config:
        print_analysis_header("TIMELINE PATTERN ANALYSIS")
    else:
        print(f"\n{'='*60}")
        print("TIMELINE PATTERN ANALYSIS")
        print(f"{'='*60}")
    
    # Get configuration values
    critical_event_ids = config.get('critical_event_ids', [41, 6008, 46]) if config else [41, 6008, 46]
    error_levels = config.get('error_levels', ['Error', 'Critical']) if config else ['Error', 'Critical']
    
    # Get all critical events
    critical_events = system_df[
        (system_df['Id'].isin(critical_event_ids)) & 
        (system_df['LevelDisplayName'].isin(error_levels))
    ].copy()
    
    if critical_events.empty:
        print("No critical events found for timeline analysis.")
        return
    
    print(f"\nCritical Events Timeline:")
    for _, event in critical_events.iterrows():
        print(f"  {event['TimeCreated'].strftime('%Y-%m-%d %H:%M:%S')} - ID:{event['Id']} - {event['LevelDisplayName']}")
    
    # Analyze time gaps between critical events
    if len(critical_events) > 1:
        time_diffs = []
        for i in range(1, len(critical_events)):
            diff = critical_events.iloc[i]['TimeCreated'] - critical_events.iloc[i-1]['TimeCreated']
            time_diffs.append(diff.total_seconds() / 60)  # Convert to minutes
        
        print(f"\nTime gaps between critical events (minutes):")
        for i, diff in enumerate(time_diffs, 1):
            print(f"  Gap {i}: {diff:.1f} minutes")
        
        print(f"\nAverage gap: {np.mean(time_diffs):.1f} minutes")
        print(f"Median gap: {np.median(time_diffs):.1f} minutes")
        
        # Identify patterns in gaps
        if len(time_diffs) > 2:
            if np.std(time_diffs) < 30:  # Low standard deviation
                print("[STATS] Pattern: Consistent timing between critical events")
            elif max(time_diffs) > 1440:  # More than 24 hours
                print("[STATS] Pattern: Long periods of stability between events")

def generate_summary_report(system_df, app_df):
    """Generate comprehensive summary report"""
    if config:
        print_analysis_header("SUMMARY STATISTICS")
    else:
        print(f"\n{'='*60}")
        print("SUMMARY STATISTICS")
        print(f"{'='*60}")
    
    # Get configuration values
    critical_event_ids = config.get('critical_event_ids', [41, 6008, 46]) if config else [41, 6008, 46]
    error_levels = config.get('error_levels', ['Error', 'Critical']) if config else ['Error', 'Critical']
    
    critical_events = system_df[
        (system_df['Id'].isin(critical_event_ids)) & 
        (system_df['LevelDisplayName'].isin(error_levels))
    ]
    
    print(f"Total critical events (IDs: {', '.join(map(str, critical_event_ids))}): {len(critical_events)}")
    
    # Breakdown by event ID
    for event_id in critical_event_ids:
        count = len(critical_events[critical_events['Id'] == event_id])
        event_names = {41: "Critical shutdown", 6008: "Unexpected shutdown", 46: "Crash dump failed", 
                      1074: "System shutdown initiated", 1076: "System startup after unexpected shutdown",
                      6005: "Event log service started", 6006: "Event log service stopped"}
        event_name = event_names.get(event_id, f"Event {event_id}")
        print(f"Event {event_id} ({event_name}): {count}")
    
    # Most common errors
    error_counts = system_df[system_df['LevelDisplayName'].isin(error_levels)]['Id'].value_counts().head(10)
    print(f"\nTop 10 most frequent errors:")
    for event_id, count in error_counts.items():
        print(f"  Event ID {event_id}: {count} occurrences")
    
    # Health assessment
    error_count = len(system_df[system_df['LevelDisplayName'].isin(error_levels)])
    warning_count = len(system_df[system_df['LevelDisplayName'] == 'Warning'])
    
    if config:
        health_rating, health_message = get_health_rating(error_count, warning_count)
        print(f"\n{health_rating} {health_message}")
    else:
        if error_count == 0:
            print(f"\n[EXCELLENT] EXCELLENT: No critical errors found")
        elif error_count <= 5:
            print(f"\n[GOOD] GOOD: {error_count} errors found - monitor for patterns")
        else:
            print(f"\n[CONCERN] CONCERN: {error_count} errors found - investigation recommended")

def main():
    """Main analysis function"""
    print("Windows Critical Event Analysis Tool")
    print("=" * 50)
    
    # Check for configuration
    if config:
        print(f"Configuration loaded from {config.config_file}")
        print(f"  Critical Event IDs: {config.get('critical_event_ids', [41, 6008, 46])}")
        print(f"  Analysis Window: {config.get('time_ranges.analysis_window_minutes', 15)} minutes")
    else:
        print("Using default configuration (log_analysis_utils not available)")
    
    try:
        # Load event data
        system_df, app_df = load_event_data()
        
        if system_df is None or system_df.empty:
            print("[ERROR] No system events found. Check CSV files and run export_events.ps1 first.")
            return
        
        # Perform analyses
        analyze_critical_events(system_df, app_df)
        analyze_timeline_patterns(system_df, app_df)
        generate_summary_report(system_df, app_df)
        
        print(f"\nAnalysis complete!")
        
    except Exception as e:
        print(f"Error during analysis: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()
