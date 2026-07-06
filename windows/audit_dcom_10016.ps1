[CmdletBinding()]
param(
    [int]$HoursBack = 24,
    [string]$OutputCsv = 'dcom_10016_audit.csv',
    [switch]$AsJson
)

try {
    $modulePath = Join-Path $PSScriptRoot 'DComTools.psm1'
    Import-Module -Force $modulePath
} catch {
    Write-Error "Failed to import DComTools.psm1: $($_.Exception.Message)"
    exit 1
}

function Parse-DCom10016Message {
    param([string]$Message)
    if (-not $Message) { return $null }

    $result = [ordered]@{
        Action = $null
        CLSID = $null
        APPID = $null
        User = $null
        SID = $null
        Address = $null
    }

    try {
        $m = $Message
        $clsid = [regex]::Match($m, 'CLSID\s*\{(?<g>[0-9A-Fa-f-]+)\}')
        if ($clsid.Success) { $result.CLSID = "{$($clsid.Groups['g'].Value)}" }
        $appid = [regex]::Match($m, 'APPID\s*\{(?<g>[0-9A-Fa-f-]+)\}')
        if ($appid.Success) { $result.APPID = "{$($appid.Groups['g'].Value)}" }
        $action = [regex]::Match($m, 'do not grant\s+(?<a>(?:Local|Remote)\s+(?:Activation|Launch))\s+permission', 'IgnoreCase')
        if ($action.Success) { $result.Action = $action.Groups['a'].Value }
        $user = [regex]::Match($m, 'to the user\s+(?<u>.+?)\s+SID\s*\((?<sid>S-[0-9-]+)\)', 'IgnoreCase')
        if ($user.Success) { $result.User = $user.Groups['u'].Value; $result.SID = $user.Groups['sid'].Value }
        $addr = [regex]::Match($m, 'from address\s+(?<addr>\S+)', 'IgnoreCase')
        if ($addr.Success) { $result.Address = $addr.Groups['addr'].Value }
    } catch {}

    return [pscustomobject]$result
}

$startTime = (Get-Date).AddHours(-[Math]::Abs($HoursBack))
Write-Host "Auditing DCOM 10016 events since: $($startTime)" -ForegroundColor Cyan

$events = Get-WinEvent -FilterHashtable @{ LogName='System'; Id=10016; StartTime=$startTime } -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, ProviderName, MachineName, @{n='Message'; e={$_.Message -replace "`n", ' ' -replace "`r", ' '}}

if (-not $events) {
    Write-Host 'No 10016 events found in the specified time range.' -ForegroundColor Yellow
    exit 0
}

$rows = @()
foreach ($e in $events) {
    $parsed = Parse-DCom10016Message -Message $e.Message
    if (-not $parsed) { continue }

    $cls = $null
    $app = $null
    if ($parsed.CLSID) { $cls = Resolve-DComClsidInfo -Clsid $parsed.CLSID }
    if ($parsed.APPID) { $app = Resolve-DComAppIdInfo -AppId $parsed.APPID }

    $row = [ordered]@{
        TimeCreated        = $e.TimeCreated
        Computer           = $e.MachineName
        Action             = $parsed.Action
        User               = $parsed.User
        SID                = $parsed.SID
        Address            = $parsed.Address
        CLSID              = $parsed.CLSID
        CLSID_Name         = $cls.Name
        APPID              = $parsed.APPID
        APPID_Name         = $app.Name
        LocalService       = $app.LocalService
        ServiceDisplayName = $app.ServiceDisplayName
        LocalServer32      = $cls.LocalServer32
        InprocServer32     = $cls.InprocServer32
    }
    $rows += [pscustomobject]$row
}

if (-not $rows) {
    Write-Host 'Found 10016 events, but could not parse details.' -ForegroundColor Yellow
    exit 0
}

# Summary
Write-Host "Found $($rows.Count) DCOM 10016 events" -ForegroundColor Green
$byKey = $rows | Group-Object CLSID, APPID, User | Sort-Object Count -Descending
foreach ($g in $byKey) {
    $k = $g.Group[0]
    $clsName = if ($k.CLSID_Name) { $k.CLSID_Name } else { 'Unknown' }
    $appName = if ($k.APPID_Name) { $k.APPID_Name } else { 'Unknown' }
    Write-Host ("  {0}x User={1} CLSID={2} ({3}) APPID={4} ({5})" -f $g.Count, $k.User, $k.CLSID, $clsName, $k.APPID, $appName) -ForegroundColor Gray
}

if ($OutputCsv) {
    try {
        $rows | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Saved audit to $OutputCsv" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to save CSV: $($_.Exception.Message)"
    }
}

if ($AsJson) {
    $rows | ConvertTo-Json -Depth 6
} else {
    $rows | Format-Table -AutoSize TimeCreated, Action, User, SID, CLSID, CLSID_Name, APPID, APPID_Name, LocalService
    Write-Host "\nRemediation guidance:" -ForegroundColor Cyan
    Write-Host "  - Open Component Services (dcomcnfg) -> Computers -> My Computer -> DCOM Config" -ForegroundColor White
    Write-Host "  - Locate the application by APPID/Name -> Properties -> Security tab" -ForegroundColor White
    Write-Host "  - Under Launch and Activation Permissions: Edit -> Add 'LOCAL SERVICE' -> Allow Local Activation" -ForegroundColor White
    Write-Host "  - Alternatively, adjust AppID LaunchPermission in registry after taking ownership (advanced)" -ForegroundColor White
}


