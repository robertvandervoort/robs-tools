# repair-delivery-optimization.ps1
# ---------------------------------------------------------------------------
# WHAT IT DOES : Fixes updates that download to 0% / no-progress (0x80D0xxxx)
#                caused by Delivery Optimization picking the wrong network path.
#                Forces DO to HTTP-only (no peering), RAISES the interface
#                metric of connected NICs that have no default gateway (so a
#                VPN/SAN link can't be chosen as the source), clears BITS/DO/
#                download caches, then retries the software download + install.
# CHANGES      : DO download mode (registry/cmdlet), interface metrics of
#                gateway-less NICs, service start-modes (temporarily).
# RISK         : Medium. The NIC metric change affects routing preference.
# RECOVERY     : Restore DO with  Set-DODownloadMode -DownloadMode 1  (or 3).
#                Restore a NIC to automatic metric with
#                  Set-NetIPInterface -InterfaceAlias "<name>" -AutomaticMetric Enabled
#                (list adapters with Get-NetIPInterface). See README safety section.
# TESTED ON    : Windows 11 (64-bit). Uses DO cmdlets + Microsoft.Update COM API.
# REQUIRES     : Run as Administrator.
# ---------------------------------------------------------------------------
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDir = Join-Path $PSScriptRoot "windows-update-repair-logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir "repair-do-$timestamp.log"
Start-Transcript -Path $logPath -Force | Out-Null

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

try {
    $principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }

    Write-Step "Baseline"
    Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber | Format-List
    try { "Original DODownloadMode: " + (Get-DODownloadMode).DownloadMode } catch { Write-Warning "Get-DODownloadMode failed: $($_.Exception.Message)" }

    Write-Step "Force Delivery Optimization to HTTP-only (no peering)"
    # Mode 0 = HTTP only, no peering. Rules out peer/interface selection issues
    # (e.g. a VPN tunnel or an isolated storage/SAN link being picked as the source).
    try {
        Set-DODownloadMode -DownloadMode 0 -ErrorAction Stop
        "New DODownloadMode: " + (Get-DODownloadMode).DownloadMode
    } catch {
        Write-Warning "Set-DODownloadMode failed, falling back to registry: $($_.Exception.Message)"
        $doConfig = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config"
        New-Item -Path $doConfig -Force | Out-Null
        Set-ItemProperty -Path $doConfig -Name "DODownloadMode" -Type DWord -Value 0
    }

    Write-Step "Ensure internet NIC is preferred over non-routable NICs"
    # Delivery Optimization selects its own source interface. If a non-routable NIC
    # (e.g. an isolated SAN/storage link) has a LOWER interface metric than the real
    # internet NIC, DO can bind to it and stall at 0 bytes (0x80D02002 no-progress).
    # Raise the metric of any connected IPv4 interface that has NO default gateway
    # so it sits above every gateway-bearing interface.
    $gatewayMetrics = @()
    Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.ConnectionState -eq 'Connected' } |
        ForEach-Object {
            $hasGw = [bool](Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue)
            if ($hasGw) { $gatewayMetrics += $_.InterfaceMetric }
        }
    $maxGwMetric = if ($gatewayMetrics.Count -gt 0) { ($gatewayMetrics | Measure-Object -Maximum).Maximum } else { 25 }
    Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.ConnectionState -eq 'Connected' -and $_.InterfaceAlias -ne 'Loopback Pseudo-Interface 1' } |
        ForEach-Object {
            $hasGw = [bool](Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue)
            if (-not $hasGw -and $_.InterfaceMetric -le $maxGwMetric) {
                $newMetric = $maxGwMetric + 20
                Write-Host ("Raising metric of non-routable NIC '{0}' from {1} to {2}" -f $_.InterfaceAlias, $_.InterfaceMetric, $newMetric)
                Set-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -InterfaceMetric $newMetric -ErrorAction SilentlyContinue
            }
        }
    Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ConnectionState -eq 'Connected' } | Select-Object InterfaceAlias, InterfaceMetric | Sort-Object InterfaceMetric | Format-Table -AutoSize

    Write-Step "Stop update + transfer services"
    $temporarilyDisabled = "UsoSvc", "wuauserv", "DoSvc"
    $originalStartModes = @{}
    foreach ($serviceName in $temporarilyDisabled) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            $originalStartModes[$serviceName] = $svc.StartMode
            Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }

    try {
        foreach ($serviceName in "UsoSvc", "wuauserv", "bits", "DoSvc") {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -ne $service -and $service.Status -ne "Stopped") {
                Write-Host "Stopping $serviceName"
                Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Seconds 3

        Write-Step "Clear stale BITS jobs and queue"
        try {
            Get-BitsTransfer -AllUsers -ErrorAction Stop | Remove-BitsTransfer -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "Removed visible BITS jobs"
        } catch {
            Write-Warning "Unable to remove all BITS jobs: $($_.Exception.Message)"
        }

        $downloaderPath = Join-Path $env:ProgramData "Microsoft\Network\Downloader"
        if (Test-Path $downloaderPath) {
            Get-ChildItem -Path $downloaderPath -Filter "qmgr*.dat" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Host "Cleared qmgr*.dat files"
        }

        Write-Step "Reset Delivery Optimization cache"
        $doProgData = Join-Path $env:ProgramData "Microsoft\Windows\DeliveryOptimization"
        if (Test-Path $doProgData) {
            Get-ChildItem -Path $doProgData -Force -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Write-Host "Cleared $doProgData"
        } else {
            Write-Host "$doProgData not present (will be recreated by DoSvc)"
        }

        Write-Step "Clear pending Windows Update download payloads"
        $dlPath = Join-Path $env:SystemRoot "SoftwareDistribution\Download"
        if (Test-Path $dlPath) {
            Get-ChildItem -Path $dlPath -Force -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Write-Host "Cleared $dlPath"
        }
    } finally {
        foreach ($serviceName in $temporarilyDisabled) {
            if ($originalStartModes.ContainsKey($serviceName)) {
                $startupType = switch ($originalStartModes[$serviceName]) {
                    "Auto" { "Automatic" }
                    "Manual" { "Manual" }
                    "Disabled" { "Disabled" }
                    default { "Manual" }
                }
                Set-Service -Name $serviceName -StartupType $startupType -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Step "Restart services"
    foreach ($serviceName in "cryptsvc", "bits", "DoSvc", "wuauserv", "UsoSvc") {
        Start-Service -Name $serviceName -ErrorAction SilentlyContinue
        Write-Host "Started $serviceName"
    }
    Start-Sleep -Seconds 5
    Get-Service wuauserv, bits, cryptsvc, UsoSvc, DoSvc | Select-Object Name, Status, StartType | Format-Table -AutoSize

    Write-Step "Scan for software updates (clean COM, with retry)"
    $session = New-Object -ComObject Microsoft.Update.Session
    $searchResult = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $searcher = $session.CreateUpdateSearcher()
        $searcher.Online = $true
        $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")
        Write-Host ("Attempt {0}: {1} updates returned" -f $attempt, $searchResult.Updates.Count)
        if ($searchResult.Updates.Count -gt 0) { break }
        Start-Sleep -Seconds 15
    }

    $softwareUpdates = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($index = 0; $index -lt $searchResult.Updates.Count; $index++) {
        $update = $searchResult.Updates.Item($index)
        if (-not $update.EulaAccepted) { $update.AcceptEula() }
        # IUpdate.Type is an integer enum: 1 = Software, 2 = Driver.
        if ($update.Type -eq 1) {
            [void] $softwareUpdates.Add($update)
            Write-Host ("SOFTWARE: {0}" -f $update.Title)
        } elseif ($update.Type -eq 2) {
            Write-Host ("DRIVER (skipped): {0}" -f $update.Title)
        }
    }

    if ($softwareUpdates.Count -eq 0) {
        Write-Host "No software updates pending after reset."
        return
    }

    Write-Step "Download software updates (DO HTTP-only)"
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $softwareUpdates
    $downloadResult = $downloader.Download()
    Write-Host "Download ResultCode: $($downloadResult.ResultCode)"
    Write-Host "Download HResult: $('{0:X8}' -f ($downloadResult.HResult -band 0xffffffff))"

    $downloadedUpdates = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($index = 0; $index -lt $softwareUpdates.Count; $index++) {
        $update = $softwareUpdates.Item($index)
        if ($update.IsDownloaded) {
            [void] $downloadedUpdates.Add($update)
            Write-Host ("DOWNLOADED: {0}" -f $update.Title)
        } else {
            Write-Warning ("NOT DOWNLOADED: {0}" -f $update.Title)
        }
    }

    if ($downloadedUpdates.Count -eq 0) {
        Write-Host "No updates downloaded; DO reset did not resolve the failure. Fall back to manual .msu install."
        return
    }

    Write-Step "Install downloaded software updates"
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $downloadedUpdates
    $installResult = $installer.Install()
    Write-Host "Install ResultCode: $($installResult.ResultCode)"
    Write-Host "Install HResult: $('{0:X8}' -f ($installResult.HResult -band 0xffffffff))"
    Write-Host "RebootRequired: $($installResult.RebootRequired)"

    for ($index = 0; $index -lt $downloadedUpdates.Count; $index++) {
        $result = $installResult.GetUpdateResult($index)
        Write-Host ("RESULT: {0} => ResultCode={1}; HResult={2}" -f $downloadedUpdates.Item($index).Title, $result.ResultCode, ('{0:X8}' -f ($result.HResult -band 0xffffffff)))
    }

    Write-Step "Completed"
    Write-Host "Repair log saved to $logPath"
} finally {
    Stop-Transcript | Out-Null
}
