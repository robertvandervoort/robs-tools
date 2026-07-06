# install-pending-software-now.ps1
# ---------------------------------------------------------------------------
# WHAT IT DOES : Immediately downloads and INSTALLS pending SOFTWARE updates
#                via the Windows Update COM API (drivers are skipped). Uses a
#                clean COM search with retry to dodge the flaky usoclient scan
#                race that can return 0 updates.
# CHANGES      : Installs updates WITHOUT further prompting; may require reboot.
# RISK         : Medium - a bad update can misbehave.
# RECOVERY     : Settings > Windows Update > Update history > Uninstall updates.
#                Take a System Restore point first (see README safety section).
# TESTED ON    : Windows 11 (64-bit). Uses the Microsoft.Update COM API.
# REQUIRES     : Run as Administrator.
# ---------------------------------------------------------------------------
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDir = Join-Path $PSScriptRoot "windows-update-repair-logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir "install-now-$timestamp.log"
Start-Transcript -Path $logPath -Force | Out-Null

try {
    $principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }

    $session = New-Object -ComObject Microsoft.Update.Session

    # Clean COM online search WITHOUT a usoclient StartScan preamble (the preamble
    # races the COM searcher and intermittently returns 0). Retry a few times to
    # ride out any transient empty result.
    Write-Host "=== Search for software updates (clean COM, with retry) ==="
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
            Write-Host ("DRIVER (skipped per policy): {0}" -f $update.Title)
        }
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
        Write-Host "No updates downloaded. The 0x80D03805 download failure likely persists; fall back to manual .msu."
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
        $result = $installResult.GetUpdateResult($index)
        Write-Host ("RESULT: {0} => ResultCode={1}; HResult={2}" -f $downloadedUpdates.Item($index).Title, $result.ResultCode, ('{0:X8}' -f ($result.HResult -band 0xffffffff)))
    }
} finally {
    Stop-Transcript | Out-Null
}
