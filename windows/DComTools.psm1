# DComTools PowerShell Module
# Utilities to resolve DCOM CLSID/AppID information and related security from the registry

function Get-RegistryDefaultValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path
    )
    try {
        if (Test-Path -Path $Path) {
            $item = Get-Item -Path $Path -ErrorAction Stop
            return $item.GetValue('')
        }
    } catch {}
    return $null
}

function Get-RegistryValueSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name
    )
    try {
        if (Test-Path -Path $Path) {
            $props = Get-ItemProperty -Path $Path -ErrorAction Stop
            return $props.$Name
        }
    } catch {}
    return $null
}

function Convert-RegistryBinarySdToSddl {
    [CmdletBinding()]
    param(
        [byte[]]$Bytes
    )
    if (-not $Bytes) { return $null }
    try {
        $rsd = New-Object System.Security.AccessControl.RawSecurityDescriptor($Bytes, 0)
        return $rsd.GetSddlForm('All')
    } catch {
        return $null
    }
}

function Resolve-DComClsidInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Clsid
    )
    $guid = $Clsid.Trim('{}')
    $paths = @(
        "HKLM:\SOFTWARE\Classes\CLSID\{$guid}",
        "HKCR:\CLSID\{$guid}"
    )

    $info = [ordered]@{
        Guid           = "{$guid}"
        Name           = $null
        AppIdFromClsid = $null
        LocalServer32  = $null
        InprocServer32 = $null
        TreatAs        = $null
        ProgId         = $null
        PathSearched   = @()
    }

    foreach ($p in $paths) {
        $info.PathSearched += $p
        if (Test-Path $p) {
            if (-not $info.Name) { $info.Name = Get-RegistryDefaultValue -Path $p }
            if (-not $info.AppIdFromClsid) { $info.AppIdFromClsid = Get-RegistryValueSafe -Path $p -Name 'AppID' }
            if (-not $info.ProgId) { $info.ProgId = Get-RegistryValueSafe -Path $p -Name 'ProgID' }
            $lsPath = Join-Path $p 'LocalServer32'
            $ipPath = Join-Path $p 'InprocServer32'
            if (-not $info.LocalServer32) { $info.LocalServer32 = Get-RegistryDefaultValue -Path $lsPath }
            if (-not $info.InprocServer32) { $info.InprocServer32 = Get-RegistryDefaultValue -Path $ipPath }
            if (-not $info.TreatAs) { $info.TreatAs = Get-RegistryValueSafe -Path $p -Name 'TreatAs' }
        }
    }

    if ($info.AppIdFromClsid) {
        $app = $info.AppIdFromClsid.ToString().Trim('{}')
        $info.AppIdFromClsid = "{$app}"
    }

    return [pscustomobject]$info
}

function Resolve-DComAppIdInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$AppId
    )
    $guid = $AppId.Trim('{}')
    $paths = @(
        "HKLM:\SOFTWARE\Classes\AppID\{$guid}",
        "HKCR:\AppID\{$guid}"
    )

    $info = [ordered]@{
        Guid                  = "{$guid}"
        Name                  = $null
        DllSurrogate          = $null
        LocalService          = $null
        ServiceDisplayName    = $null
        ServiceParameters     = $null
        LaunchPermissionSddl  = $null
        AccessPermissionSddl  = $null
        PathSearched          = @()
    }

    foreach ($p in $paths) {
        $info.PathSearched += $p
        if (Test-Path $p) {
            if (-not $info.Name) { $info.Name = Get-RegistryDefaultValue -Path $p }
            if (-not $info.DllSurrogate) { $info.DllSurrogate = Get-RegistryValueSafe -Path $p -Name 'DllSurrogate' }
            if (-not $info.LocalService) { $info.LocalService = Get-RegistryValueSafe -Path $p -Name 'LocalService' }
            if (-not $info.ServiceParameters) { $info.ServiceParameters = Get-RegistryValueSafe -Path $p -Name 'ServiceParameters' }

            $lp = Get-RegistryValueSafe -Path $p -Name 'LaunchPermission'
            if (-not $info.LaunchPermissionSddl -and $lp -is [byte[]]) {
                $info.LaunchPermissionSddl = Convert-RegistryBinarySdToSddl -Bytes $lp
            }
            $ap = Get-RegistryValueSafe -Path $p -Name 'AccessPermission'
            if (-not $info.AccessPermissionSddl -and $ap -is [byte[]]) {
                $info.AccessPermissionSddl = Convert-RegistryBinarySdToSddl -Bytes $ap
            }
        }
    }

    if ($info.LocalService) {
        try {
            $svc = Get-Service -Name $info.LocalService -ErrorAction Stop
            if ($svc) { $info.ServiceDisplayName = $svc.DisplayName }
        } catch {}
    }

    return [pscustomobject]$info
}

function Resolve-DComGuidSet {
    [CmdletBinding()]
    param(
        [string]$Clsid,
        [string]$AppId
    )
    $result = [ordered]@{}
    if ($Clsid) { $result.CLSID = Resolve-DComClsidInfo -Clsid $Clsid }
    if ($AppId) { $result.AppID = Resolve-DComAppIdInfo -AppId $AppId }
    return [pscustomobject]$result
}

Export-ModuleMember -Function Resolve-DComClsidInfo, Resolve-DComAppIdInfo, Resolve-DComGuidSet


