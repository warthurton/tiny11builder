<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.
#>
$categories = . (Join-Path $PSScriptRoot '..\categories\account-mode.categories.ps1')
return $categories | Where-Object { $_.Name -eq 'Online' } | Select-Object -First 1
