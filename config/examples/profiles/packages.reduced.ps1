<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.
    Matches this repo's current out-of-the-box default: tiers 1-2 removed, tier 3 (niche/AI/Recall-era)
    left alone.
#>
$categories = . (Join-Path $PSScriptRoot '..\categories\packages.categories.ps1')
return @($categories | Where-Object { $_.Tier -le 2 } | ForEach-Object { $_.Name })
