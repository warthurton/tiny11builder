<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.
#>
$categories = . (Join-Path $PSScriptRoot '..\categories\hardware-compat.categories.ps1')
return $categories | Where-Object { $_.Name -eq 'BypassOffline' } | Select-Object -First 1
