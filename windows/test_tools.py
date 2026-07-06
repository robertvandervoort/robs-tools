#!/usr/bin/env python3
"""
Test script for the log analysis tools
Validates functionality and configuration
"""

import subprocess
import os
import sys
from datetime import datetime

def test_config_loading():
    """Test configuration loading"""
    print("Testing configuration loading...")
    try:
        from log_analysis_utils import LogAnalysisConfig
        config = LogAnalysisConfig()
        print(f"[OK] Configuration loaded successfully")
        print(f"  Critical Event IDs: {config.get('critical_event_ids', [])}")
        print(f"  Recent minutes: {config.get('time_ranges.recent_minutes', 30)}")
        return True
    except Exception as e:
        print(f"[ERROR] Configuration loading failed: {e}")
        return False

def test_export_script():
    """Test the export script"""
    print("\nTesting export script...")
    try:
        result = subprocess.run(['powershell', '-ExecutionPolicy', 'Bypass', '-File', 'export_events.ps1', '-HoursBack', '2'], 
                              capture_output=True, text=True, timeout=60)
        
        if result.returncode == 0:
            print("[OK] Export script completed successfully")
            print("Output:", result.stdout)
            return True
        else:
            print(f"[ERROR] Export script failed: {result.stderr}")
            return False
    except Exception as e:
        print(f"[ERROR] Error running export script: {e}")
        return False

def test_csv_analysis():
    """Test CSV-based analysis"""
    print("\nTesting CSV-based analysis...")
    try:
        result = subprocess.run([sys.executable, 'analyze_critical_events.py'], 
                              capture_output=True, text=True, timeout=30)
        
        if result.returncode == 0:
            print("[OK] CSV analysis completed successfully")
            print("Output preview:")
            lines = result.stdout.split('\n')
            for line in lines[:10]:  # Show first 10 lines
                print(f"  {line}")
            return True
        else:
            print(f"[ERROR] Enhanced CSV analysis failed: {result.stderr}")
            return False
    except Exception as e:
        print(f"[ERROR] Error running CSV analysis: {e}")
        return False

def test_recent_analysis():
    """Test recent events analysis"""
    print("\nTesting recent events analysis...")
    try:
        result = subprocess.run([sys.executable, 'analyze_recent_events.py'], 
                              capture_output=True, text=True, timeout=30)
        
        if result.returncode == 0:
            print("[OK] Recent events analysis completed successfully")
            print("Output preview:")
            lines = result.stdout.split('\n')
            for line in lines[:10]:  # Show first 10 lines
                print(f"  {line}")
            return True
        else:
            print(f"[ERROR] Enhanced recent events analysis failed: {result.stderr}")
            return False
    except Exception as e:
        print(f"[ERROR] Error running recent analysis: {e}")
        return False

def test_file_validation():
    """Test file validation utilities"""
    print("\nTesting file validation...")
    try:
        from log_analysis_utils import validate_csv_files
        file_status = validate_csv_files()
        
        print("File validation results:")
        for file_name, status in file_status.items():
            if status['exists'] and status['readable']:
                print(f"  [OK] {file_name}: {status['rows']} rows")
            else:
                print(f"  [ERROR] {file_name}: {status.get('error', 'Unknown error')}")
        
        return all(status['exists'] and status['readable'] for status in file_status.values())
    except Exception as e:
        print(f"[ERROR] File validation failed: {e}")
        return False

def main():
    """Run all tests"""
    print("Log Analysis Tools - Test Suite")
    print("=" * 50)
    print(f"Test started at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    
    tests = [
        ("Configuration Loading", test_config_loading),
        ("File Validation", test_file_validation),
        ("Export Script", test_export_script),
        ("CSV Analysis", test_csv_analysis),
        ("Recent Analysis", test_recent_analysis)
    ]
    
    results = []
    
    for test_name, test_func in tests:
        print(f"\n{'='*20} {test_name} {'='*20}")
        try:
            success = test_func()
            results.append((test_name, success))
        except Exception as e:
            print(f"[ERROR] Test {test_name} crashed: {e}")
            results.append((test_name, False))
    
    # Summary
    print(f"\n{'='*50}")
    print("TEST SUMMARY")
    print(f"{'='*50}")
    
    passed = sum(1 for _, success in results if success)
    total = len(results)
    
    for test_name, success in results:
        status = "[OK] PASS" if success else "[ERROR] FAIL"
        print(f"{status} {test_name}")
    
    print(f"\nOverall: {passed}/{total} tests passed")
    
    if passed == total:
        print("🎉 All tests passed! Tools are working correctly.")
    else:
        print("[WARNING]️ Some tests failed. Check the output above for details.")
    
    return passed == total

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)

