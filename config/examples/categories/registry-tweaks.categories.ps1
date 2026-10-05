<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.

    Every registry/policy tweak function this repo knows about (docs/tweak-catalog.md SS3), tagged:
      Tier 1 = today's active-by-default functions
      Tier 2 = today's commented-out, more aggressive functions (WU suppression, diagnostic services,
               Windows AI) -- Core-only functions (Disable-WindowsDefender, Set-BootImageSetupCmdLine) are
               deliberately NOT listed here, since they're gated by -Core, not by a package/registry
               profile -- see hardware-compat / the -Core option in docs/build-options-reference.md instead.
      CorporateExempt $true for the functions -KeepCorporateApps skips today (overlay, not a tier).
#>
@(
    @{ Name = 'Disable-SponsoredApps';          Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#3' }
    @{ Name = 'Enable-LocalAccountOOBE';        Tier = 1; CorporateExempt = $true;  Source = 'tweak-catalog.md#3' }
    @{ Name = 'Disable-ReservedStorage';        Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#3' }
    @{ Name = 'Disable-BitLockerAutoEncryption'; Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#3' }
    @{ Name = 'Disable-Telemetry';              Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#3' }
    @{ Name = 'Disable-ChatIcon';               Tier = 1; CorporateExempt = $true;  Source = 'tweak-catalog.md#3' }
    @{ Name = 'Disable-OneDriveSync';           Tier = 1; CorporateExempt = $true;  Source = 'tweak-catalog.md#3' }
    @{ Name = 'Disable-DevHomeOutlookInstall';  Tier = 1; CorporateExempt = $true;  Source = 'tweak-catalog.md#3' }
    @{ Name = 'Disable-Copilot';                Tier = 1; CorporateExempt = $true;  Source = 'tweak-catalog.md#3' }
    @{ Name = 'Disable-TeamsInstall';           Tier = 1; CorporateExempt = $true;  Source = 'tweak-catalog.md#3' }
    @{ Name = 'Disable-NewOutlook';             Tier = 1; CorporateExempt = $true;  Source = 'tweak-catalog.md#3' }
    @{ Name = 'Disable-WindowsUpdate';          Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#3' }
    @{ Name = 'Disable-DiagnosticServices';     Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#3' }
    @{ Name = 'Disable-WindowsAI';              Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#3' }
)
