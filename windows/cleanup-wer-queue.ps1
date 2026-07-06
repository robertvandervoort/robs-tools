# Windows Error Reporting (WER) Queue Cleanup - v2 (aggressive)
# Wipes ALL pending WER reports including SYSTEM-profile and service-account dirs.
# Uses takeown/icacls to break through ACL restrictions on SYSTEM-owned reports.
# Also clears WER's registry-tracked retry queue.
# Does NOT disable WER - the service remains available for future crash tracking.
# Run this in an ELEVATED PowerShell window
# (Right-click PowerShell -> Run as Administrator)

# Self-elevation guard
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator', then re-run this script." -ForegroundColor Yellow
    exit 1
}

Write-Host "=== Windows Error Reporting Queue Cleanup (v2 - aggressive) ===" -ForegroundColor Cyan
Write-Host ""

function Force-RemoveDir {
    param(
        [string]$Path,
        [string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        return @{ Deleted = 0; Remaining = 0; Note = "(does not exist)" }
    }

    # First pass: try plain remove
    $itemsBefore = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    if ($itemsBefore.Count -eq 0) {
        return @{ Deleted = 0; Remaining = 0; Note = "(already empty)" }
    }

    foreach ($item in $itemsBefore) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Second pass: takeown + icacls + remove for stragglers
    $itemsAfter = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    if ($itemsAfter.Count -gt 0) {
        Write-Host ("  Stragglers in {0}, applying takeown/icacls..." -f $Label) -ForegroundColor Yellow
        # Take ownership of the directory and everything in it (suppress per-file noise)
        & takeown.exe /f "$Path" /r /d Y *> $null
        & icacls.exe "$Path" /grant "Administrators:(OI)(CI)F" /T /C /Q *> $null

        # Try removal again
        foreach ($item in $itemsAfter) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $itemsFinal = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    $deleted = $itemsBefore.Count - $itemsFinal.Count
    return @{ Deleted = $deleted; Remaining = $itemsFinal.Count; Note = "" }
}

# Step 1: Stop WerSvc
Write-Host "[1/6] Stopping WerSvc temporarily..." -ForegroundColor Yellow
$wasRunning = $false
$svc = Get-Service WerSvc -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    $wasRunning = $true
    Stop-Service -Name WerSvc -Force -ErrorAction SilentlyContinue
    Write-Host "  Stopped (was running)" -ForegroundColor Green
} else {
    Write-Host "  Already stopped" -ForegroundColor Green
}

# Also kill any active werfault/wermgr processes
Get-Process -Name 'WerFault','WerMgr','wermgr','werfault' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  Killing $($_.ProcessName) (PID $($_.Id))" -ForegroundColor Yellow
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

# Step 2: Build complete list of WER directories
Write-Host ""
Write-Host "[2/6] Enumerating WER directories (system + user + service profiles)..." -ForegroundColor Yellow
$werDirs = [System.Collections.Generic.List[string]]::new()

# System-wide
@(
    "C:\ProgramData\Microsoft\Windows\WER\ReportQueue",
    "C:\ProgramData\Microsoft\Windows\WER\ReportArchive",
    "C:\ProgramData\Microsoft\Windows\WER\Temp",
    "C:\ProgramData\Microsoft\Windows\WER\ERC"
) | ForEach-Object { $werDirs.Add($_) }

# SYSTEM account profile
$systemBase = "C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft\Windows\WER"
@("ReportQueue","ReportArchive","Temp") | ForEach-Object { $werDirs.Add((Join-Path $systemBase $_)) }

# 32-bit SYSTEM (SysWOW64) profile
$systemBase32 = "C:\Windows\SysWOW64\config\systemprofile\AppData\Local\Microsoft\Windows\WER"
@("ReportQueue","ReportArchive","Temp") | ForEach-Object { $werDirs.Add((Join-Path $systemBase32 $_)) }

# Service profiles (LocalService, NetworkService)
@("LocalService","NetworkService") | ForEach-Object {
    $base = "C:\Windows\ServiceProfiles\$_\AppData\Local\Microsoft\Windows\WER"
    @("ReportQueue","ReportArchive","Temp") | ForEach-Object { $werDirs.Add((Join-Path $base $_)) }
}

# All user profiles
$userProfiles = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath }
foreach ($prof in $userProfiles) {
    $base = Join-Path $prof.LocalPath "AppData\Local\Microsoft\Windows\WER"
    @("ReportQueue","ReportArchive","Temp") | ForEach-Object { $werDirs.Add((Join-Path $base $_)) }
}

$werDirs = $werDirs | Sort-Object -Unique
Write-Host ("  Total WER directories to check: $($werDirs.Count)") -ForegroundColor Cyan

# Step 3: Survey before deletion
Write-Host ""
Write-Host "[3/6] Surveying current contents..." -ForegroundColor Yellow
$totalFiles = 0
$totalBytes = 0
foreach ($d in $werDirs) {
    if (Test-Path -LiteralPath $d -ErrorAction SilentlyContinue) {
        $items = Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue
        $totalFiles += $items.Count
        $totalBytes += [int64](($items | Measure-Object Length -Sum -ErrorAction SilentlyContinue).Sum)
    }
}
$totalMB = [math]::Round($totalBytes / 1MB, 2)
Write-Host "  Found $totalFiles files / $totalMB MB across WER directories" -ForegroundColor Cyan

# Step 4: Wipe contents (with takeown fallback for ACL-protected items)
Write-Host ""
Write-Host "[4/6] Wiping contents (using takeown/icacls for stragglers)..." -ForegroundColor Yellow

$grandDeleted = 0
$grandRemaining = 0
foreach ($d in $werDirs) {
    if (-not (Test-Path -LiteralPath $d -ErrorAction SilentlyContinue)) { continue }

    $shortPath = $d -replace 'C:\\','' -replace '\\AppData\\Local\\Microsoft\\Windows\\WER\\','\AppData\...\WER\'
    $result = Force-RemoveDir -Path $d -Label $shortPath
    $grandDeleted += $result.Deleted
    $grandRemaining += $result.Remaining

    if ($result.Deleted -gt 0 -or $result.Remaining -gt 0) {
        $status = if ($result.Remaining -eq 0) { "CLEAN  " } else { "PARTIAL" }
        $color = if ($result.Remaining -eq 0) { "Green" } else { "Yellow" }
        Write-Host ("  [$status] {0} -> deleted {1}, remaining {2}" -f $shortPath, $result.Deleted, $result.Remaining) -ForegroundColor $color
    }
}

# Step 5: Clear WER registry-tracked retry queues
Write-Host ""
Write-Host "[5/6] Clearing WER registry retry tracking..." -ForegroundColor Yellow
$werRegPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\KernelFaults\Queue",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\Windows Error Reporting\KernelFaults\Queue"
)
foreach ($regPath in $werRegPaths) {
    if (Test-Path -LiteralPath $regPath -ErrorAction SilentlyContinue) {
        $vals = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue | Get-Member -MemberType NoteProperty | Where-Object { $_.Name -notmatch '^PS' }
        $valCount = ($vals | Measure-Object).Count
        if ($valCount -gt 0) {
            foreach ($v in $vals) {
                Remove-ItemProperty -LiteralPath $regPath -Name $v.Name -Force -ErrorAction SilentlyContinue
            }
            Write-Host ("  Cleared {0} queued kernel fault entries from {1}" -f $valCount, $regPath) -ForegroundColor Green
        } else {
            Write-Host ("  Already empty: {0}" -f $regPath) -ForegroundColor Green
        }
    } else {
        Write-Host ("  Not present: {0}" -f $regPath) -ForegroundColor Gray
    }
}

# Step 6: Restart WER service if it was running, verify
Write-Host ""
Write-Host "[6/6] Restoring WER service state..." -ForegroundColor Yellow
if ($wasRunning) {
    Start-Service WerSvc -ErrorAction SilentlyContinue
    $svcAfter = Get-Service WerSvc
    Write-Host ("  WerSvc started ($($svcAfter.Status))") -ForegroundColor Green
} else {
    Write-Host "  Left WerSvc stopped (will start on demand if a new crash needs reporting)" -ForegroundColor Green
}

# Final verification
Write-Host ""
Write-Host "=== Verification ===" -ForegroundColor Cyan
$finalFiles = 0
$finalBytes = 0
foreach ($d in $werDirs) {
    if (Test-Path -LiteralPath $d -ErrorAction SilentlyContinue) {
        $items = Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue
        $finalFiles += $items.Count
        $finalBytes += [int64](($items | Measure-Object Length -Sum -ErrorAction SilentlyContinue).Sum)
    }
}
$finalMB = [math]::Round($finalBytes / 1MB, 2)
$freedMB = [math]::Round(($totalBytes - $finalBytes) / 1MB, 2)
Write-Host ("  Top-level items removed: {0}" -f $grandDeleted) -ForegroundColor Green
Write-Host ("  Remaining files (recursive): {0}" -f $finalFiles) -ForegroundColor $(if ($finalFiles -eq 0) {'Green'} else {'Yellow'})
Write-Host ("  Disk space freed: {0} MB" -f $freedMB) -ForegroundColor Cyan

if ($finalFiles -gt 0) {
    Write-Host ""
    Write-Host "  Remaining locations:" -ForegroundColor Yellow
    foreach ($d in $werDirs) {
        if (Test-Path -LiteralPath $d -ErrorAction SilentlyContinue) {
            $items = Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue
            if ($items.Count -gt 0) {
                Write-Host ("    {0,4} files  in  {1}" -f $items.Count, $d) -ForegroundColor Yellow
            }
        }
    }
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
Write-Host "WER queues purged. Future crashes will still be tracked normally."
Write-Host ""
Write-Host "Press any key to close..."
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
