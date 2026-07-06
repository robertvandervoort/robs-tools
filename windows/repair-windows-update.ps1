# repair-windows-update.ps1
# ---------------------------------------------------------------------------
# WHAT IT DOES : First-responder Windows Update repair. Resets update services
#                and caches (renames SoftwareDistribution + catroot2), repairs
#                the servicing stack with DISM /RestoreHealth and sfc /scannow,
#                then searches/downloads/installs pending SOFTWARE updates
#                (drivers are deferred), and prints recent update history.
# CHANGES      : Service start-modes (temporarily), renames two system cache
#                folders. Does NOT touch your files.
# RISK         : Medium. This is the one to try first.
# RECOVERY     : Folders are renamed, not deleted - Windows rebuilds them;
#                delete the *.bak-<timestamp> copies once updates work. Take a
#                System Restore point first (see README safety section).
# TESTED ON    : Windows 11 (64-bit). Uses DISM/SFC and the Microsoft.Update
#                COM API; details vary by Windows build.
# REQUIRES     : Run as Administrator. DISM/SFC can take 10-30+ minutes.
# ---------------------------------------------------------------------------
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Invoke-LoggedProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-Host "Running: $FilePath $($ArgumentList -join ' ')"
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -NoNewWindow -PassThru
    Write-Host "Exit code: $($process.ExitCode)"
    if ($AllowedExitCodes -notcontains $process.ExitCode) {
        throw "$FilePath failed with exit code $($process.ExitCode)."
    }
}

function Stop-ServiceHostIfNeeded {
    param([string]$ServiceName)

    $service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    if ($null -eq $service -or $service.State -ne "Running" -or $service.ProcessId -eq 0) {
        return
    }

    Write-Warning "$ServiceName is still running; terminating PID $($service.ProcessId)."
    try {
        Stop-Process -Id $service.ProcessId -Force -ErrorAction Stop
    } catch {
        Write-Warning "Unable to terminate $ServiceName (PID $($service.ProcessId)): $($_.Exception.Message)"
    }
}

function Convert-StartMode {
    param([string]$StartMode)

    switch ($StartMode) {
        "Auto" { return "Automatic" }
        "Manual" { return "Manual" }
        "Disabled" { return "Disabled" }
        default { return "Manual" }
    }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDir = Join-Path $PSScriptRoot "windows-update-repair-logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir "repair-$timestamp.log"
Start-Transcript -Path $logPath -Force | Out-Null

try {
    $principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }

    Write-Step "Environment"
    Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber | Format-List
    Get-Service wuauserv, bits, cryptsvc, UsoSvc, DoSvc, TrustedInstaller | Select-Object Name, Status, StartType | Format-Table -AutoSize

    Write-Step "Reset Windows Update services and cache"
    $temporarilyDisabled = "UsoSvc", "wuauserv", "DoSvc"
    $originalStartModes = @{}

    foreach ($serviceName in $temporarilyDisabled) {
        $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            $originalStartModes[$serviceName] = $service.StartMode
            Write-Host "Temporarily disabling $serviceName"
            Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }

    try {
        $servicesToStop = "UsoSvc", "wuauserv", "bits", "cryptsvc", "DoSvc", "AppIDSvc"
        foreach ($serviceName in $servicesToStop) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -ne $service -and $service.Status -ne "Stopped") {
                Write-Host "Stopping $serviceName"
                Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            }
        }

        Start-Sleep -Seconds 3

        foreach ($serviceName in $servicesToStop) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -ne $service) {
                try {
                    $service.WaitForStatus("Stopped", "00:00:20")
                } catch {
                    Write-Warning "$serviceName did not fully stop before timeout."
                }
            }
        }

        Stop-ServiceHostIfNeeded -ServiceName "UsoSvc"
        Stop-ServiceHostIfNeeded -ServiceName "wuauserv"
        Stop-ServiceHostIfNeeded -ServiceName "DoSvc"
        Stop-ServiceHostIfNeeded -ServiceName "BITS"

        Start-Sleep -Seconds 2

        try {
            $bitsJobs = Get-BitsTransfer -AllUsers -ErrorAction Stop
            if ($bitsJobs) {
                Write-Host "Removing stale BITS jobs"
                $bitsJobs | Remove-BitsTransfer -Confirm:$false -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warning "Unable to enumerate all BITS jobs: $($_.Exception.Message)"
        }

        $softwareDistribution = Join-Path $env:SystemRoot "SoftwareDistribution"
        $softwareDistributionBackup = "SoftwareDistribution.bak-$timestamp"
        if (Test-Path $softwareDistribution) {
            Write-Host "Renaming $softwareDistribution"
            Rename-Item -Path $softwareDistribution -NewName $softwareDistributionBackup -Force
        }

        $catroot2 = Join-Path $env:SystemRoot "System32\catroot2"
        $catroot2Backup = "catroot2.bak-$timestamp"
        if (Test-Path $catroot2) {
            Write-Host "Renaming $catroot2"
            Rename-Item -Path $catroot2 -NewName $catroot2Backup -Force
        }
    } finally {
        foreach ($serviceName in $temporarilyDisabled) {
            if ($originalStartModes.ContainsKey($serviceName)) {
                $startupType = Convert-StartMode -StartMode $originalStartModes[$serviceName]
                Write-Host "Restoring $serviceName startup type to $startupType"
                Set-Service -Name $serviceName -StartupType $startupType -ErrorAction SilentlyContinue
            }
        }
    }

    $servicesToStart = "cryptsvc", "bits", "wuauserv", "UsoSvc", "DoSvc"
    foreach ($serviceName in $servicesToStart) {
        Write-Host "Starting $serviceName"
        Start-Service -Name $serviceName -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 3
    Get-Service wuauserv, bits, cryptsvc, UsoSvc, DoSvc | Select-Object Name, Status, StartType | Format-Table -AutoSize

    Write-Step "Repair servicing stack"
    Invoke-LoggedProcess -FilePath "DISM.exe" -ArgumentList @("/Online", "/Cleanup-Image", "/ScanHealth")
    Invoke-LoggedProcess -FilePath "DISM.exe" -ArgumentList @("/Online", "/Cleanup-Image", "/RestoreHealth")
    Invoke-LoggedProcess -FilePath "sfc.exe" -ArgumentList @("/scannow") -AllowedExitCodes @(0, 1)

    Write-Step "Search for pending updates"
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")

    $softwareUpdates = New-Object -ComObject Microsoft.Update.UpdateColl
    $driverTitles = [System.Collections.Generic.List[string]]::new()

    for ($index = 0; $index -lt $searchResult.Updates.Count; $index++) {
        $update = $searchResult.Updates.Item($index)
        if (-not $update.EulaAccepted) {
            $update.AcceptEula()
        }

        # IUpdate.Type is an integer enum: 1 = Software, 2 = Driver.
        if ($update.Type -eq 1) {
            [void] $softwareUpdates.Add($update)
        } elseif ($update.Type -eq 2) {
            $driverTitles.Add($update.Title) | Out-Null
        }
    }

    Write-Host "Software updates found: $($softwareUpdates.Count)"
    if ($driverTitles.Count -gt 0) {
        Write-Host "Driver updates deferred for now:"
        $driverTitles | ForEach-Object { Write-Host " - $_" }
    }

    if ($softwareUpdates.Count -gt 0) {
        Write-Step "Download software updates"
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $softwareUpdates
        $downloadResult = $downloader.Download()
        Write-Host "Download result code: $($downloadResult.ResultCode)"
        Write-Host "Download HResult: $('{0:X8}' -f ($downloadResult.HResult -band 0xffffffff))"

        $downloadedUpdates = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($index = 0; $index -lt $softwareUpdates.Count; $index++) {
            $update = $softwareUpdates.Item($index)
            if ($update.IsDownloaded) {
                [void] $downloadedUpdates.Add($update)
            } else {
                Write-Warning "Not downloaded: $($update.Title)"
            }
        }

        Write-Host "Software updates downloaded: $($downloadedUpdates.Count)"
        if ($downloadedUpdates.Count -gt 0) {
            Write-Step "Install downloaded software updates"
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $downloadedUpdates
            $installResult = $installer.Install()
            Write-Host "Install result code: $($installResult.ResultCode)"
            Write-Host "Install HResult: $('{0:X8}' -f ($installResult.HResult -band 0xffffffff))"
            Write-Host "Reboot required: $($installResult.RebootRequired)"

            for ($index = 0; $index -lt $downloadedUpdates.Count; $index++) {
                $result = $installResult.GetUpdateResult($index)
                Write-Host ("[{0}] {1} => ResultCode={2}; HResult={3}" -f $index, $downloadedUpdates.Item($index).Title, $result.ResultCode, ('{0:X8}' -f ($result.HResult -band 0xffffffff)))
            }
        }
    } else {
        Write-Host "No software updates were pending after repair."
    }

    Write-Step "Post-repair update history"
    $historyCount = $searcher.GetTotalHistoryCount()
    $searcher.QueryHistory(0, [Math]::Min($historyCount, 15)) | Select-Object Date, Title, Operation, ResultCode, HResult | Format-List

    Write-Step "Completed"
    Write-Host "Repair log saved to $logPath"
} finally {
    Stop-Transcript | Out-Null
}
