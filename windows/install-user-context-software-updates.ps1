# install-user-context-software-updates.ps1
# ---------------------------------------------------------------------------
# WHAT IT DOES : Triggers a scan (usoclient), then downloads and INSTALLS
#                pending SOFTWARE updates via the COM API; drivers are deferred
#                (listed, not installed).
# CHANGES      : Installs updates WITHOUT further prompting; may require reboot.
# RISK         : Medium - a bad update can misbehave.
# RECOVERY     : Settings > Windows Update > Update history > Uninstall updates.
#                Take a System Restore point first (see README safety section).
# NOTE         : Overlaps with install-pending-software-now.ps1 (which avoids
#                the usoclient scan race). If keeping just one, keep that.
# TESTED ON    : Windows 11 (64-bit). Uses usoclient + Microsoft.Update COM API.
# REQUIRES     : Run as Administrator.
# ---------------------------------------------------------------------------
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDir = Join-Path $PSScriptRoot "windows-update-repair-logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir "install-user-$timestamp.log"
Start-Transcript -Path $logPath -Force | Out-Null

try {
    Write-Host "=== Trigger scan ==="
    & usoclient StartScan
    Start-Sleep -Seconds 15

    Write-Host "=== Search for software updates ==="
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.Online = $true
    $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")

    $softwareUpdates = New-Object -ComObject Microsoft.Update.UpdateColl
    $driverTitles = [System.Collections.Generic.List[string]]::new()

    for ($index = 0; $index -lt $searchResult.Updates.Count; $index++) {
        $update = $searchResult.Updates.Item($index)
        if (-not $update.EulaAccepted) {
            $update.AcceptEula()
        }

        if ($update.Type -eq 1) {
            [void] $softwareUpdates.Add($update)
            Write-Host ("SOFTWARE: {0}" -f $update.Title)
        } elseif ($update.Type -eq 2) {
            $driverTitles.Add($update.Title) | Out-Null
        }
    }

    if ($driverTitles.Count -gt 0) {
        Write-Host "=== Driver updates deferred ==="
        $driverTitles | ForEach-Object { Write-Host "DRIVER: $_" }
    }

    if ($softwareUpdates.Count -eq 0) {
        Write-Host "No software updates pending."
        return
    }

    Write-Host "=== Download software updates ==="
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
        Write-Host "No software updates downloaded."
        return
    }

    Write-Host "=== Install downloaded software updates ==="
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $downloadedUpdates
    $installResult = $installer.Install()
    Write-Host "Install ResultCode: $($installResult.ResultCode)"
    Write-Host "Install HResult: $('{0:X8}' -f ($installResult.HResult -band 0xffffffff))"
    Write-Host "RebootRequired: $($installResult.RebootRequired)"

    for ($index = 0; $index -lt $downloadedUpdates.Count; $index++) {
        $update = $downloadedUpdates.Item($index)
        $result = $installResult.GetUpdateResult($index)
        Write-Host ("RESULT: {0} => ResultCode={1}; HResult={2}" -f $update.Title, $result.ResultCode, ('{0:X8}' -f ($result.HResult -band 0xffffffff)))
    }
} finally {
    Stop-Transcript | Out-Null
}
