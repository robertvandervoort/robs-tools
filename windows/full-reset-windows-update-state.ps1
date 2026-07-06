# full-reset-windows-update-state.ps1
# ---------------------------------------------------------------------------
# WHAT IT DOES : Deep reset of Windows Update. Stops update/transfer services,
#                clears BITS jobs + Delivery Optimization cache, RENAMES
#                SoftwareDistribution and catroot2 (to *.bak-<timestamp>),
#                restarts services, forces a fresh scan, re-hides driver offers.
# CHANGES      : Service start-modes (temporarily), registry driver policy,
#                renames two system cache folders. Does NOT touch your files.
# RISK         : Medium. Heavier than repair-windows-update.ps1 - use when a
#                normal repair didn't clear the problem.
# RECOVERY     : The folders are renamed, not deleted - Windows rebuilds fresh
#                ones automatically. Delete the *.bak-<timestamp> copies once
#                updates work again. Create a System Restore point first
#                (see the README "Safety, compatibility & recovery" section).
# TESTED ON    : Windows 11 (64-bit). Relies on usoclient.exe + the
#                Microsoft.Update COM API, which vary by Windows build.
# REQUIRES     : Run as Administrator.
# ---------------------------------------------------------------------------
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Stop-ServiceHostIfNeeded {
    param([string]$ServiceName)

    $service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    if ($null -eq $service -or $service.State -ne "Running" -or $service.ProcessId -eq 0) {
        return
    }

    try {
        Stop-Process -Id $service.ProcessId -Force -ErrorAction Stop
        Write-Host "Terminated host for $ServiceName (PID $($service.ProcessId))"
    } catch {
        Write-Warning "Unable to terminate $ServiceName host: $($_.Exception.Message)"
    }
}

function Convert-StartMode {
    param([string]$StartMode)

    switch ($StartMode) {
        "Auto" { "Automatic" }
        "Manual" { "Manual" }
        "Disabled" { "Disabled" }
        default { "Manual" }
    }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDir = Join-Path $PSScriptRoot "windows-update-repair-logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir "full-reset-$timestamp.log"
Start-Transcript -Path $logPath -Force | Out-Null

try {
    $principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }

    Write-Host "=== Preserve driver exclusion policy ==="
    $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    New-Item -Path $policyPath -Force | Out-Null
    Set-ItemProperty -Path $policyPath -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1
    Get-ItemProperty -Path $policyPath | Select-Object ExcludeWUDriversInQualityUpdate | Format-List

    Write-Host "=== Stop update services ==="
    $temporarilyDisabled = "UsoSvc", "wuauserv", "DoSvc"
    $originalStartModes = @{}
    foreach ($serviceName in $temporarilyDisabled) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            $originalStartModes[$serviceName] = $svc.StartMode
            Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Host "Temporarily disabled $serviceName"
        }
    }

    try {
        $servicesToStop = "UsoSvc", "wuauserv", "bits", "cryptsvc", "DoSvc", "AppIDSvc"
        foreach ($serviceName in $servicesToStop) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -ne $service -and $service.Status -ne "Stopped") {
                Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
                Write-Host "Stopping $serviceName"
            }
        }

        Start-Sleep -Seconds 3

        Stop-ServiceHostIfNeeded -ServiceName "UsoSvc"
        Stop-ServiceHostIfNeeded -ServiceName "wuauserv"
        Stop-ServiceHostIfNeeded -ServiceName "DoSvc"
        Stop-ServiceHostIfNeeded -ServiceName "BITS"
        Stop-ServiceHostIfNeeded -ServiceName "CryptSvc"

        Start-Sleep -Seconds 2

        Write-Host "=== Clear queued transfer state ==="
        try {
            Get-BitsTransfer -AllUsers -ErrorAction Stop | Remove-BitsTransfer -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "Removed all visible BITS jobs"
        } catch {
            Write-Warning "Unable to remove all BITS jobs: $($_.Exception.Message)"
        }

        $downloaderPath = Join-Path $env:ProgramData "Microsoft\Network\Downloader"
        if (Test-Path $downloaderPath) {
            Get-ChildItem -Path $downloaderPath -Filter "qmgr*.dat" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Host "Cleared qmgr*.dat files"
        }

        $doCachePath = Join-Path $env:ProgramData "Microsoft\Windows\DeliveryOptimization\Cache"
        if (Test-Path $doCachePath) {
            Get-ChildItem -Path $doCachePath -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Write-Host "Cleared Delivery Optimization cache"
        }

        Write-Host "=== Reset Windows Update cache folders ==="
        $softwareDistribution = Join-Path $env:SystemRoot "SoftwareDistribution"
        if (Test-Path $softwareDistribution) {
            Rename-Item -Path $softwareDistribution -NewName "SoftwareDistribution.bak-$timestamp" -Force
            Write-Host "Renamed SoftwareDistribution"
        }

        $catroot2 = Join-Path $env:SystemRoot "System32\catroot2"
        if (Test-Path $catroot2) {
            Rename-Item -Path $catroot2 -NewName "catroot2.bak-$timestamp" -Force
            Write-Host "Renamed catroot2"
        }
    } finally {
        foreach ($serviceName in $temporarilyDisabled) {
            if ($originalStartModes.ContainsKey($serviceName)) {
                $startupType = Convert-StartMode -StartMode $originalStartModes[$serviceName]
                Set-Service -Name $serviceName -StartupType $startupType -ErrorAction SilentlyContinue
                Write-Host "Restored $serviceName startup type to $startupType"
            }
        }
    }

    Write-Host "=== Restart core services ==="
    foreach ($serviceName in "cryptsvc", "bits", "wuauserv", "UsoSvc", "DoSvc") {
        Start-Service -Name $serviceName -ErrorAction SilentlyContinue
        Write-Host "Started $serviceName"
    }

    Start-Sleep -Seconds 5
    Get-Service wuauserv, bits, cryptsvc, UsoSvc, DoSvc | Select-Object Name, Status, StartType | Format-Table -AutoSize

    Write-Host "=== Force fresh update scan ==="
    & usoclient RefreshSettings
    Start-Sleep -Seconds 5
    & usoclient StartScan
    Start-Sleep -Seconds 15

    Write-Host "=== Hide driver offers again if rediscovered ==="
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.Online = $true
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0")
    if ($result.Updates.Count -gt 0) {
        foreach ($i in 0..($result.Updates.Count - 1)) {
            $update = $result.Updates.Item($i)
            if ($update.Type -eq 2) {
                $update.IsHidden = $true
                Write-Host ("HIDDEN: {0}" -f $update.Title)
            }
        }
    }

    Write-Host "=== Final visible queue ==="
    $verifySearcher = $session.CreateUpdateSearcher()
    $verifySearcher.Online = $true
    $verifyResult = $verifySearcher.Search("IsInstalled=0 and IsHidden=0")
    $remaining = for ($i = 0; $i -lt $verifyResult.Updates.Count; $i++) {
        $u = $verifyResult.Updates.Item($i)
        [pscustomobject]@{
            Title        = $u.Title
            Type         = $u.Type
            IsHidden     = $u.IsHidden
            IsDownloaded = $u.IsDownloaded
            AutoSelect   = $u.AutoSelectOnWebSites
        }
    }

    if ($remaining) {
        $remaining | Format-List
    } else {
        Write-Host "No remaining visible updates."
    }
} finally {
    Stop-Transcript | Out-Null
}
