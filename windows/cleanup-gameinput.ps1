# Microsoft GameInput Cleanup Script
# ---------------------------------------------------------------------------
# WHAT IT DOES : Fully removes Microsoft GameInput - stops/disables its
#                services, kills its processes, uninstalls the MSI, deletes
#                leftover folders, and verifies removal.
# RISK         : Low. Recovery: reinstall GameInput from Microsoft, or simply
#                launch a game that needs it and it will reinstall its own copy.
# CAVEAT       : The MSI product code below ({A9E31119-...}) is hardcoded and
#                may differ between GameInput versions. If uninstall returns
#                1605 ("already gone") but a copy remains, find the real code
#                with:  Get-Package '*GameInput*' | Select Name,FastPackageReference
# TESTED ON    : Windows 11 (64-bit).
# ---------------------------------------------------------------------------
# Run this in an ELEVATED PowerShell window
# (Right-click PowerShell -> Run as Administrator)

# Self-elevation guard
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator', then re-run this script." -ForegroundColor Yellow
    exit 1
}

Write-Host "=== Microsoft GameInput Cleanup ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Stop and disable the service
Write-Host "[1/5] Stopping and disabling GameInputRedistService..." -ForegroundColor Yellow
Stop-Service -Name GameInputRedistService -Force -ErrorAction SilentlyContinue
Set-Service -Name GameInputRedistService -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service -Name GameInputSvc -Force -ErrorAction SilentlyContinue
Get-Service -Name '*GameInput*' -ErrorAction SilentlyContinue | Format-Table -AutoSize

# Step 2: Kill any running processes
Write-Host "[2/5] Killing any GameInput processes..." -ForegroundColor Yellow
Get-Process -Name 'GameInput*' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  Killing $($_.ProcessName) (PID $($_.Id))"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 2

# Step 3: Uninstall the MSI package
Write-Host "[3/5] Uninstalling Microsoft GameInput MSI..." -ForegroundColor Yellow
$result = Start-Process msiexec.exe -ArgumentList '/X{A9E31119-18D8-4BF7-8B63-3CFE78CA0ABD} /qn /norestart' -Wait -PassThru
Write-Host "  Uninstall exit code: $($result.ExitCode)"
Write-Host "  (0 = success, 1605 = already gone, 3010 = success+reboot needed)"

# Step 4: Remove leftover folders
Write-Host "[4/5] Removing leftover folders..." -ForegroundColor Yellow
@("C:\Program Files\Microsoft GameInput", "C:\Program Files (x86)\Microsoft GameInput") | ForEach-Object {
    if (Test-Path $_) {
        Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $_) {
            Write-Host "  STILL EXISTS: $_" -ForegroundColor Red
        } else {
            Write-Host "  REMOVED: $_" -ForegroundColor Green
        }
    } else {
        Write-Host "  Already gone: $_" -ForegroundColor Green
    }
}

# Step 5: Verify
Write-Host ""
Write-Host "[5/5] Final verification..." -ForegroundColor Yellow
$found = $false
@(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
) | ForEach-Object {
    Get-ItemProperty $_ -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'GameInput' } | ForEach-Object {
        Write-Host "  STILL REGISTERED: $($_.DisplayName) v$($_.DisplayVersion)" -ForegroundColor Red
        $found = $true
    }
}
if (-not $found) {
    Write-Host "  Microsoft GameInput is fully removed." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
Write-Host "Note: If a game later requires GameInput, it will install its own copy or you can re-download from Microsoft."
Write-Host "Press any key to close..."
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
