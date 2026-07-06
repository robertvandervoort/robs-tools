# PowerShell script to export Windows events to CSV for Python analysis
# Supports configurable time ranges and additional event types

param(
    [int]$HoursBack = 12,
    [string]$SystemFile = "system_events.csv",
    [string]$AppFile = "app_events.csv",
    [switch]$IncludeSecurity = $false,
    [switch]$Verbose = $false
)

# Load configuration if available
$configFile = "log_analysis_config.json"
$config = @{}

if (Test-Path $configFile) {
    try {
        $config = Get-Content $configFile | ConvertFrom-Json
        if ($config.time_ranges.export_hours) {
            $HoursBack = $config.time_ranges.export_hours
        }
        Write-Host "Loaded configuration from $configFile" -ForegroundColor Green
    } catch {
        Write-Host "Warning: Could not load config file, using defaults" -ForegroundColor Yellow
    }
}

Write-Host "Windows Event Export Tool" -ForegroundColor Green
Write-Host "=========================" -ForegroundColor Green
Write-Host ""

$startTime = (Get-Date).AddHours(-$HoursBack)
Write-Host "Exporting events from: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host "Exporting events to: $(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host ""

# Function to safely export events
function Export-EventLog {
    param(
        [string]$LogName,
        [string]$OutputFile,
        [string]$Description
    )
    
    try {
        Write-Host "Exporting $Description..." -ForegroundColor Yellow
        
        $events = Get-WinEvent -FilterHashtable @{LogName=$LogName; StartTime=$startTime} -ErrorAction Stop | 
            Select-Object TimeCreated, Id, LevelDisplayName, @{Name='Message';Expression={$_.Message -replace "`n", " " -replace "`r", " "}} |
            Sort-Object TimeCreated
        
        if ($events) {
            $events | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
            Write-Host "Exported $($events.Count) $Description to $OutputFile" -ForegroundColor Green
            
            if ($Verbose) {
                # Show event breakdown by level
                $levelCounts = $events | Group-Object LevelDisplayName | Sort-Object Count -Descending
                foreach ($level in $levelCounts) {
                    Write-Host "  $($level.Name): $($level.Count)" -ForegroundColor Gray
                }
            }
        } else {
            Write-Host "No $Description found in the specified time range" -ForegroundColor Yellow
            # Create empty CSV with headers
            $emptyEvents = @() | Select-Object TimeCreated, Id, LevelDisplayName, Message
            $emptyEvents | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
        }
        
        return $events.Count
    } catch {
        Write-Host "Error exporting $Description : $($_.Exception.Message)" -ForegroundColor Red
        return 0
    }
}

# Export System events
$systemCount = Export-EventLog -LogName "System" -OutputFile $SystemFile -Description "System events"

# Export Application events  
$appCount = Export-EventLog -LogName "Application" -OutputFile $AppFile -Description "Application events"

# Export Security events if requested
$securityCount = 0
if ($IncludeSecurity) {
    $securityCount = Export-EventLog -LogName "Security" -OutputFile "security_events.csv" -Description "Security events"
}

# Export Setup events (Windows updates, installations)
$setupCount = Export-EventLog -LogName "Setup" -OutputFile "setup_events.csv" -Description "Setup events"

# Summary
Write-Host ""
Write-Host "Export Summary" -ForegroundColor Green
Write-Host "=============" -ForegroundColor Green
Write-Host "System Events: $systemCount" -ForegroundColor White
Write-Host "Application Events: $appCount" -ForegroundColor White
if ($IncludeSecurity) {
    Write-Host "Security Events: $securityCount" -ForegroundColor White
}
Write-Host "Setup Events: $setupCount" -ForegroundColor White
Write-Host "Total Events: $($systemCount + $appCount + $securityCount + $setupCount)" -ForegroundColor Cyan

# Check for critical events in the exported data
Write-Host ""
Write-Host "Quick Critical Event Check" -ForegroundColor Yellow
Write-Host "==========================" -ForegroundColor Yellow

$criticalEventIds = @(41, 6008, 46, 1074, 1076)
$criticalCount = 0

if (Test-Path $SystemFile) {
    $systemData = Import-Csv $SystemFile
    foreach ($eventId in $criticalEventIds) {
        $count = ($systemData | Where-Object { $_.Id -eq $eventId }).Count
        if ($count -gt 0) {
            Write-Host "Event ID $eventId : $count occurrences" -ForegroundColor Red
            $criticalCount += $count
        }
    }
}

if ($criticalCount -eq 0) {
    Write-Host "No critical events found in the exported data" -ForegroundColor Green
} else {
    Write-Host "Found $criticalCount critical events - analysis recommended" -ForegroundColor Red
}

Write-Host ""
Write-Host "Export complete! Files ready for analysis." -ForegroundColor Green
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  python analyze_critical_events.py" -ForegroundColor White
Write-Host "  python analyze_recent_events.py" -ForegroundColor White
