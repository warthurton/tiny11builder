<#
.SYNOPSIS
    Builds several asl-win11 image profiles back-to-back from a single source ISO.

.DESCRIPTION
    Thin orchestrator around asl-win11maker.ps1: runs it once per selected profile, each
    time as a fresh child process (so each profile's own admin-elevation check, transcript,
    and final "press Enter" prompt behave exactly as they do for a normal single-image run).
    Always builds with -UseSourceCache under the hood, so only the first profile that
    actually needs it touches the mounted ISO / converts install.esd - every later profile
    restores the same pristine source.wim from the cache instead, which is what makes
    building multiple profiles in one go fast instead of repeating the slow ISO extraction
    three times over.

    Three profiles are defined:

      Standard  - the regular serviceable build with every default debloat/telemetry tweak
                  applied, but -BypassMode forced to None regardless of what's passed here,
                  so Windows Setup's TPM/Secure Boot/RAM hardware checks stay fully enforced.
                  Any -LocalAccountName/-ProductKey you pass are honored.

      Entra     - same debloat/telemetry tweaks as Standard, but built with
                  -KeepCorporateApps (keeps OneDrive, Outlook, Teams, and Copilot, and skips
                  forcing the local-account-only OOBE path) so the image is ready to be
                  joined to Microsoft Entra ID / enrolled via Autopilot or Intune. Any
                  -LocalAccountName you pass is ignored for this profile (with a warning) -
                  Entra join needs OOBE's normal work-account sign-in, not a local account.
                  Uses whatever -BypassMode you pass (default None).

      Optimized - your normal fully-tweaked build: whatever -BypassMode, -LocalAccountName,
                  and -ProductKey you pass are used as-is, with no -KeepCorporateApps carve-
                  out. This is the "everything on" build the rest of asl-win11maker.ps1's
                  parameters already describe.

    Every other parameter (-ISO, -SCRATCH, -INDEX/-ESDINDEX/-Edition, -Core, driver
    injection, -EnableDotNet35, -CompressionMode, etc.) is forwarded unchanged to every
    profile that gets built.

.PARAMETER Profiles
    Which profiles to build, in any order (always executed in Standard, Entra, Optimized
    order regardless of the order given here). Defaults to all three.

.PARAMETER RefreshSourceCache
    Forces the source cache to be rebuilt from the ISO before the first profile builds
    (e.g. after swapping in a different Windows 11 ISO). Only applied once, on the first
    profile actually built - later profiles reuse the now-fresh cache.

.EXAMPLE
    .\asl-win11-multibuild.ps1 -ISO E -SCRATCH D -Edition Pro
    .\asl-win11-multibuild.ps1 -ISO E -Edition Pro -Profiles Entra,Optimized
    .\asl-win11-multibuild.ps1 -ISO E -Edition Pro -BypassMode Hive -LocalAccountName devbox
#>

param (
    [string]$ISO,
    [ValidatePattern('^[c-zC-Z]$')][string]$SCRATCH,
    [int]$INDEX,
    [int]$ESDINDEX,
    [string]$Edition,
    [switch]$RefreshSourceCache,
    [ValidateSet('None', 'Hive', 'Unattend', 'Both')][string]$BypassMode = 'None',
    [switch]$Core,
    [switch]$InjectSystemDrivers,
    [string]$DriverPath,
    [switch]$InjectVirtioDrivers,
    [string]$VirtioIso,
    [switch]$SkipVirtioGuestTools,
    [switch]$EnableDotNet35,
    [string]$LocalAccountName,
    [string]$ProductKey,
    [ValidateSet('None', 'Fast', 'Max', 'Recovery')][string]$CompressionMode = 'Fast',
    [ValidateSet('Standard', 'Entra', 'Optimized')][string[]]$Profiles = @('Standard', 'Entra', 'Optimized')
)

if (-not $SCRATCH) {
    $script:BuildScratchRoot = Join-Path $PSScriptRoot 'work'
} else {
    $script:BuildScratchRoot = $SCRATCH + ":"
}

$script:EntryScriptPath = $PSCommandPath
$script:EntryBoundParameters = $PSBoundParameters

$functionsScriptPath = Join-Path $PSScriptRoot 'asl-win11.functions.ps1'
if (-not (Test-Path -Path $functionsScriptPath)) {
    Write-Error "Required function library not found: $functionsScriptPath"
    Read-Host 'Press Enter to exit' | Out-Null
    exit 1
}

. $functionsScriptPath

$ErrorActionPreference = 'Stop'

# REQUIRED: elevate once here so every child asl-win11maker.ps1 invocation below inherits an
# already-elevated token and its own Confirm-AdminPrivileges check is a no-op - otherwise each
# child would try to relaunch itself elevated in a detached window and this orchestrator would
# race ahead of the real (elevated) build instead of waiting for it.
Confirm-ExecutionPolicy
Confirm-AdminPrivileges

$childScriptPath = Join-Path $PSScriptRoot 'asl-win11maker.ps1'
if (-not (Test-Path -Path $childScriptPath)) {
    Write-Error "Required builder script not found: $childScriptPath"
    Read-Host 'Press Enter to exit' | Out-Null
    exit 1
}

function Add-ChildArg {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Name,
        $Value
    )
    if ($null -eq $Value) { return }
    if ($Value -is [switch] -or $Value -is [bool]) {
        if ($Value) { $List.Add("-$Name") }
        return
    }
    if ([string]::IsNullOrEmpty([string]$Value)) { return }
    $List.Add("-$Name")
    $List.Add([string]$Value)
}

$orderedProfiles = @('Standard', 'Entra', 'Optimized') | Where-Object { $_ -in $Profiles }

Write-Phase 'Multi-profile build plan'
Write-Output "  Profiles to build, in order: $($orderedProfiles -join ', ')"
Write-Output '  Each profile runs as its own asl-win11maker.ps1 build; press Enter when prompted at the end of each one to continue to the next.'

for ($i = 0; $i -lt $orderedProfiles.Count; $i++) {
    $profileName = $orderedProfiles[$i]
    $isFirst = ($i -eq 0)

    Write-Phase "Build profile: $profileName"

    $childArgs = [System.Collections.Generic.List[string]]::new()
    Add-ChildArg -List $childArgs -Name 'ISO' -Value $ISO
    Add-ChildArg -List $childArgs -Name 'SCRATCH' -Value $SCRATCH
    Add-ChildArg -List $childArgs -Name 'INDEX' -Value $(if ($INDEX) { $INDEX })
    Add-ChildArg -List $childArgs -Name 'ESDINDEX' -Value $(if ($ESDINDEX) { $ESDINDEX })
    Add-ChildArg -List $childArgs -Name 'Edition' -Value $Edition
    Add-ChildArg -List $childArgs -Name 'UseSourceCache' -Value $true
    Add-ChildArg -List $childArgs -Name 'RefreshSourceCache' -Value ($isFirst -and $RefreshSourceCache)
    Add-ChildArg -List $childArgs -Name 'Core' -Value $Core
    Add-ChildArg -List $childArgs -Name 'InjectSystemDrivers' -Value $InjectSystemDrivers
    Add-ChildArg -List $childArgs -Name 'DriverPath' -Value $DriverPath
    Add-ChildArg -List $childArgs -Name 'InjectVirtioDrivers' -Value $InjectVirtioDrivers
    Add-ChildArg -List $childArgs -Name 'VirtioIso' -Value $VirtioIso
    Add-ChildArg -List $childArgs -Name 'SkipVirtioGuestTools' -Value $SkipVirtioGuestTools
    Add-ChildArg -List $childArgs -Name 'EnableDotNet35' -Value $EnableDotNet35
    Add-ChildArg -List $childArgs -Name 'ProductKey' -Value $ProductKey
    Add-ChildArg -List $childArgs -Name 'CompressionMode' -Value $CompressionMode
    Add-ChildArg -List $childArgs -Name 'ProfileName' -Value $profileName

    switch ($profileName) {
        'Standard' {
            if ($BypassMode -ne 'None' -and $PSBoundParameters.ContainsKey('BypassMode')) {
                Write-Output "  -BypassMode '$BypassMode' is overridden to 'None' for the Standard profile, which is meant to keep Windows Setup's hardware checks fully enforced."
            }
            Add-ChildArg -List $childArgs -Name 'BypassMode' -Value 'None'
            Add-ChildArg -List $childArgs -Name 'LocalAccountName' -Value $LocalAccountName
        }
        'Entra' {
            Add-ChildArg -List $childArgs -Name 'BypassMode' -Value $BypassMode
            Add-ChildArg -List $childArgs -Name 'KeepCorporateApps' -Value $true
            if ($LocalAccountName) {
                Write-Output "  -LocalAccountName '$LocalAccountName' is ignored for the Entra profile; OOBE will offer a work/school sign-in instead."
            }
        }
        'Optimized' {
            Add-ChildArg -List $childArgs -Name 'BypassMode' -Value $BypassMode
            Add-ChildArg -List $childArgs -Name 'LocalAccountName' -Value $LocalAccountName
        }
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $childScriptPath @childArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Build of profile '$profileName' failed (exit code $LASTEXITCODE). Stopping - later profiles were not built."
    }
}

Write-Phase 'Multi-profile build complete'
Write-Output "  Built profiles: $($orderedProfiles -join ', ')"
Write-Output "  Output ISOs are in $(Join-Path $PSScriptRoot 'output')"
