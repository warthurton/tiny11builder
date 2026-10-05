<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.
    Most aggressive package removal: every tier (1-3) is removed, including today's commented-out,
    more niche removals (AI/Recall-era packages, Photos, Widgets, legacy codecs/Store helper).
#>
$categories = . (Join-Path $PSScriptRoot '..\categories\packages.categories.ps1')
return @($categories | Where-Object { $_.Tier -le 3 } | ForEach-Object { $_.Name })
