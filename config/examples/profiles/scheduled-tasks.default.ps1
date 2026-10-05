<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.
    Matches this repo's current out-of-the-box default: tier 1 only (today's 5 active task paths).
#>
$categories = . (Join-Path $PSScriptRoot '..\categories\scheduled-tasks.categories.ps1')
return @($categories | Where-Object { $_.Tier -le 1 } | ForEach-Object { $_.Name })
