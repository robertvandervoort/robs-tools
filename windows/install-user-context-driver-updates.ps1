# install-user-context-driver-updates.ps1
# ---------------------------------------------------------------------------
# WHAT IT DOES : Searches for and INSTALLS pending DRIVER updates via the
#                Windows Update COM API.
# CHANGES      : Installs drivers WITHOUT further prompting; may require reboot.
# RISK         : Medium - a bad driver can cause device/boot issues.
# RECOVERY     : Roll back in Device Manager (device > Properties > Driver >
#                Roll Back Driver). Take a System Restore point first
#                (see README safety section).
# TESTED ON    : Windows 11 (64-bit). Uses the Microsoft.Update COM API.
# REQUIRES     : Run as Administrator.
# ---------------------------------------------------------------------------
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDir = Join-Path $PSScriptRoot "windows-update-repair-logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir "install-drivers-$timestamp.log"
Start-Transcript -Path $logPath -Force | Out-Null

try {
    Write-Host "=== Trigger scan ==="
    & usoclient StartScan
    Start-Sleep -Seconds 15

    Write-Host "=== Search for driver updates ==="
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.Online = $true
    $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")

    $driverUpdates = New-Object -ComObject Microsoft.Update.UpdateColl

    for ($index = 0; $index -lt $searchResult.Updates.Count; $index++) {
        $update = $searchResult.Updates.Item($index)
        if ($update.Type -eq 2) {
            if (-not $update.EulaAccepted) {
                $update.AcceptEula()
            }
            [void] $driverUpdates.Add($update)
            Write-Host ("DRIVER: {0}" -f $update.Title)
        }
    }

    if ($driverUpdates.Count -eq 0) {
        Write-Host "No driver updates pending."
        return
    }

    Write-Host "=== Download driver updates ==="
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $driverUpdates
    $downloadResult = $downloader.Download()
    Write-Host "Download ResultCode: $($downloadResult.ResultCode)"
    Write-Host "Download HResult: $('{0:X8}' -f ($downloadResult.HResult -band 0xffffffff))"

    $downloadedUpdates = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($index = 0; $index -lt $driverUpdates.Count; $index++) {
        $update = $driverUpdates.Item($index)
        if ($update.IsDownloaded) {
            [void] $downloadedUpdates.Add($update)
            Write-Host ("DOWNLOADED: {0}" -f $update.Title)
        } else {
            Write-Warning ("NOT DOWNLOADED: {0}" -f $update.Title)
        }
    }

    if ($downloadedUpdates.Count -eq 0) {
        Write-Host "No driver updates downloaded."
        return
    }

    Write-Host "=== Install downloaded driver updates ==="
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
