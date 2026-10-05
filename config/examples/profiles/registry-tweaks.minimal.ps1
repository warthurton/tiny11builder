<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.
    Aggressive: adds tier-2 functions (Disable-WindowsUpdate, Disable-DiagnosticServices, Disable-WindowsAI)
    -- today these are only ever forced on under -Core. Pair with a -Core (non-serviceable) build.
#>
$categories = . (Join-Path $PSScriptRoot '..\categories\registry-tweaks.categories.ps1')
return @($categories | Where-Object { $_.Tier -le 2 } | ForEach-Object { $_.Name })
