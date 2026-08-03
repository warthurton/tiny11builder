<#
.SYNOPSIS
    Main runner script to build a trimmed-down Windows 11 image.

.DESCRIPTION
    This runner imports reusable functions from asl-win11.functions.ps1 and
    executes the build workflow in a clear, commentable function list.

.PARAMETER ISO
    Either the drive letter of an already-mounted Windows 11 ISO/DVD (eg: E), or a path to
    a Windows 11 .iso file, which the script mounts itself via Mount-DiskImage and
    dismounts again during cleanup. Prompts interactively (accepting either form) when
    omitted.

.PARAMETER SCRATCH
    Drive letter of the desired scratch disk (eg: D)

.PARAMETER INDEX
    Install.wim image index to build from. Prompts interactively when omitted. Ignored if
    -Edition is also given.

.PARAMETER ESDINDEX
    Source install.esd image index to convert, when the source media ships an ESD
    instead of a WIM. Prompts interactively when omitted. Ignored if -Edition is also given.

.PARAMETER Edition
    Look up the image index by edition name instead of a numeric -INDEX/-ESDINDEX (eg:
    'Pro', 'Home', 'Education', 'Enterprise', 'Professional'). Matches case-insensitively
    as a substring against either the image's friendly name (eg 'Windows 11 Pro') or its
    DISM Edition ID (eg 'Professional', 'Core' — Home's internal edition ID), so either
    common name works. Applies to both install.wim (-INDEX) and, when converting from
    install.esd, the ESD source (-ESDINDEX). Errors out if the name matches zero or more
    than one image in the source.

.PARAMETER UseSourceCache
    Cache the pristine, just-extracted install.wim/boot.wim (post ESD conversion, before
    any removals or tweaks) under <SCRATCH>\sourcecache. When a valid cache already exists,
    reruns restore from it instead of requiring the ISO to be mounted or re-copied — useful
    for iterating on -BypassMode, driver injection, or the removal lists without repeating
    the ISO extraction each time. The cache is left untouched by every build; only rebuilt
    when missing or when -RefreshSourceCache is passed.

.PARAMETER RefreshSourceCache
    Used with -UseSourceCache: force rebuilding the cache from the mounted ISO even if one
    already exists (e.g. after swapping in a different Windows 11 ISO).

.PARAMETER BypassMode
    Windows 11 hardware-check bypass strategy: None (default), Hive (offline registry
    edit, applied to install.wim and boot.wim), Unattend (Rufus-style RunSynchronousCommand
    entries embedded in autounattend.xml), or Both.

.PARAMETER Core
    Build the stripped, non-serviceable "core" image instead of the regular serviceable
    build (strips WinSxS/Windows Update/WinRE/Defender; cannot add updates, languages, or
    features afterward).

.PARAMETER InjectSystemDrivers
    Export drivers from the currently running host system and inject the full set into
    install.wim. The storage/RAID-class subset is also staged into $WinpeDriver$ at the ISO
    root, which Windows Setup auto-loads during its WinPE pass - boot.wim itself is never
    mounted for this.

.PARAMETER DriverPath
    Additional local folder of drivers: the full set is injected into install.wim, and its
    storage/RAID-class subset is staged into $WinpeDriver$, same as -InjectSystemDrivers.

.PARAMETER InjectVirtioDrivers
    Inject KVM/QEMU virtio-win drivers into install.wim, stage the storage driver
    (viostor/vioscsi) into $WinpeDriver$ so Setup's WinPE environment can see the VM disk,
    and stage the virtio guest tools to install at first logon (see -SkipVirtioGuestTools).

.PARAMETER VirtioIso
    Source for the virtio drivers: a drive letter of an already-mounted virtio-win ISO,
    a path to a virtio-win .iso file, or an already-extracted folder. When omitted, the
    latest stable virtio-win.iso is downloaded automatically.

.PARAMETER SkipVirtioGuestTools
    When -InjectVirtioDrivers is set, skip staging the virtio-win-guest-tools first-logon
    install and only inject the drivers themselves.

.PARAMETER EnableDotNet35
    Core build only: enable .NET Framework 3.5 from the source media. Prompts
    interactively when omitted.

.PARAMETER LocalAccountName
    Embed a local account into autounattend.xml so OOBE creates it automatically instead of
    requiring a Microsoft account, in the Administrators group. Its password is set to the
    same value as the account name - deliberately, so no password generation/storage/prompt
    handling is needed here. This means the account's password is exactly its (public)
    username, which is fine for a disposable/dev/VM image but is not a hardening feature and
    should never be used for an image that will be exposed to an untrusted network or user.

.PARAMETER ProductKey
    A Windows product key to embed into autounattend.xml so Setup activates automatically
    instead of prompting. Optional even for a fully unattended install: autounattend.xml
    always carries an (empty by default) ProductKey element with WillShowUI set to Never, so
    Setup never shows the "Enter your product key" screen (and aborts if that screen is
    Cancelled) regardless of whether -ProductKey is given.

.PARAMETER CompressionMode
    DISM /Export-Image /Compress mode used for the final install.wim (and, under -Core, the
    install.esd conversion): None, Fast (default), Max, or Recovery. Fast matches the
    original tiny11 scripts' behavior; Max shrinks the image further at the cost of a much
    slower export; Recovery produces the same WIMBoot-style compression Windows Setup uses
    for its own install.esd (smallest, slowest); None skips recompression entirely (largest,
    fastest export - useful mainly for quick iteration).

.EXAMPLE
    .\asl-win11maker.ps1 E D
    .\asl-win11maker.ps1 -ISO E -SCRATCH D
    .\asl-win11maker.ps1 -ISO E -INDEX 6 -BypassMode Hive -InjectVirtioDrivers
    .\asl-win11maker.ps1 -ISO E -INDEX 6 -Core
    .\asl-win11maker.ps1 -ISO E -INDEX 6 -UseSourceCache
    .\asl-win11maker.ps1 -INDEX 6 -UseSourceCache -BypassMode Both        # rerun from cache, no -ISO needed
    .\asl-win11maker.ps1 -ISO D:\Win11_25H2_English_x64.iso -Edition Pro  # mount the ISO file itself and pick "Pro" by name
    .\asl-win11maker.ps1 -ISO E -INDEX 6 -LocalAccountName testvm        # local account "testvm", password "testvm"
    .\asl-win11maker.ps1 -ISO E -INDEX 6 -ProductKey XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
    .\asl-win11maker.ps1 -ISO E -INDEX 6 -CompressionMode Max
#>

#---------[ Parameters ]---------#
param (
    [string]$ISO,
    [ValidatePattern('^[c-zC-Z]$')][string]$SCRATCH,
    [int]$INDEX,
    [int]$ESDINDEX,
    [string]$Edition,
    [switch]$UseSourceCache,
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
    [ValidateSet('None', 'Fast', 'Max', 'Recovery')][string]$CompressionMode = 'Fast'
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

#---------[ Error Handling ]---------#
# REQUIRED: fail fast instead of continuing past a broken step, so the top-level
# try/catch below always gets a chance to run emergency cleanup.
$ErrorActionPreference = 'Stop'

try {
#---------[ Main Workflow ]---------#
# REQUIRED SETUP STEPS (do not comment out)
Confirm-ExecutionPolicy        # REQUIRED: ensure script execution policy allows running
Confirm-AdminPrivileges        # REQUIRED: relaunch as admin if needed (forwards all bound parameters)
Confirm-AutounattendXml        # REQUIRED: ensure autounattend.xml is present locally
Initialize-Tiny11Session       # REQUIRED: initialize paths, transcript, and session state
Set-SleepPrevention            # REQUIRED: keep Windows from suspending mid-build; released before the final prompt
Show-CoreBuildWarning          # REQUIRED: no-op unless -Core; prints the non-serviceable-image warning
Initialize-SourceImage         # REQUIRED: populate scratch sources\ from the -UseSourceCache cache when valid, else from the mounted ISO (resolves drive letter, converts install.esd if needed, and copies source media)
Resolve-InstallImageIndex      # REQUIRED: choose the install image index to modify (honors -INDEX)
Mount-InstallImage             # REQUIRED: mount install.wim to working directory
Show-ImageMetadata             # REQUIRED: print selected image language/architecture info
Initialize-PreparedAnswerFile  # REQUIRED: prepare autounattend.xml once for every consumer (Sysprep copy, ISO root, Unattend bypass)

# DRIVER INJECTION (install.wim, plus storage-only staging into $WinpeDriver$ for Setup's
# WinPE environment - see Add-WinPEStorageDrivers) - SWITCH-GATED: controlled by
# -InjectSystemDrivers / -DriverPath / -InjectVirtioDrivers, not by commenting these out.
if ($InjectSystemDrivers) {
    Export-HostSystemDrivers | Out-Null
    Add-DriversToImage -MountPath $script:mountDir -DriverPath $script:hostDriverPath -Label 'install.wim (host)'
    Add-WinPEStorageDrivers -ContentRoot $script:tiny11Root -SourcePath $script:hostDriverPath -Label 'host'
}
if ($DriverPath) {
    Add-DriversToImage -MountPath $script:mountDir -DriverPath $DriverPath -Label 'install.wim (custom)'
    Add-WinPEStorageDrivers -ContentRoot $script:tiny11Root -SourcePath $DriverPath -Label 'custom'
}
if ($InjectVirtioDrivers) {
    $script:virtioRoot = Resolve-VirtioDriverSource -VirtioIso $VirtioIso
    $virtioStagingDir = Add-VirtioDriversToImage -MountPath $script:mountDir -VirtioRoot $script:virtioRoot
    if ($virtioStagingDir) {
        Add-WinPEStorageDrivers -ContentRoot $script:tiny11Root -SourcePath $virtioStagingDir -Label 'virtio'
    }
}

Write-Output "Mounting complete! Performing removal of applications..."

# Optional customization lists
# Comment out individual entries to keep them in the final image.
$appPackagePrefixes = @(
    'AppUp.IntelManagementandSecurityStatus'   # Intel Management & Security Status OEM bloatware
    'Clipchamp.Clipchamp'                      # Clipchamp video editor
    'DolbyLaboratories.DolbyAccess'            # Dolby Access audio OEM app
    'DolbyLaboratories.DolbyDigitalPlusDecoderOEM' # Dolby Digital Plus decoder OEM app
    'Microsoft.BingNews'                       # Microsoft News (Bing News)
    'Microsoft.BingSearch'                     # Bing Search integration app
    'Microsoft.BingWeather'                    # Microsoft Weather (Bing Weather)
    'Microsoft.Copilot'                        # Microsoft Copilot AI assistant app
    'Microsoft.Windows.CrossDevice'            # Cross-device experience (Phone Link companion)
    'Microsoft.GamingApp'                      # Xbox Gaming App (Game Pass hub)
    'Microsoft.GetHelp'                        # Get Help support app
    'Microsoft.Getstarted'                     # Tips / Get Started app
    'Microsoft.Microsoft3DViewer'              # 3D Viewer app
    'Microsoft.MicrosoftOfficeHub'             # Office Hub ("Get Office" / Microsoft 365 app)
    'Microsoft.MicrosoftSolitaireCollection'   # Microsoft Solitaire Collection game
    'Microsoft.MicrosoftStickyNotes'           # Sticky Notes app
    'Microsoft.MixedReality.Portal'            # Mixed Reality Portal (VR/AR)
    # 'Microsoft.MPEG2VideoExtension'            # tiny11-automated: MPEG-2 video playback extension
    # 'Microsoft.MSPaint'                        # Paint 3D (legacy MSPaint UWP)
    'Microsoft.Office.OneNote'                 # OneNote UWP app
    'Microsoft.OfficePushNotificationUtility'  # Office push notification background service
    'Microsoft.OutlookForWindows'              # New Outlook for Windows app
    # 'Microsoft.Paint'                          # Paint app (modern)
    'Microsoft.People'                         # People contacts app
    'Microsoft.PowerAutomateDesktop'           # Power Automate Desktop (RPA tool)
    # 'Microsoft.Recall'                         # tiny11-automated: Windows Recall (older package name)
    # 'Microsoft.ScreenSketch'                   # tiny11-automated: Snip & Sketch screenshot tool
    'Microsoft.SkypeApp'                       # Skype UWP app
    'Microsoft.StartExperiencesApp'            # Start menu experiences / recommendations app
    # 'Microsoft.StorePurchaseApp'               # tiny11-automated: Microsoft Store purchase/checkout helper
    'Microsoft.Todos'                          # Microsoft To Do task manager
    'Microsoft.Wallet'                         # Microsoft Wallet (NFC payments)
    # 'Microsoft.WebMediaExtensions'             # tiny11-automated: web media codec extensions
    'Microsoft.Windows.DevHome'                # Dev Home developer dashboard app
    # 'Microsoft.Windows.AI'                     # tiny11-automated: Windows AI platform component
    # 'Microsoft.Windows.AIFabric'                # tiny11-automated: Windows AI Fabric runtime
    'Microsoft.Windows.Copilot'                # Windows Copilot integration
    # 'Microsoft.Windows.CoreAI'                 # tiny11-automated: Windows Core AI component
    # 'Microsoft.Windows.Photos'                  # tiny11-automated: Photos app
    # 'Microsoft.Windows.Recall'                  # tiny11-automated: Windows Recall (current package name)
    'Microsoft.Windows.Teams'                  # Microsoft Teams (Chat) integration
    'Microsoft.WindowsAlarms'                  # Alarms & Clock app
    'Microsoft.WindowsCamera'                  # Camera app
    'microsoft.windowscommunicationsapps'      # Mail and Calendar apps
    'Microsoft.WindowsFeedbackHub'             # Feedback Hub app
    'Microsoft.WindowsMaps'                    # Windows Maps app
    'Microsoft.WindowsSoundRecorder'           # Sound Recorder / Voice Recorder app
    # 'Microsoft.WindowsTerminal'                # Windows Terminal app
    # 'MicrosoftWindows.Client.WebExperience'    # tiny11-automated: Widgets board
    'Microsoft.Xbox.TCUI'                      # Xbox Title-Callable UI (game overlay helper)
    'Microsoft.XboxApp'                        # Xbox Console Companion app
    'Microsoft.XboxGameOverlay'                # Xbox Game Overlay (in-game UI)
    'Microsoft.XboxGamingOverlay'              # Xbox Game Bar overlay
    'Microsoft.XboxIdentityProvider'           # Xbox Identity Provider (sign-in service)
    'Microsoft.XboxSpeechToTextOverlay'        # Xbox speech-to-text overlay (accessibility)
    'Microsoft.YourPhone'                      # Phone Link (formerly Your Phone) app
    'Microsoft.ZuneMusic'                      # Groove Music / Media Player (Zune Music)
    'Microsoft.ZuneVideo'                      # Movies & TV app (Zune Video)
    'MicrosoftCorporationII.MicrosoftFamily'   # Microsoft Family Safety app
    'MicrosoftCorporationII.QuickAssist'       # Quick Assist remote help app
    'MSTeams'                                  # Microsoft Teams (new/MSIX variant)
    'MicrosoftTeams'                           # Microsoft Teams (legacy variant)
    'Microsoft.549981C3F5F10'                  # Cortana app (internal package name)
)

$scheduledTaskPaths = @(
    'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'  # Collects app compatibility telemetry data for Microsoft
    'Microsoft\Windows\Customer Experience Improvement Program'                   # CEIP - sends usage data to Microsoft (removes entire folder)
    'Microsoft\Windows\Application Experience\ProgramDataUpdater'                 # Updates compatibility telemetry data cache
    'Microsoft\Windows\Chkdsk\Proxy'                                              # Chkdsk proxy - notifies user about filesystem errors
    'Microsoft\Windows\Windows Error Reporting\QueueReporting'                    # Sends crash/error reports to Microsoft
    # 'Microsoft\Windows\InstallService'                                            # winutil: Store/Push-Button-Reset install service tasks
    # 'Microsoft\Windows\UpdateOrchestrator'                                        # winutil: Update Orchestrator scheduled tasks
    # 'Microsoft\Windows\UpdateAssistant'                                           # winutil: Update Assistant scheduled tasks
    # 'Microsoft\Windows\WaaSMedic'                                                 # winutil: WaaS Medic self-repair scheduled tasks
    # 'Microsoft\Windows\WindowsUpdate'                                             # winutil: Windows Update scheduled tasks
    # 'Microsoft\WindowsUpdate'                                                     # winutil: legacy Windows Update scheduled tasks
)

# Core-build-only: Windows system component (CBS/FoD) packages, removed via
# Remove-SystemPackages under -Core. Not used by the serviceable build. Four more
# per-language patterns (handwriting/OCR/speech/text-to-speech) are added automatically
# from the detected image language.
$systemPackagePatterns = @(
    'Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35'      # Internet Explorer 11 legacy browser (optional compatibility feature)
    'Microsoft-Windows-Kernel-LA57-FoD-Package~31bf3856ad364e35~amd64'          # 5-Level Paging (LA57) kernel support - not needed for most hardware
    'Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35'                    # Windows Media Player legacy app
    'Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~31bf3856ad364e35' # Extended wallpaper collection (extra desktop backgrounds)
    'Windows-Defender-Client-Package~31bf3856ad364e35~'                        # Windows Defender antivirus client package
    'Microsoft-Windows-WordPad-FoD-Package~'                                   # WordPad rich text editor (legacy app)
    'Microsoft-Windows-TabletPCMath-Package~'                                  # Tablet PC Math Input Panel (equation handwriting)
    'Microsoft-Windows-StepsRecorder-Package~'                                 # Steps Recorder (Problem Steps Recorder - PSR)
)

# REQUIRED CUSTOMIZATION STEP (do not comment out)
Remove-ProvisionedAppPackages -ImagePath $script:mountDir -PackagePrefixes $appPackagePrefixes   # REQUIRED: apply package removal list defined above

# OPTIONAL FILE CUSTOMIZATION STEPS (safe to comment out)
Remove-OneDriveSetup -MountDir $script:mountDir -AdminGroupName $script:adminGroupName            # OPTIONAL: remove OneDrive setup executable
Remove-IsoSupportFolder -ContentRoot $script:tiny11Root                                           # OPTIONAL: drop support\ folder to shrink final ISO

# CORE-BUILD-ONLY FILE CUSTOMIZATION (needs no registry hives; runs before Mount-OfflineRegistryHives)
if ($Core) {
    Remove-SystemPackages -MountDir $script:mountDir -PackagePatterns $systemPackagePatterns -LanguageCode $script:languageCode
    if (Confirm-DotNet35Enablement) {
        Enable-DotNet35 -MountDir $script:mountDir -SourceRoot $script:tiny11Root
    }
    Remove-EdgeWebViewWinSxS -MountDir $script:mountDir -Architecture $script:architecture -AdminGroupName $script:adminGroupName
    Remove-WindowsRecoveryEnvironment -MountDir $script:mountDir
    Compress-WinSxS -MountDir $script:mountDir -Architecture $script:architecture -AdminGroupName $script:adminGroupName
}

# REQUIRED REGISTRY PHASE BOUNDARIES (do not comment out)
Mount-OfflineRegistryHives                                                                        # REQUIRED: load offline hives before registry tweaks

# OPTIONAL REGISTRY TWEAKS (safe to comment out)
Invoke-HardwareBypassStrategy                                                                     # REQUIRED: apply hardware bypass chosen via -BypassMode (default: None = no-op)
# Remove-Edge -MountDir $script:mountDir -AdminGroupName $script:adminGroupName                   # OPTIONAL: remove Edge files and offline uninstall entries (always applied under -Core, below)
Disable-SponsoredApps                                                                             # OPTIONAL: disable suggested/sponsored consumer content
Enable-LocalAccountOOBE -MountDir $script:mountDir                                                # OPTIONAL: enable local account path during OOBE
Disable-ReservedStorage                                                                           # OPTIONAL: disable reserved storage allocation
Disable-BitLockerAutoEncryption                                                                   # OPTIONAL: prevent automatic device encryption
Disable-ChatIcon                                                                                  # OPTIONAL: hide chat/teams taskbar icon
Disable-OneDriveSync                                                                              # OPTIONAL: disable OneDrive sync policy
Disable-Telemetry                                                                                 # OPTIONAL: reduce telemetry and data collection
Disable-DevHomeOutlookInstall                                                                     # OPTIONAL: prevent automatic Dev Home/Outlook install
Disable-Copilot                                                                                   # OPTIONAL: disable Copilot and related integrations
Disable-TeamsInstall                                                                              # OPTIONAL: prevent Teams auto-installation
Disable-NewOutlook                                                                                # OPTIONAL: block new Outlook app execution
# Disable-WindowsUpdate                                                                            # OPTIONAL: aggressive WU suppression - see docs/tweak-catalog.md (always applied under -Core, below)
# Disable-DiagnosticServices                                                                       # OPTIONAL: disable DiagTrack/WerSvc/PcaSvc/SysMain services
# Disable-WindowsAI                                                                                # OPTIONAL: disable Windows AI / Recall data analysis

if ($InjectVirtioDrivers -and -not $SkipVirtioGuestTools) {
    Install-VirtioGuestToolsAtFirstLogon -MountDir $script:mountDir -VirtioRoot $script:virtioRoot  # SWITCH-GATED: -InjectVirtioDrivers (and not -SkipVirtioGuestTools)
}

# CORE-BUILD-ONLY REGISTRY TWEAKS (need offline hives loaded)
if ($Core) {
    Remove-Edge -MountDir $script:mountDir -AdminGroupName $script:adminGroupName
    Disable-WindowsUpdate
    Disable-WindowsDefender
}

Remove-ScheduledTasks -MountDir $script:mountDir -TaskPaths $scheduledTaskPaths                  # OPTIONAL: remove selected telemetry/reporting task files

# REQUIRED REGISTRY PHASE BOUNDARY (do not comment out)
Dismount-OfflineRegistryHives                                                                     # REQUIRED: unload offline hives before image finalization

# REQUIRED FINALIZE/BUILD STEPS (do not comment out)
Complete-InstallImage      # REQUIRED: cleanup, unmount, export updated install image (exports to install.esd instead under -Core)
Update-BootImage           # REQUIRED: mount boot.wim once for bypass tweaks and (Core) the setup CmdLine key (driver injection happens earlier, into install.wim + $WinpeDriver$ - not here)
New-Tiny11Iso              # REQUIRED: build final ISO using oscdimg
Write-BuildInfo -OutputPath (Join-Path $PSScriptRoot 'output\asl-win11-buildinfo.json')  # OPTIONAL: emit build metadata JSON
Invoke-Tiny11Cleanup       # REQUIRED: remove temp files and eject mounted source media

Stop-Transcript  # REQUIRED: stop transcript logging
exit             # REQUIRED: end script
} catch {
    # REQUIRED: emergency cleanup so a mid-pipeline failure doesn't leave images mounted
    # or registry hives loaded, which would block the next run.
    Write-Output "FATAL ERROR: $_"
    Write-Output "Stack trace: $($_.ScriptStackTrace)"
    Invoke-Tiny11EmergencyCleanup
    try { Stop-Transcript } catch {}
    exit 1
}
