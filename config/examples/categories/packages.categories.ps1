<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.

    Every provisioned-appx prefix this repo knows about (docs/tweak-catalog.md SS1), tagged with:
      Tier            1 = unambiguous bloat, removed starting at the "Normal" profile (lightest touch)
                      2 = today's default behavior, removed starting at "Reduced" (matches the out-of-the-
                          box $appPackagePrefixes array as of this writing)
                      3 = today's commented-out/more-aggressive removals, removed only at "Minimal"
      CorporateExempt $true for the items today's -KeepCorporateApps carves out of removal regardless of
                      tier -- this is an overlay applied on TOP of a tier choice, not a tier of its own.
      Source          pointer back into docs/tweak-catalog.md SS1 for full provenance.

    Tier placement is a best-guess starting classification (see docs/settings-config-strategy.md) -- adjust
    freely; nothing reads these tier numbers yet.

    Deliberately absent from this list (by design, not oversight): Microsoft.Paint, Microsoft.MSPaint,
    Microsoft.WindowsTerminal -- already commented out upstream as broadly-useful mainstream apps, not
    bloat. No profile in this proposal removes them.
#>
@(
    # --- Tier 1: unambiguous OEM/Xbox/gaming-adjacent bloat ---
    @{ Name = 'AppUp.IntelManagementandSecurityStatus';     Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.BingNews';                         Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.BingSearch';                       Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.BingWeather';                      Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Clipchamp.Clipchamp';                        Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'DolbyLaboratories.DolbyAccess';               Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'DolbyLaboratories.DolbyDigitalPlusDecoderOEM'; Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.549981C3F5F10';                    Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' } # Cortana
    @{ Name = 'Microsoft.GamingApp';                        Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Microsoft3DViewer';                Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.MicrosoftSolitaireCollection';     Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.MixedReality.Portal';               Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.OfficePushNotificationUtility';    Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.PowerAutomateDesktop';             Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.SkypeApp';                         Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Wallet';                           Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Xbox.TCUI';                        Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.XboxApp';                          Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.XboxGameOverlay';                  Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.XboxGamingOverlay';                Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.XboxIdentityProvider';             Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.XboxSpeechToTextOverlay';          Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.ZuneMusic';                        Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.ZuneVideo';                        Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'MicrosoftCorporationII.MicrosoftFamily';     Tier = 1; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }

    # --- Tier 2: today's remaining active-by-default items ---
    @{ Name = 'Microsoft.Copilot';                          Tier = 2; CorporateExempt = $true;  Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.GetHelp';                          Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Getstarted';                       Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.MicrosoftOfficeHub';               Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.MicrosoftStickyNotes';             Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Office.OneNote';                   Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.OutlookForWindows';                Tier = 2; CorporateExempt = $true;  Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.People';                           Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.StartExperiencesApp';              Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Todos';                            Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Windows.Copilot';                  Tier = 2; CorporateExempt = $true;  Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Windows.CrossDevice';               Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Windows.DevHome';                  Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Windows.Teams';                    Tier = 2; CorporateExempt = $true;  Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.WindowsAlarms';                    Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.WindowsCamera';                    Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'microsoft.windowscommunicationsapps';        Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.WindowsFeedbackHub';               Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.WindowsMaps';                      Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.WindowsSoundRecorder';             Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.YourPhone';                        Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'MicrosoftCorporationII.QuickAssist';         Tier = 2; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'MSTeams';                                    Tier = 2; CorporateExempt = $true;  Source = 'tweak-catalog.md#1' }
    @{ Name = 'MicrosoftTeams';                             Tier = 2; CorporateExempt = $true;  Source = 'tweak-catalog.md#1' }

    # --- Tier 3: today's commented-out, more aggressive/niche removals ---
    @{ Name = 'Microsoft.MPEG2VideoExtension';              Tier = 3; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Recall';                           Tier = 3; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.ScreenSketch';                     Tier = 3; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.StorePurchaseApp';                 Tier = 3; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.WebMediaExtensions';                Tier = 3; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Windows.AI';                       Tier = 3; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Windows.AIFabric';                 Tier = 3; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Windows.CoreAI';                   Tier = 3; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Windows.Photos';                   Tier = 3; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'Microsoft.Windows.Recall';                   Tier = 3; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
    @{ Name = 'MicrosoftWindows.Client.WebExperience';      Tier = 3; CorporateExempt = $false; Source = 'tweak-catalog.md#1' }
)
