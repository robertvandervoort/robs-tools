# disable-windows-update-drivers.ps1
# ---------------------------------------------------------------------------
# WHAT IT DOES : Stops Windows Update from offering driver updates - sets the
#                ExcludeWUDriversInQualityUpdate policy and hides any driver
#                updates currently on offer.
# CHANGES      : One registry policy value + hides offered driver updates.
# RISK         : Low and fully reversible.
# RECOVERY     : Run enable-driver-suggestions.ps1 to undo.
# NOTE         : Don't use on employer/school/MDM/WSUS-managed PCs - it changes
#                update policy. Tested on Windows 11 (64-bit).
# REQUIRES     : Run as Administrator.
# ---------------------------------------------------------------------------
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDir = Join-Path $PSScriptRoot "windows-update-repair-logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir "disable-drivers-$timestamp.log"
Start-Transcript -Path $logPath -Force | Out-Null

try {
    $principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }

    Write-Host "=== Set Windows Update driver exclusion policy ==="
    $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    New-Item -Path $policyPath -Force | Out-Null
    Set-ItemProperty -Path $policyPath -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1
    Get-ItemProperty -Path $policyPath | Select-Object ExcludeWUDriversInQualityUpdate | Format-List

    Write-Host "=== Hide currently offered driver updates ==="
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.Online = $true
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0")

    $hiddenTitles = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $result.Updates.Count; $i++) {
        $update = $result.Updates.Item($i)
        if ($update.Type -eq 2) {
            $update.IsHidden = $true
            $hiddenTitles.Add($update.Title) | Out-Null
            Write-Host ("HIDDEN: {0}" -f $update.Title)
        }
    }

    if ($hiddenTitles.Count -eq 0) {
        Write-Host "No visible driver updates needed hiding."
    }

    Write-Host "=== Refresh Windows Update view ==="
    & usoclient RefreshSettings
    Start-Sleep -Seconds 5
    & usoclient StartScan
    Start-Sleep -Seconds 10

    $verifySearcher = $session.CreateUpdateSearcher()
    $verifySearcher.Online = $true
    $verifyResult = $verifySearcher.Search("IsInstalled=0 and IsHidden=0")
    $remaining = for ($i = 0; $i -lt $verifyResult.Updates.Count; $i++) {
        $u = $verifyResult.Updates.Item($i)
        [pscustomobject]@{
            Title      = $u.Title
            Type       = $u.Type
            IsHidden   = $u.IsHidden
            AutoSelect = $u.AutoSelectOnWebSites
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
