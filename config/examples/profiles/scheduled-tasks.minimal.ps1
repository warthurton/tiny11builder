<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.
    Aggressive: all 11 known task paths, including winutil's 6 WU-specific additions. Reduces Windows
    Update's ability to self-heal -- pair with a -Core (non-serviceable) build, not a serviceable one.
#>
$categories = . (Join-Path $PSScriptRoot '..\categories\scheduled-tasks.categories.ps1')
return @($categories | Where-Object { $_.Tier -le 2 } | ForEach-Object { $_.Name })
