<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.
    Matches this repo's current out-of-the-box default: tier 1 functions, un-filtered by CorporateExempt
    (i.e. this is the "Online"/non-corporate account-mode behavior). Combine with the CorporateExempt
    overlay yourself (see packages.corporate.ps1 for the pattern) for an Entra-style build.
#>
$categories = . (Join-Path $PSScriptRoot '..\categories\registry-tweaks.categories.ps1')
return @($categories | Where-Object { $_.Tier -le 1 } | ForEach-Object { $_.Name })
