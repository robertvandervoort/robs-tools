param(
    [string]$Clsid,
    [string]$AppId,
    [switch]$AsJson
)

try {
    $modulePath = Join-Path $PSScriptRoot 'DComTools.psm1'
    Import-Module -Force $modulePath
} catch {
    Write-Error "Failed to import DComTools.psm1: $($_.Exception.Message)"
    exit 1
}

$output = Resolve-DComGuidSet -Clsid $Clsid -AppId $AppId
if ($AsJson) {
    $output | ConvertTo-Json -Depth 6
} else {
    $output
}









