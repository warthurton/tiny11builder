<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.

    Every scheduled-task path this repo knows about (docs/tweak-catalog.md SS2), tagged:
      Tier 1 = today's 5 active-by-default removals (telemetry/CEIP/compat-appraiser/chkdsk/WER)
      Tier 2 = winutil's 6 additional WU-task paths, today shipped commented out -- more aggressive,
               reduces Windows Update's ability to self-heal on a serviceable image.
#>
@(
    @{ Name = 'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'; Tier = 1; Source = 'tweak-catalog.md#2' }
    @{ Name = 'Microsoft\Windows\Customer Experience Improvement Program';                  Tier = 1; Source = 'tweak-catalog.md#2' }
    @{ Name = 'Microsoft\Windows\Application Experience\ProgramDataUpdater';                Tier = 1; Source = 'tweak-catalog.md#2' }
    @{ Name = 'Microsoft\Windows\Chkdsk\Proxy';                                             Tier = 1; Source = 'tweak-catalog.md#2' }
    @{ Name = 'Microsoft\Windows\Windows Error Reporting\QueueReporting';                   Tier = 1; Source = 'tweak-catalog.md#2' }
    @{ Name = 'Microsoft\Windows\InstallService';                                           Tier = 2; Source = 'tweak-catalog.md#2' }
    @{ Name = 'Microsoft\Windows\UpdateOrchestrator';                                       Tier = 2; Source = 'tweak-catalog.md#2' }
    @{ Name = 'Microsoft\Windows\UpdateAssistant';                                          Tier = 2; Source = 'tweak-catalog.md#2' }
    @{ Name = 'Microsoft\Windows\WaaSMedic';                                                Tier = 2; Source = 'tweak-catalog.md#2' }
    @{ Name = 'Microsoft\Windows\WindowsUpdate';                                            Tier = 2; Source = 'tweak-catalog.md#2' }
    @{ Name = 'Microsoft\WindowsUpdate';                                                    Tier = 2; Source = 'tweak-catalog.md#2' }
)
