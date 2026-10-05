<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.

    Hardware-compatibility doesn't have a removal "tier" -- it's three small, named, mutually exclusive
    strata mapping directly onto -BypassMode x the driver-injection switches
    (docs/build-options-reference.md's -BypassMode and -InjectSystemDrivers/-DriverPath/-InjectVirtioDrivers
    sections). Pick exactly one.
#>
@(
    @{
        Name           = 'StrictCompliant'
        Description    = 'Setup enforces TPM/Secure Boot/RAM checks normally; no driver injection. Matches ' +
                          'asl-win11-multibuild.ps1''s Standard profile, which forces this regardless of ' +
                          'what the orchestrator was given.'
        BypassMode     = 'None'
        InjectDrivers  = $false
        Source         = 'build-options-reference.md#-bypassmode-nonehiveunattendboth'
    }
    @{
        Name           = 'BypassOffline'
        Description    = 'Bypass hardware checks via offline hive edit (or both hive+answer-file) but no ' +
                          'driver injection -- for known-incompatible-but-otherwise-ordinary hardware or ' +
                          'VMs without an unusual storage controller.'
        BypassMode     = 'Both'
        InjectDrivers  = $false
        Source         = 'build-options-reference.md#-bypassmode-nonehiveunattendboth'
    }
    @{
        Name           = 'BypassAndDrivers'
        Description    = 'Bypass hardware checks AND inject drivers (-InjectSystemDrivers and/or ' +
                          '-InjectVirtioDrivers as needed) -- for unusual storage controllers or maximum ' +
                          'offline portability. The storage-driver INF false-positive gap winutil found ' +
                          '(abcbc23) is fixed here (Test-StorageDriverInf + Update-BootImage, see ' +
                          'docs/build-options-reference.md''s Drivers section) -- still worth a real-' +
                          'hardware/VM boot test for an uncommon RAID/NVMe-RAID controller before trusting ' +
                          'a clean build log alone.'
        BypassMode     = 'Both'
        InjectDrivers  = $true
        Source         = 'build-options-reference.md#-injectsystemdrivers---driverpath-folder---injectvirtiodrivers--virtioiso-path'
    }
)
