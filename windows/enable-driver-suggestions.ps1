# enable-driver-suggestions.ps1
# ---------------------------------------------------------------------------
# WHAT IT DOES : Re-enables Windows Update driver offers by clearing the
#                ExcludeWUDriversInQualityUpdate policy, then rescans. Drivers
#                appear as reviewable suggestions - it does NOT force installs.
# CHANGES      : Removes one registry policy value.
# RISK         : Low and fully reversible.
# RECOVERY     : Run disable-windows-update-drivers.ps1 to undo.
# NOTE         : Don't use on employer/school/MDM/WSUS-managed PCs. Tested on
#                Windows 11 (64-bit).
# REQUIRES     : Run as Administrator.
# ---------------------------------------------------------------------------
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDir = Join-Path $PSScriptRoot "windows-update-repair-logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir "enable-driver-suggestions-$timestamp.log"
Start-Transcript -Path $logPath -Force | Out-Null

try {
    $principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }

    Write-Host "=== Clear driver exclusion policy (re-enable driver suggestions) ==="
    # ExcludeWUDriversInQualityUpdate=1 suppresses ALL driver offers. Remove it so
    # drivers are suggested again. Auto-install is NOT forced (no AUOptions policy),
    # so drivers appear as reviewable suggestions, not silent installs.
    $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    if (Test-Path $policyPath) {
        Remove-ItemProperty -Path $policyPath -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
        Write-Host "Removed ExcludeWUDriversInQualityUpdate (was previously = 1)"
    } else {
        Write-Host "WindowsUpdate policy key not present; nothing to remove."
    }

    Write-Host "=== Effective policy now ==="
    Get-ItemProperty -Path $policyPath -ErrorAction SilentlyContinue | Select-Object * -ExcludeProperty PS* | Format-List

    Write-Host "=== Refresh and scan (so driver offers repopulate) ==="
    & usoclient RefreshSettings
    Start-Sleep -Seconds 5
    & usoclient StartScan
    Start-Sleep -Seconds 15

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

    Write-Host "=== Pending updates now ==="
    for ($index = 0; $index -lt $searchResult.Updates.Count; $index++) {
        $update = $searchResult.Updates.Item($index)
        # IUpdate.Type: 1 = Software, 2 = Driver.
        $typeLabel = if ($update.Type -eq 2) { "DRIVER" } elseif ($update.Type -eq 1) { "Software" } else { "Type=$($update.Type)" }
        Write-Host ("[{0}] {1}" -f $typeLabel, $update.Title)
    }
} finally {
    Stop-Transcript | Out-Null
}
