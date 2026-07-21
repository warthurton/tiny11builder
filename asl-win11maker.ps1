<#
.SYNOPSIS
    Main runner script to build a trimmed-down Windows 11 image.

.DESCRIPTION
    This runner imports reusable functions from asl-win11maker.functions.ps1 and
    executes the build workflow in a clear, commentable function list.

.PARAMETER ISO
    Drive letter given to the mounted iso (eg: E)

.PARAMETER SCRATCH
    Drive letter of the desired scratch disk (eg: D)

.EXAMPLE
    .\asl-win11maker.ps1 E D
    .\asl-win11maker.ps1 -ISO E -SCRATCH D
#>

#---------[ Parameters ]---------#
param (
    [ValidatePattern('^[c-zC-Z]$')][string]$ISO,
    [ValidatePattern('^[c-zC-Z]$')][string]$SCRATCH
)

if (-not $SCRATCH) {
    $script:BuildScratchRoot = $PSScriptRoot -replace '[\\]+$', ''
} else {
    $script:BuildScratchRoot = $SCRATCH + ":"
}

$script:EntryScriptPath = $PSCommandPath

$functionsScriptPath = Join-Path $PSScriptRoot 'asl-win11maker.functions.ps1'
if (-not (Test-Path -Path $functionsScriptPath)) {
    Write-Error "Required function library not found: $functionsScriptPath"
    Read-Host 'Press Enter to exit' | Out-Null
    exit 1
}

. $functionsScriptPath

#---------[ Main Workflow ]---------#
# REQUIRED SETUP STEPS (do not comment out)
Confirm-ExecutionPolicy        # REQUIRED: ensure script execution policy allows running
Confirm-AdminPrivileges        # REQUIRED: relaunch as admin if needed
Confirm-AutounattendXml        # REQUIRED: ensure autounattend.xml is present locally
Initialize-Tiny11Session       # REQUIRED: initialize paths, transcript, and session state
Resolve-SourceDriveLetter      # REQUIRED: resolve/validate source ISO drive letter
Confirm-InstallWimSource       # REQUIRED: ensure install.wim exists (or convert install.esd)
Copy-SourceImageFiles          # REQUIRED: copy source media into scratch working folder
Select-InstallImageIndex       # REQUIRED: choose the install image index to modify
Mount-InstallImage             # REQUIRED: mount install.wim to working directory
Show-ImageMetadata             # REQUIRED: print selected image language/architecture info

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
    # 'Microsoft.MSPaint'                        # Paint 3D (legacy MSPaint UWP)
    'Microsoft.Office.OneNote'                 # OneNote UWP app
    'Microsoft.OfficePushNotificationUtility'  # Office push notification background service
    'Microsoft.OutlookForWindows'              # New Outlook for Windows app
    # 'Microsoft.Paint'                          # Paint app (modern)
    'Microsoft.People'                         # People contacts app
    'Microsoft.PowerAutomateDesktop'           # Power Automate Desktop (RPA tool)
    'Microsoft.SkypeApp'                       # Skype UWP app
    'Microsoft.StartExperiencesApp'            # Start menu experiences / recommendations app
    'Microsoft.Todos'                          # Microsoft To Do task manager
    'Microsoft.Wallet'                         # Microsoft Wallet (NFC payments)
    'Microsoft.Windows.DevHome'                # Dev Home developer dashboard app
    'Microsoft.Windows.Copilot'                # Windows Copilot integration
    'Microsoft.Windows.Teams'                  # Microsoft Teams (Chat) integration
    'Microsoft.WindowsAlarms'                  # Alarms & Clock app
    'Microsoft.WindowsCamera'                  # Camera app
    'microsoft.windowscommunicationsapps'      # Mail and Calendar apps
    'Microsoft.WindowsFeedbackHub'             # Feedback Hub app
    'Microsoft.WindowsMaps'                    # Windows Maps app
    'Microsoft.WindowsSoundRecorder'           # Sound Recorder / Voice Recorder app
    # 'Microsoft.WindowsTerminal'                # Windows Terminal app
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
)

# REQUIRED CUSTOMIZATION STEP (do not comment out)
Remove-ProvisionedAppPackages -ImagePath $script:mountDir -PackagePrefixes $appPackagePrefixes   # REQUIRED: apply package removal list defined above

# OPTIONAL FILE CUSTOMIZATION STEPS (safe to comment out)
Remove-OneDriveSetup -MountDir $script:mountDir -AdminGroupName $script:adminGroupName            # OPTIONAL: remove OneDrive setup executable

# REQUIRED REGISTRY PHASE BOUNDARIES (do not comment out)
Mount-OfflineRegistryHives                                                                        # REQUIRED: load offline hives before registry tweaks

# OPTIONAL REGISTRY TWEAKS (safe to comment out)
# Set-BypassHardwareChecks                                                                        # OPTIONAL: apply setup hardware bypass keys to install.wim
# Remove-Edge -MountDir $script:mountDir -AdminGroupName $script:adminGroupName                   # OPTIONAL: remove Edge files and offline uninstall entries
Disable-SponsoredApps                                                                             # OPTIONAL: disable suggested/sponsored consumer content
Enable-LocalAccountOOBE -MountDir $script:mountDir -ScriptRoot $PSScriptRoot                     # OPTIONAL: enable local account path during OOBE
Disable-ReservedStorage                                                                           # OPTIONAL: disable reserved storage allocation
Disable-BitLockerAutoEncryption                                                                   # OPTIONAL: prevent automatic device encryption
Disable-ChatIcon                                                                                  # OPTIONAL: hide chat/teams taskbar icon
Disable-OneDriveSync                                                                              # OPTIONAL: disable OneDrive sync policy
Disable-Telemetry                                                                                 # OPTIONAL: reduce telemetry and data collection
Disable-DevHomeOutlookInstall                                                                     # OPTIONAL: prevent automatic Dev Home/Outlook install
Disable-Copilot                                                                                   # OPTIONAL: disable Copilot and related integrations
Disable-TeamsInstall                                                                              # OPTIONAL: prevent Teams auto-installation
Disable-NewOutlook                                                                                # OPTIONAL: block new Outlook app execution
Remove-ScheduledTasks -MountDir $script:mountDir -TaskPaths $scheduledTaskPaths                  # OPTIONAL: remove selected telemetry/reporting task files

# REQUIRED REGISTRY PHASE BOUNDARY (do not comment out)
Dismount-OfflineRegistryHives                                                                     # REQUIRED: unload offline hives before image finalization

# REQUIRED FINALIZE/BUILD STEPS (do not comment out)
Complete-InstallImage      # REQUIRED: cleanup, unmount, and export updated install image
Set-BootImageBypassTweaks  # REQUIRED: apply setup bypass tweaks in boot.wim index 2
New-Tiny11Iso              # REQUIRED: build final ISO using oscdimg
Invoke-Tiny11Cleanup       # REQUIRED: remove temp files and eject mounted source media

Stop-Transcript  # REQUIRED: stop transcript logging
exit             # REQUIRED: end script
