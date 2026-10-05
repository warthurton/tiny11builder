<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.
    Lightest touch: only tier 1 (unambiguous OEM/Xbox/gaming bloat) removed. Keeps Mail/Calendar, Maps,
    Camera, Sticky Notes, To Do, Copilot/Teams/Outlook, etc.
#>
$categories = . (Join-Path $PSScriptRoot '..\categories\packages.categories.ps1')
return @($categories | Where-Object { $_.Tier -le 1 } | ForEach-Object { $_.Name })
