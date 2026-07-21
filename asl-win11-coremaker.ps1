if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Host "Your current PowerShell Execution Policy is set to Restricted, which prevents scripts from running. Do you want to change it to RemoteSigned? (yes/no)"
    $response = Read-Host
    if ($response -eq 'yes') {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
    } else {
        Write-Host "The script cannot be run without changing the execution policy. Exiting..."
        exit
    }
}

# Check and run the script as admin if required
$adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator
if (! $myWindowsPrincipal.IsInRole($adminRole)) {
    Write-Host "Restarting asl-win11 image creator as admin in a new window, you can close this one."
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell";
    $newProcess.Arguments = $myInvocation.MyCommand.Definition;
    $newProcess.Verb = "runas";
    [System.Diagnostics.Process]::Start($newProcess);
    exit
}
$logsDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
Start-Transcript -Path "$logsDir\asl-win11-core.log"
# Ask the user for input
Write-Host "Welcome to asl-win11 core builder! BETA 09-05-25"
Write-Host "This script generates a significantly reduced Windows 11 image. However, it's not suitable for regular use due to its lack of serviceability - you can't add languages, updates, or features post-creation. asl-win11 Core is not a full Windows 11 substitute but a rapid testing or development tool, potentially useful for VM environments."
Write-Host "Do you want to continue? (y/n)"
$input = Read-Host

if ($input -eq 'y') {
    Write-Host "Off we go..."
    Start-Sleep -Seconds 3
    Clear-Host

    $workDir = Join-Path $PSScriptRoot 'work'
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    $mainOSDrive = $workDir
    $hostArchitecture = $Env:PROCESSOR_ARCHITECTURE
    New-Item -ItemType Directory -Force -Path "$mainOSDrive\asl-win11\sources" >null
    $DriveLetter = Read-Host "Please enter the drive letter for the Windows 11 image"
    $DriveLetter = $DriveLetter + ":"

    if ((Test-Path "$DriveLetter\sources\boot.wim") -eq $false -or (Test-Path "$DriveLetter\sources\install.wim") -eq $false) {
        if ((Test-Path "$DriveLetter\sources\install.esd") -eq $true) {
            Write-Host "Found install.esd, converting to install.wim..."
            &  'dism' '/English' "/Get-WimInfo" "/wimfile:$DriveLetter\sources\install.esd"
            $index = Read-Host "Please enter the image index"
            Write-Host ' '
            Write-Host 'Converting install.esd to install.wim. This may take a while...'
            & 'DISM' /Export-Image /SourceImageFile:"$DriveLetter\sources\install.esd" /SourceIndex:$index /DestinationImageFile:"$mainOSDrive\asl-win11\sources\install.wim" /Compress:max /CheckIntegrity
        } else {
            Write-Host "Can't find Windows OS Installation files in the specified Drive Letter.."
            Write-Host "Please enter the correct DVD Drive Letter.."
            exit
        }
    }

    Write-Host "Copying Windows image..."
    Copy-Item -Path "$DriveLetter\*" -Destination "$mainOSDrive\asl-win11" -Recurse -Force > null
    Set-ItemProperty -Path "$mainOSDrive\asl-win11\sources\install.esd" -Name IsReadOnly -Value $false > $null 2>&1
    Remove-Item "$mainOSDrive\asl-win11\sources\install.esd" > $null 2>&1
    Write-Host "Copy complete!"
    Start-Sleep -Seconds 2
    Clear-Host
    Write-Host "Getting image information:"
    &  'dism' '/English' "/Get-WimInfo" "/wimfile:$mainOSDrive\asl-win11\sources\install.wim"
    $index = Read-Host "Please enter the image index"
    Write-Host "Mounting Windows image. This may take a while."
    $wimFilePath = "$($env:SystemDrive)\asl-win11\sources\install.wim" 
    & takeown "/F" $wimFilePath 
    & icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
    try {
        Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction Stop
    } catch {
        # This block will catch the error and suppress it.
    }
    New-Item -ItemType Directory -Force -Path "$mainOSDrive\scratchdir" > $null
    & dism /English "/mount-image" "/imagefile:$($env:SystemDrive)\asl-win11\sources\install.wim" "/index:$index" "/mountdir:$($env:SystemDrive)\scratchdir"

    $imageIntl = & dism /English /Get-Intl "/Image:$($env:SystemDrive)\scratchdir"
    $languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

    if ($languageLine) {
        $languageCode = $Matches[1]
        Write-Host "Default system UI language code: $languageCode"
    } else {
        Write-Host "Default system UI language code not found."
    }

    $imageInfo = & 'dism' '/English' '/Get-WimInfo' "/wimFile:$($env:SystemDrive)\asl-win11\sources\install.wim" "/index:$index"
    $lines = $imageInfo -split '\r?\n'

    foreach ($line in $lines) {
        if ($line -like '*Architecture : *') {
            $architecture = $line -replace 'Architecture : ', ''
            # If the architecture is x64, replace it with amd64
            if ($architecture -eq 'x64') {
                $architecture = 'amd64'
            }
            Write-Host "Architecture: $architecture"
            break
        }
    }

    if (-not $architecture) {
        Write-Host "Architecture information not found."
    }

    Write-Host "Mounting complete! Performing removal of applications..."

    $packages = & 'dism' '/English' "/image:$($env:SystemDrive)\scratchdir" '/Get-ProvisionedAppxPackages' |
        ForEach-Object {
            if ($_ -match 'PackageName : (.*)') {
                $matches[1]
            }
        }
    # List of provisioned UWP/MSIX app package prefixes to remove from the image.
    # Each entry matches the beginning of a package name. Uses "_" suffix for exact prefix matching.
    $packagePrefixes = 'Clipchamp.Clipchamp_',                       # Clipchamp video editor
    'Microsoft.BingNews_',                        # Microsoft News (Bing News)
    'Microsoft.BingWeather_',                     # Microsoft Weather (Bing Weather)
    'Microsoft.GamingApp_',                       # Xbox Gaming App (Game Pass hub)
    'Microsoft.GetHelp_',                         # Get Help support app
    'Microsoft.Getstarted_',                      # Tips / Get Started app
    'Microsoft.MicrosoftOfficeHub_',              # Office Hub ("Get Office" / Microsoft 365 app)
    'Microsoft.MicrosoftSolitaireCollection_',    # Microsoft Solitaire Collection game
    'Microsoft.People_',                          # People contacts app
    'Microsoft.PowerAutomateDesktop_',            # Power Automate Desktop (RPA tool)
    'Microsoft.Todos_',                           # Microsoft To Do task manager
    'Microsoft.WindowsAlarms_',                   # Alarms & Clock app
    'microsoft.windowscommunicationsapps_',       # Mail and Calendar apps
    'Microsoft.WindowsFeedbackHub_',              # Feedback Hub app
    'Microsoft.WindowsMaps_',                     # Windows Maps app
    'Microsoft.WindowsSoundRecorder_',            # Sound Recorder / Voice Recorder app
    'Microsoft.Xbox.TCUI_',                       # Xbox Title-Callable UI (game overlay helper)
    'Microsoft.XboxGamingOverlay_',               # Xbox Game Bar overlay
    'Microsoft.XboxGameOverlay_',                 # Xbox Game Overlay (in-game UI)
    'Microsoft.XboxSpeechToTextOverlay_',         # Xbox speech-to-text overlay (accessibility)
    'Microsoft.YourPhone_',                       # Phone Link (formerly Your Phone) app
    'Microsoft.ZuneMusic_',                       # Groove Music / Media Player (Zune Music)
    'Microsoft.ZuneVideo_',                       # Movies & TV app (Zune Video)
    'MicrosoftCorporationII.MicrosoftFamily_',    # Microsoft Family Safety app
    'MicrosoftCorporationII.QuickAssist_',        # Quick Assist remote help app
    'MicrosoftTeams_',                            # Microsoft Teams (legacy variant)
    'Microsoft.549981C3F5F10_',                   # Cortana app (internal package name)
    'Microsoft.Windows.Copilot',                  # Windows Copilot AI assistant
    'MSTeams_',                                   # Microsoft Teams (new/MSIX variant)
    'Microsoft.OutlookForWindows_',               # New Outlook for Windows app
    'Microsoft.Windows.Teams_',                   # Microsoft Teams integration
    'Microsoft.Copilot_'                          # Microsoft Copilot app

    $packagesToRemove = $packages | Where-Object {
        $packageName = $_
        $packagePrefixes -contains ($packagePrefixes | Where-Object { $packageName -like "$_*" })
    }
    foreach ($package in $packagesToRemove) {
        Write-Host "Removing $package :"
        & 'dism' '/English' "/image:$($env:SystemDrive)\scratchdir" '/Remove-ProvisionedAppxPackage' "/PackageName:$package"
    }

    Write-Host "Removing of system apps complete! Now proceeding to removal of system packages..."
    Start-Sleep -Seconds 1
    Clear-Host

    $scratchDir = "$($env:SystemDrive)\scratchdir"
    # List of Windows system package (CBS) patterns to remove from the image.
    # These are Feature-on-Demand (FoD) and optional component packages removed via DISM.
    $packagePatterns = @(
        "Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35",           # Internet Explorer 11 legacy browser (optional compatibility feature)
        "Microsoft-Windows-Kernel-LA57-FoD-Package~31bf3856ad364e35~amd64",              # 5-Level Paging (LA57) kernel support — not needed for most hardware
        "Microsoft-Windows-LanguageFeatures-Handwriting-$languageCode-Package~31bf3856ad364e35",  # Handwriting recognition for detected language
        "Microsoft-Windows-LanguageFeatures-OCR-$languageCode-Package~31bf3856ad364e35",          # Optical Character Recognition for detected language
        "Microsoft-Windows-LanguageFeatures-Speech-$languageCode-Package~31bf3856ad364e35",       # Speech recognition for detected language
        "Microsoft-Windows-LanguageFeatures-TextToSpeech-$languageCode-Package~31bf3856ad364e35", # Text-to-Speech engine for detected language
        "Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35",                        # Windows Media Player legacy app
        "Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~31bf3856ad364e35",     # Extended wallpaper collection (extra desktop backgrounds)
        "Windows-Defender-Client-Package~31bf3856ad364e35~",                             # Windows Defender antivirus client package
        "Microsoft-Windows-WordPad-FoD-Package~",                                        # WordPad rich text editor (legacy app)
        "Microsoft-Windows-TabletPCMath-Package~",                                       # Tablet PC Math Input Panel (equation handwriting)
        "Microsoft-Windows-StepsRecorder-Package~"                                       # Steps Recorder (Problem Steps Recorder — PSR)
    )

    # Get all packages
    $allPackages = & dism /image:$scratchDir /Get-Packages /Format:Table
    $allPackages = $allPackages -split "`n" | Select-Object -Skip 1

    foreach ($packagePattern in $packagePatterns) {
        # Filter the packages to remove
        $packagesToRemove = $allPackages | Where-Object { $_ -like "$packagePattern*" }

        foreach ($package in $packagesToRemove) {
            # Extract the package identity
            $packageIdentity = ($package -split "\s+")[0]

            Write-Host "Removing $packageIdentity..."
            & dism /image:$scratchDir /Remove-Package /PackageName:$packageIdentity 
        }
    }

    Write-Host "Do you want to enable .NET 3.5? This cannot be done after the image has been created! (y/n)"
    $input = Read-Host

    if ($input -eq 'y') {
        Write-Host "Enabling .NET 3.5..."
        & 'dism'  "/image:$scratchDir" '/enable-feature' '/featurename:NetFX3' '/All' "/source:$($env:SystemDrive)\asl-win11\sources\sxs" 
        Write-Host ".NET 3.5 has been enabled."
    } elseif ($input -eq 'n') {
        Write-Host "You chose not to enable .NET 3.5. Continuing..."
    } else {
        Write-Host "Invalid input. Please enter 'y' to enable .NET 3.5 or 'n' to continue without installing .net 3.5."
    }
    ## --- FILE/SOFTWARE REMOVALS --- ##

    # Remove Microsoft Edge browser installation files
    Write-Host "Removing Edge:"
    Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\Edge" -Recurse -Force >null          # Edge browser main installation directory
    Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse -Force >null     # Edge auto-update service
    Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\EdgeCore" -Recurse -Force >null       # Edge core engine / runtime binaries

    # Remove Edge WebView2 from WinSxS (architecture-specific side-by-side assembly)
    if ($architecture -eq 'amd64') {
        $folderPath = Get-ChildItem -Path "$mainOSDrive\scratchdir\Windows\WinSxS" -Filter "amd64_microsoft-edge-webview_31bf3856ad364e35*" -Directory | Select-Object -ExpandProperty FullName

        if ($folderPath) {
            & 'takeown' '/f' $folderPath '/r' >null
            & icacls $folderPath  "/grant" "$($adminGroup.Value):(F)" '/T' '/C' >null
            Remove-Item -Path $folderPath -Recurse -Force >null
        } else {
            Write-Host "Folder not found."
        }
    } elseif ($architecture -eq 'arm64') {
        $folderPath = Get-ChildItem -Path "$mainOSDrive\scratchdir\Windows\WinSxS" -Filter "arm64_microsoft-edge-webview_31bf3856ad364e35*" -Directory | Select-Object -ExpandProperty FullName >null

        if ($folderPath) {
            & 'takeown' '/f' $folderPath '/r'>null
            & icacls $folderPath  "/grant" "$($adminGroup.Value):(F)" '/T' '/C' >null
            Remove-Item -Path $folderPath -Recurse -Force >null
        } else {
            Write-Host "Folder not found."
        }
    } else {
        Write-Host "Unknown architecture: $architecture"
    }
    # Remove Edge WebView2 runtime from System32 (embedded browser component used by some apps)
    & 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/r'
    & 'icacls' "$mainOSDrive\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/grant' "$($adminGroup.Value):(F)" '/T' '/C'
    Remove-Item -Path "$mainOSDrive\scratchdir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force

    # Remove Windows Recovery Environment (WinRE) — saves ~500 MB but disables recovery features
    # A placeholder empty file is created to prevent errors from components expecting the file
    Write-Host "Removing WinRE"
    & 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\System32\Recovery" '/r'
    & 'icacls' "$mainOSDrive\scratchdir\Windows\System32\Recovery" '/grant' 'Administrators:F' '/T' '/C'
    Remove-Item -Path "$mainOSDrive\scratchdir\Windows\System32\Recovery\winre.wim" -Recurse -Force
    New-Item -Path "$mainOSDrive\scratchdir\Windows\System32\Recovery\winre.wim" -ItemType File -Force

    # Remove OneDrive cloud storage client installer
    # Remove OneDrive cloud storage client installer
    Write-Host "Removing OneDrive:"
    & 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" >null
    & 'icacls' "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' >null
    Remove-Item -Path "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" -Force >null
    Write-Host "Removal complete!"
    Start-Sleep -Seconds 2
    Clear-Host

    ## --- WINSXS STRIPPING: Reduce image size by keeping only essential side-by-side assemblies --- ##
    ## WARNING: This makes the image non-serviceable (cannot add updates, languages, or features later)
    Write-Host "Taking ownership of the WinSxS folder. This might take a while..."
    & 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\WinSxS" '/r'
    & 'icacls' "$mainOSDrive\scratchdir\Windows\WinSxS" '/grant' "$($adminGroup.Value):(F)" '/T' '/C'
    Write-Host "Complete!"
    Start-Sleep -Seconds 2
    Clear-Host
    Write-Host "Preparing..."
    $folderPath = Join-Path -Path $mainOSDrive -ChildPath "\scratchdir\Windows\WinSxS_edit"
    $sourceDirectory = "$mainOSDrive\scratchdir\Windows\WinSxS"
    $destinationDirectory = "$mainOSDrive\scratchdir\Windows\WinSxS_edit"
    New-Item -Path $folderPath -ItemType Directory
    if ($architecture -eq "amd64") {
        # Only these critical WinSxS directories are preserved for amd64 architecture.
        # Everything else in WinSxS is deleted to dramatically reduce image size.
        # Kept: Visual C++ runtimes, common controls, GDI+, servicing stack, catalogs, manifests
        $dirsToCopy = @(
            "x86_microsoft.windows.common-controls_6595b64144ccf1df_*",
            "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*",    
            "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
            "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
            "x86_microsoft-windows-s..ngstack-onecorebase_31bf3856ad364e35_*",
            "x86_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
            "x86_microsoft-windows-servicingstack_31bf3856ad364e35_*",
            "x86_microsoft-windows-servicingstack-inetsrv_*",
            "x86_microsoft-windows-servicingstack-onecore_*",
            "amd64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
            "amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
            "amd64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
            "amd64_microsoft.windows.common-controls_6595b64144ccf1df_*",
            "amd64_microsoft.windows.gdiplus_6595b64144ccf1df_*",
            "amd64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
            "amd64_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
            "amd64_microsoft-windows-s..stack-inetsrv-extra_31bf3856ad364e35_*",
            "amd64_microsoft-windows-s..stack-msg.resources_31bf3856ad364e35_*",
            "amd64_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
            "amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*",
            "amd64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*",
            "amd64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*",
            "amd64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
            "Catalogs",
            "FileMaps",
            "Fusion",
            "InstallTemp",
            "Manifests",
            "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
            "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
            "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
            "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
        )
        # Copy each directory
        foreach ($dir in $dirsToCopy) {
            $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory
            foreach ($sourceDir in $sourceDirs) {
                $destDir = Join-Path -Path $destinationDirectory -ChildPath $sourceDir.Name
                Write-Host "Copying $sourceDir.FullName to $destDir"
                Copy-Item -Path $sourceDir.FullName -Destination $destDir -Recurse -Force
            }
        }
    } elseif ($architecture -eq "arm64") {
        # Only these critical WinSxS directories are preserved for arm64 architecture.
        # Kept: Visual C++ runtimes, common controls, GDI+, servicing stack, catalogs, manifests
        $dirsToCopy = @(
            "arm64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
            "Catalogs"
            "FileMaps"
            "Fusion"
            "InstallTemp"
            "Manifests"
            "SettingsManifests"
            "Temp"
            "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*"
            "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*"
            "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
            "x86_microsoft.windows.common-controls_6595b64144ccf1df_*"
            "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*"
            "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*"
            "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*"
            "arm_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
            "arm_microsoft.windows.common-controls_6595b64144ccf1df_*"
            "arm_microsoft.windows.gdiplus_6595b64144ccf1df_*"
            "arm_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*"
            "arm_microsoft.windows.isolationautomation_6595b64144ccf1df_*"
            "arm64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*"
            "arm64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*"
            "arm64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
            "arm64_microsoft.windows.common-controls_6595b64144ccf1df_*"
            "arm64_microsoft.windows.gdiplus_6595b64144ccf1df_*"
            "arm64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*"
            "arm64_microsoft.windows.isolationautomation_6595b64144ccf1df_*"
            "arm64_microsoft-windows-servicing-adm_31bf3856ad364e35_*"
            "arm64_microsoft-windows-servicingcommon_31bf3856ad364e35_*"
            "arm64_microsoft-windows-servicing-onecore-uapi_31bf3856ad364e35_*"
            "arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*"
            "arm64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*"
            "arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*"
        )
    }
    foreach ($dir in $dirsToCopy) {
        $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory
        foreach ($sourceDir in $sourceDirs) {
            $destDir = Join-Path -Path $destinationDirectory -ChildPath $sourceDir.Name
            Write-Host "Copying $sourceDir.FullName to $destDir"
            Copy-Item -Path $sourceDir.FullName -Destination $destDir -Recurse -Force
        }
    }  


    # Delete original WinSxS and replace with stripped version containing only essential assemblies
    Write-Host "Deleting WinSxS. This may take a while..."
    Remove-Item -Path $mainOSDrive\scratchdir\Windows\WinSxS -Recurse -Force

    Rename-Item -Path $mainOSDrive\scratchdir\Windows\WinSxS_edit -NewName $mainOSDrive\scratchdir\Windows\WinSxS
    Write-Host "Complete!"

    Write-Host "Loading registry..."
    reg load HKLM\zCOMPONENTS $ScratchDisk\scratchdir\Windows\System32\config\COMPONENTS | Out-Null
    reg load HKLM\zDEFAULT $ScratchDisk\scratchdir\Windows\System32\config\default | Out-Null
    reg load HKLM\zNTUSER $ScratchDisk\scratchdir\Users\Default\ntuser.dat | Out-Null
    reg load HKLM\zSOFTWARE $ScratchDisk\scratchdir\Windows\System32\config\SOFTWARE | Out-Null
    reg load HKLM\zSYSTEM $ScratchDisk\scratchdir\Windows\System32\config\SYSTEM | Out-Null

    ## --- REGISTRY: Bypass hardware requirements for Windows 11 --- ##
    Write-Host "Bypassing system requirements(on the system image):"
    # Suppress "unsupported hardware" watermark/notification on desktop for default user profile
    & 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    & 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Same suppression for the NTUSER default profile (new users inherit these)
    & 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    & 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # LabConfig keys: bypass individual hardware checks during Windows Setup
    & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null       # Skip CPU compatibility check
    & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null       # Skip minimum 4 GB RAM requirement
    & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null # Skip Secure Boot requirement
    & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null   # Skip 64 GB minimum storage requirement
    & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null       # Skip TPM 2.0 requirement
    # Allow in-place upgrades on systems without TPM 2.0 or supported CPU
    & 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

    ## --- REGISTRY: Disable sponsored/suggested apps and content delivery --- ##
    Write-Host "Disabling Sponsored Apps:"
    # Disable OEM pre-installed app suggestions in Start menu
    & 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'OemPreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable pre-installed app promotions
    & 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'PreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable silent installation of suggested apps in the background
    & 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SilentInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable Windows Consumer Features (blocks Microsoft consumer app suggestions via policy)
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableWindowsConsumerFeatures' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
    # Disable content delivery entirely (prevents all CDM-driven content like spotlight, tips)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'ContentDeliveryAllowed' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Clear Start menu pinned layout to remove default promoted apps
    & 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' '/v' 'ConfigureStartPins' '/t' 'REG_SZ' '/d' '{"pinnedList": [{}]}' '/f' | Out-Null
    # (Duplicate entries below — same keys set again for robustness)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'ContentDeliveryAllowed' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'ContentDeliveryAllowed' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable Windows feature management (prevents dynamic feature rollouts)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'FeatureManagementEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable OEM pre-installed app suggestions (duplicate for robustness)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'OemPreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable pre-installed app promotions (duplicate)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'PreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Mark that pre-installed apps were never enabled (prevents re-enabling)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'PreInstalledAppsEverEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable silent installation of suggested apps (duplicate)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SilentInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable "soft landing" tips and suggestions after app installations
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SoftLandingEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable subscribed content (dynamic promotional content from Microsoft)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContentEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable specific subscribed content IDs:
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-310093Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null  # "Suggested" in Settings
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338388Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null  # Timeline suggestions
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338389Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null  # Tips/suggestions notifications
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338393Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null  # Suggested content in Settings app
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-353694Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null  # Suggested content in Settings
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-353696Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null  # Suggested content in Settings
    # Disable subscribed content (duplicate for robustness)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContentEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable Start menu app suggestions
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SystemPaneSuggestionsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable Microsoft Store push-to-install feature (remote app install from web)
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' '/v' 'DisablePushToInstall' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
    # Disable Malicious Software Removal Tool (MRT) offerings via Windows Update
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' '/v' 'DontOfferThroughWUAU' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
    # Remove Content Delivery Manager subscription and suggested apps tracking data
    & 'reg' 'delete' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions' '/f' | Out-Null
    & 'reg' 'delete' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps' '/f' | Out-Null
    # Disable consumer account state content (prevents Microsoft account promotions)
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableConsumerAccountStateContent' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
    # Disable cloud-optimized content (prevents cloud-based content suggestions)
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableCloudOptimizedContent' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

    ## --- REGISTRY: Enable local account creation during OOBE --- ##
    Write-Host "Enabling Local Accounts on OOBE:"
    # Bypass Network Requirement for OOBE — allows setup without internet (enables local account)
    & 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' '/v' 'BypassNRO' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
    # Copy autounattend.xml to Sysprep folder to automate OOBE local account setup
    Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$ScratchDisk\scratchdir\Windows\System32\Sysprep\autounattend.xml" -Force | Out-Null

    ## --- REGISTRY: Disable Reserved Storage (7 GB reserved for updates) --- ##
    Write-Host "Disabling Reserved Storage:"
    & 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' '/v' 'ShippedWithReserves' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null

    ## --- REGISTRY: Disable automatic BitLocker Device Encryption --- ##
    Write-Host "Disabling BitLocker Device Encryption"
    & 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' '/v' 'PreventDeviceEncryption' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

    ## --- REGISTRY: Disable Teams Chat icon on taskbar --- ##
    Write-Host "Disabling Chat icon:"
    # Hide Chat icon via group policy (3 = hidden)
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' '/v' 'ChatIcon' '/t' 'REG_DWORD' '/d' '3' '/f' | Out-Null
    # Disable "Meet Now" / Chat taskbar button in Explorer
    & 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' '/v' 'TaskbarMn' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null

    ## --- REGISTRY: Remove Microsoft Edge uninstall registry entries --- ##
    Write-Host "Removing Edge related registries"
    # Remove Edge from Add/Remove Programs list
    reg delete "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f | Out-Null
    # Remove Edge Update from Add/Remove Programs list
    reg delete "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" /f | Out-Null

    ## --- REGISTRY: Disable OneDrive folder backup/sync --- ##
    Write-Host "Disabling OneDrive folder backup"
    # Prevent OneDrive from syncing (FileSyncNGSC = Next Generation Sync Client)
    & 'reg' 'add' "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" '/v' 'DisableFileSyncNGSC' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

    ## --- REGISTRY: Disable telemetry and data collection --- ##
    Write-Host "Disabling Telemetry:"
    # Disable Advertising ID for app cross-promotion
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' '/v' 'Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable tailored experiences based on diagnostic data
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' '/v' 'TailoredExperiencesWithDiagnosticDataEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable online speech recognition / cloud speech services
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' '/v' 'HasAccepted' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable Tablet Input Panel Connector (handwriting data collection)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' '/v' 'Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Restrict implicit ink data collection (pen/touch input personalization)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' '/v' 'RestrictImplicitInkCollection' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
    # Restrict implicit text data collection (typing personalization)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' '/v' 'RestrictImplicitTextCollection' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
    # Disable harvesting contacts for typing personalization
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' '/v' 'HarvestContacts' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Decline personalization privacy policy (prevents input data sending)
    & 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' '/v' 'AcceptedPrivacyPolicy' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Set telemetry level to 0 (Security only — minimum data collection via policy)
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' '/v' 'AllowTelemetry' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable dmwappushservice (WAP Push Message Routing Service — telemetry helper). Start=4 means disabled
    & 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' | Out-Null

    ## --- REGISTRY: Prevent post-OOBE automatic installation of DevHome and Outlook --- ##
    Write-Host "Prevents installation or DevHome and Outlook:"
    # Mark Outlook update work as already completed so the UScheduler won't install it
    & 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' '/v' 'workCompleted' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
    # Mark DevHome update work as already completed
    & 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' '/v' 'workCompleted' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
    # Remove OOBE-triggered scheduled tasks for Outlook and DevHome installation
    & 'reg' 'delete' 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' '/f' | Out-Null
    & 'reg' 'delete' 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate' '/f' | Out-Null

    ## --- REGISTRY: Disable Windows Copilot and Edge sidebar --- ##
    Write-Host "Disabling Copilot"
    # Disable Windows Copilot AI assistant via group policy
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' '/v' 'TurnOffWindowsCopilot' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
    # Disable Edge sidebar (Hubs) via policy
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' '/v' 'HubsSidebarEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
    # Disable search box web/cloud suggestions in Windows Explorer
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' '/v' 'DisableSearchBoxSuggestions' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

    ## --- REGISTRY: Prevent Teams auto-installation --- ##
    Write-Host "Prevents installation of Teams:"
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' '/v' 'DisableInstallation' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

    ## --- REGISTRY: Prevent new Outlook (Windows Mail replacement) from running --- ##
    Write-Host "Prevent installation of New Outlook":
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' '/v' 'PreventRun' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
    $tasksPath = "C:\scratchdir\Windows\System32\Tasks"

    ## --- SCHEDULED TASK REMOVAL: Delete task definition XML files to prevent telemetry/maintenance tasks --- ##
    Write-Host "Deleting scheduled task definition files..."

    # Remove Application Compatibility Appraiser — collects app compatibility telemetry data for Microsoft
    Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue

    # Remove all Customer Experience Improvement Program (CEIP) tasks — sends usage data to Microsoft
    Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue

    # Remove Program Data Updater — updates compatibility telemetry data cache
    Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue

    # Remove Chkdsk Proxy task — notifies user about filesystem errors (unnecessary for clean image)
    Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue

    # Remove Windows Error Reporting queue task — sends crash/error reports to Microsoft
    Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue

    Write-Host "Task files have been deleted."

    ## --- REGISTRY: Disable Windows Update (Core edition only — non-serviceable image) --- ##
    Write-Host "Disabling Windows Update..."
    # RunOnce commands: stop and disable Windows Update service on first boot after OOBE
    & 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE1' '/t' 'REG_SZ' '/d' 'net stop wuauserv' '/f'                    # Stop WU service via net
    & 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE2' '/t' 'REG_SZ' '/d' 'sc stop wuauserv' '/f'                      # Stop WU service via sc
    & 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE3' '/t' 'REG_SZ' '/d' 'sc config wuauserv start= disabled' '/f'    # Set WU service to disabled start
    & 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'DisbaleWUPostOOBE1' '/t' 'REG_SZ' '/d' 'reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' '/f'  # Disable WU service via CurrentControlSet
    & 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'DisbaleWUPostOOBE2' '/t' 'REG_SZ' '/d' 'reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' '/f'    # Disable WU service via ControlSet001
    # Group Policy: block connections to Windows Update internet locations
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'DoNotConnectToWindowsUpdateInternetLocations' '/t' 'REG_DWORD' '/d' '1' '/f'
    # Group Policy: disable access to Windows Update
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'DisableWindowsUpdateAccess' '/t' 'REG_DWORD' '/d' '1' '/f' 
    # Redirect Windows Update server URLs to localhost (effectively blocking them)
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'WUServer' '/t' 'REG_SZ' '/d' 'localhost' '/f' 
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'WUStatusServer' '/t' 'REG_SZ' '/d' 'localhost' '/f' 
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'UpdateServiceUrlAlternate' '/t' 'REG_SZ' '/d' 'localhost' '/f' 
    # Force use of the (now-localhost) WSUS server for updates
    & 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' '/v' 'UseWUServer' '/t' 'REG_DWORD' '/d' '1' '/f' 
    # Disable online OOBE features
    & 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' '/v' 'DisableOnline' '/t' 'REG_DWORD' '/d' '1' '/f' 
    # Disable Windows Update service directly (Start=4 means disabled)
    & 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 
    # Delete WaaS Medic Service — auto-repairs Windows Update; removing it prevents WU from self-healing
    & 'reg' 'delete' 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC' '/f'
    # Delete Update Orchestrator Service — schedules and manages Windows Update installations
    & 'reg' 'delete' 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc' '/f'
    # Disable automatic updates via policy
    & 'reg' 'add' 'HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' '/v' 'NoAutoUpdate' '/t' 'REG_DWORD' '/d' '1' '/f'

    ## --- REGISTRY: Disable Windows Defender (Core edition only) --- ##
    Write-Host "Disabling Windows Defender"
    # Disable all Windows Defender services by setting Start=4 (disabled)
    $servicePaths = @(
        "WinDefend",   # Windows Defender Antivirus Service — main real-time protection
        "WdNisSvc",    # Windows Defender Network Inspection Service — network traffic scanner
        "WdNisDrv",    # Windows Defender Network Inspection Driver — kernel-mode network filter
        "WdFilter",    # Windows Defender Mini-Filter Driver — filesystem real-time scanner
        "Sense"        # Windows Defender Advanced Threat Protection (ATP) / Microsoft Defender for Endpoint
    )

    foreach ($path in $servicePaths) {
        Set-ItemProperty -Path "HKLM:\zSYSTEM\ControlSet001\Services\$path" -Name "Start" -Value 4
    }
    # Hide Windows Defender and Windows Update pages from Settings app (since they're disabled)
    & 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' '/v' 'SettingsPageVisibility' '/t' 'REG_SZ' '/d' 'hide:virus;windowsupdate' '/f' 
    Write-Host "Tweaking complete!"
    Write-Host "Unmounting Registry..."
    reg unload HKLM\zCOMPONENTS >null
    reg unload HKLM\zDEFAULT >null
    reg unload HKLM\zNTUSER >null
    reg unload HKLM\zSOFTWARE
    reg unload HKLM\zSYSTEM >null
    Write-Host "Cleaning up image..."
    & 'dism' '/English' "/image:$mainOSDrive\scratchdir" '/Cleanup-Image' '/StartComponentCleanup' '/ResetBase' >null
    Write-Host "Cleanup complete."
    Write-Host ' '
    Write-Host "Unmounting image..."
    & 'dism' '/English' '/unmount-image' "/mountdir:$mainOSDrive\scratchdir" '/commit'
    Write-Host "Exporting image..."
    & 'dism' '/English' '/Export-Image' "/SourceImageFile:$mainOSDrive\asl-win11\sources\install.wim" "/SourceIndex:$index" "/DestinationImageFile:$mainOSDrive\asl-win11\sources\install2.wim" '/compress:max'
    Remove-Item -Path "$mainOSDrive\asl-win11\sources\install.wim" -Force >null
    Rename-Item -Path "$mainOSDrive\asl-win11\sources\install2.wim" -NewName "install.wim" >null
    Write-Host "Windows image completed. Continuing with boot.wim."
    Start-Sleep -Seconds 2
    Clear-Host
    Write-Host "Mounting boot image:"
    $wimFilePath = "$($env:SystemDrive)\asl-win11\sources\boot.wim" 
    & takeown "/F" $wimFilePath >null
    & icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
    Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false
    & 'dism' '/English' '/mount-image' "/imagefile:$mainOSDrive\asl-win11\sources\boot.wim" '/index:2' "/mountdir:$mainOSDrive\scratchdir"
    Write-Host "Loading registry..."
    reg load HKLM\zCOMPONENTS $mainOSDrive\scratchdir\Windows\System32\config\COMPONENTS
    reg load HKLM\zDEFAULT $mainOSDrive\scratchdir\Windows\System32\config\default
    reg load HKLM\zNTUSER $mainOSDrive\scratchdir\Users\Default\ntuser.dat
    reg load HKLM\zSOFTWARE $mainOSDrive\scratchdir\Windows\System32\config\SOFTWARE
    reg load HKLM\zSYSTEM $mainOSDrive\scratchdir\Windows\System32\config\SYSTEM
    ## --- BOOT.WIM REGISTRY: Apply same hardware requirement bypasses to the Windows Setup (boot) image --- ##
    Write-Host "Bypassing system requirements(on the setup image):"
    # Suppress unsupported hardware notification in default user profile (boot environment)
    & 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' >null
    & 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' >null
    # Suppress unsupported hardware notification in NTUSER default profile (boot environment)
    & 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' >null
    & 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' >null
    # LabConfig keys in boot image: bypass hardware checks during initial Windows Setup
    & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck' '/t' 'REG_DWORD' '/d' '1' '/f' >null       # Skip CPU compatibility check
    & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' >null       # Skip minimum RAM check
    & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' >null # Skip Secure Boot check
    & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck' '/t' 'REG_DWORD' '/d' '1' '/f' >null   # Skip storage size check
    & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' >null       # Skip TPM 2.0 check
    # Allow upgrades on unsupported hardware (boot image)
    & 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' >null
    # Set boot image setup command line to use setup.exe from the sources directory
    & 'reg' 'add' 'HKEY_LOCAL_MACHINE\zSYSTEM\Setup' '/v' 'CmdLine' '/t' 'REG_SZ' '/d' 'X:\sources\setup.exe' '/f' >null
    Write-Host "Tweaking complete!"
    Write-Host "Unmounting Registry..."
    reg unload HKLM\zCOMPONENTS >null
    reg unload HKLM\zDEFAULT >null
    reg unload HKLM\zNTUSER >null
    reg unload HKLM\zSOFTWARE >null
    reg unload HKLM\zSYSTEM >null
    Write-Host "Unmounting image..."
    & 'dism' '/English' '/unmount-image' "/mountdir:$mainOSDrive\scratchdir" '/commit'
    Clear-Host
    Write-Host "Exporting ESD. This may take a while..."
    & dism /Export-Image /SourceImageFile:"$mainOSDrive\asl-win11\sources\install.wim" /SourceIndex:1 /DestinationImageFile:"$mainOSDrive\asl-win11\sources\install.esd" /Compress:recovery
    Remove-Item "$mainOSDrive\asl-win11\sources\install.wim" > $null 2>&1
    Write-Host "The asl-win11 image is now completed. Proceeding with the making of the ISO..."
    Write-Host "Creating ISO image..."
    $ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostarchitecture\Oscdimg"
    $localOSCDIMGPath = "$PSScriptRoot\oscdimg.exe"

    if ([System.IO.Directory]::Exists($ADKDepTools)) {
        Write-Host "Will be using oscdimg.exe from system ADK."
        $OSCDIMG = "$ADKDepTools\oscdimg.exe"
    } else {
        Write-Host "ADK folder not found. Will be using bundled oscdimg.exe."
    
    
        $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"

        if (-not (Test-Path -Path $localOSCDIMGPath)) {
            Write-Host "Downloading oscdimg.exe..."
            Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath

            if (Test-Path $localOSCDIMGPath) {
                Write-Host "oscdimg.exe downloaded successfully."
            } else {
                Write-Error "Failed to download oscdimg.exe."
                exit 1
            }
        } else {
            Write-Host "oscdimg.exe already exists locally."
        }

        $OSCDIMG = $localOSCDIMGPath
    }

    $outputDir = Join-Path $PSScriptRoot 'output'
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    $isoPath = "$outputDir\asl-win11-core_$(Get-Date -f yyyyMMdd).iso"
    & "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$ScratchDisk\asl-win11\boot\etfsboot.com#pEF,e,b$ScratchDisk\asl-win11\efi\microsoft\boot\efisys.bin" "$ScratchDisk\asl-win11" "$isoPath"

    # Finishing up
    Write-Host "Creation completed! Press any key to exit the script..."
    Read-Host "Press Enter to continue"
    Write-Host "Performing Cleanup..."
    Remove-Item -Path "$mainOSDrive\asl-win11" -Recurse -Force >null
    Remove-Item -Path "$mainOSDrive\scratchdir" -Recurse -Force >null

    # Stop the transcript
    Stop-Transcript

    exit
} elseif ($input -eq 'n') {
    Write-Host "You chose not to continue. The script will now exit."
    exit
} else {
    Write-Host "Invalid input. Please enter 'y' to continue or 'n' to exit."
}
