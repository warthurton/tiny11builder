<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.
    NOT a tier of its own -- this is the "Reduced" tier (today's default) with the CorporateExempt overlay
    applied, matching today's actual -KeepCorporateApps behavior (keeps Copilot/Teams/Outlook). Combine the
    overlay with packages.normal.ps1's selection instead if you want an even lighter corporate image.
#>
$categories = . (Join-Path $PSScriptRoot '..\categories\packages.categories.ps1')
return @($categories | Where-Object { $_.Tier -le 2 -and -not $_.CorporateExempt } | ForEach-Object { $_.Name })
