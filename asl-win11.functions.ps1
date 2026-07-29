<#
.SYNOPSIS
    Reusable functions for asl-win11 image creation workflows.

.DESCRIPTION
    This file contains reusable functions used by asl-win11 main scripts.
    It is intended to be dot-sourced by runner scripts such as asl-win11maker.ps1.
#>
function Wait-ForAcknowledgement {
    param (
        [string]$Prompt = 'Press Enter to exit'
    )

    Read-Host $Prompt | Out-Null
}

function Write-Phase {
    param (
        [string]$Title
    )

    Write-Output ''
    Write-Log "=== $Title ==="
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped, leveled log line to the console and the structured log file.
    .DESCRIPTION
        Additive to Start-Transcript: the transcript captures raw console output, while this
        writes a parallel `$script:structuredLogPath` file with timestamp/level prefixes for
        easier post-run triage. Silently skips the file write if no session has been
        initialized yet (e.g. a failure before Initialize-Tiny11Session ran).
    #>
    param (
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Write-Output $line
    if ($script:structuredLogPath) {
        Add-Content -Path $script:structuredLogPath -Value $line -ErrorAction SilentlyContinue
    }
}

function Get-RegistryDisplayName {
    param (
        [string]$Path,
        [string]$Name
    )

    $segments = $Path -split '\\'
    $tail = if ($segments.Count -ge 2) {
        ($segments[($segments.Count - 2)..($segments.Count - 1)] -join '\\')
    } else {
        $Path
    }

    if ($Name) {
        return "$tail\\$Name"
    }

    return $tail
}

function Invoke-WithoutProgress {
    param (
        [scriptblock]$ScriptBlock
    )

    $previousProgressPreference = $global:ProgressPreference
    try {
        $global:ProgressPreference = 'SilentlyContinue'
        & $ScriptBlock
    } finally {
        $global:ProgressPreference = $previousProgressPreference
    }
}

function Set-RegistryValue {
    param (
        [string]$path,
        [string]$name,
        [string]$type,
        [string]$value
    )
    try {
        & 'reg' 'add' $path '/v' $name '/t' $type '/d' $value '/f' 2>$null | Out-Null
        Write-Output "  Set $(Get-RegistryDisplayName -Path $path -Name $name) = $value"
    } catch {
        Write-Output "Error setting registry value: $_"
    }
}

function Remove-RegistryValue {
    param (
        [string]$path
    )
    try {
        & 'reg' 'query' $path 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & 'reg' 'delete' $path '/f' 2>$null | Out-Null
            Write-Output "  Removed $(Get-RegistryDisplayName -Path $path)"
        } else {
            Write-Output "  Skipped missing $(Get-RegistryDisplayName -Path $path)"
        }
    } catch {
        Write-Output "Error removing registry value: $_"
    }
}

#---------[ App & Software Removal Functions ]---------#

function Remove-ProvisionedAppPackages {
    <#
    .SYNOPSIS
        Removes provisioned UWP/MSIX app packages from a mounted Windows image.
    .DESCRIPTION
        Takes a list of package name prefixes and removes any matching provisioned
        packages from the image. Comment out individual entries in the prefix list
        to keep specific apps.
    #>
    param (
        [string]$ImagePath,
        [string[]]$PackagePrefixes
    )
    Write-Phase 'Remove provisioned app packages'
    $packages = & 'dism' '/English' "/image:$ImagePath" '/Get-ProvisionedAppxPackages' |
        ForEach-Object {
            if ($_ -match 'PackageName : (.*)') { $matches[1] }
        }

    $packagesToRemove = $packages | Where-Object {
        $packageName = $_
        $PackagePrefixes -contains ($PackagePrefixes | Where-Object { $packageName -like "*$_*" })
    }
    if (-not $packagesToRemove) {
        Write-Output '  No matching provisioned packages found.'
        return
    }

    foreach ($package in $packagesToRemove) {
        Write-Output "  Removing: $package"
        & 'dism' '/English' "/image:$ImagePath" '/Remove-ProvisionedAppxPackage' "/PackageName:$package"
    }
    Write-Output "Removed $($packagesToRemove.Count) provisioned package(s)."
}

function Remove-Edge {
    <#
    .SYNOPSIS
        Removes Microsoft Edge files and registry entries from the mounted image.
    .DESCRIPTION
        Deletes Edge installation directories (Edge, EdgeUpdate, EdgeCore) and removes Edge
        uninstall entries from Add/Remove Programs in the offline registry.
        Optionally also removes the WebView2 runtime — pass -SkipWebView to leave it in place,
        as some apps depend on it.
        Registry removals require offline hives to be loaded at HKLM\z* paths.
    #>
    param (
        [string]$MountDir,
        [string]$AdminGroupName,
        [switch]$SkipWebView
    )
    Write-Phase 'Remove Microsoft Edge'

    # Edge browser main installation directory
    Remove-Item -Path "$MountDir\Program Files (x86)\Microsoft\Edge" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    # Edge auto-update service
    Remove-Item -Path "$MountDir\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    # Edge core engine / runtime binaries
    Remove-Item -Path "$MountDir\Program Files (x86)\Microsoft\EdgeCore" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    Write-Output '  Removed Edge browser files.'

    if (-not $SkipWebView) {
        # WebView2 embedded browser runtime — removing may break apps that depend on it
        $webviewPath = "$MountDir\Windows\System32\Microsoft-Edge-Webview"
        if (Test-Path $webviewPath) {
            & 'takeown' '/f' $webviewPath '/r' | Out-Null
            & 'icacls' $webviewPath '/grant' "${AdminGroupName}:(F)" '/T' '/C' | Out-Null
            Remove-Item -Path $webviewPath -Recurse -Force | Out-Null
        }
        Write-Output '  Removed Edge WebView2 runtime.'
    }

    # Remove Edge entries from Add/Remove Programs in the offline registry (requires z-hives loaded)
    Remove-RegistryValue "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
    Remove-RegistryValue "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"
    Write-Output '  Removed Edge uninstall entries.'
}

function Remove-OneDriveSetup {
    <#
    .SYNOPSIS
        Removes the OneDrive cloud storage client installer from the mounted image.
    #>
    param (
        [string]$MountDir,
        [string]$AdminGroupName
    )
    Write-Phase 'Remove OneDrive setup'
    $onedrivePath = "$MountDir\Windows\System32\OneDriveSetup.exe"
    if (Test-Path $onedrivePath) {
        & 'takeown' '/f' $onedrivePath | Out-Null
        & 'icacls' $onedrivePath '/grant' "${AdminGroupName}:(F)" '/T' '/C' | Out-Null
        Remove-Item -Path $onedrivePath -Force | Out-Null
    }
    Write-Output '  OneDrive setup removal complete.'
}

function Remove-ScheduledTasks {
    <#
    .SYNOPSIS
        Removes scheduled task definition XML files from the mounted image.
    .DESCRIPTION
        Deletes task files to prevent telemetry and maintenance tasks from running.
        Comment out individual paths in the TaskPaths list to keep specific tasks.
    #>
    param (
        [string]$MountDir,
        [string[]]$TaskPaths
    )
    Write-Phase 'Remove scheduled task definitions'
    $tasksBasePath = "$MountDir\Windows\System32\Tasks"
    $removedCount = 0
    foreach ($taskRelPath in $TaskPaths) {
        $fullPath = Join-Path $tasksBasePath $taskRelPath
        if (Test-Path $fullPath) {
            Remove-Item -Path $fullPath -Recurse -Force -ErrorAction SilentlyContinue
            $removedCount += 1
            Write-Output "  Removed: $taskRelPath"
        }
    }
    if ($removedCount -eq 0) {
        Write-Output '  No matching scheduled task files found.'
    } else {
        Write-Output "Removed $removedCount scheduled task definition(s)."
    }
}

function Remove-IsoSupportFolder {
    <#
    .SYNOPSIS
        Removes the support\ folder from the ISO contents directory.
    .DESCRIPTION
        The support\ folder only contains OEM/support tooling that isn't needed to install
        Windows; dropping it is a small, safe reduction in final ISO size.
    #>
    param (
        [string]$ContentRoot
    )
    Write-Phase 'Remove ISO support folder'
    $supportPath = Join-Path $ContentRoot 'support'
    if (Test-Path $supportPath) {
        Remove-Item -Path $supportPath -Recurse -Force
        Write-Output '  Removed support\ folder.'
    } else {
        Write-Output '  support\ folder not present; nothing to remove.'
    }
}

#---------[ Answer File & Edition Enforcement Functions ]---------#

function Get-AnswerFileChildElement {
    <#
    .SYNOPSIS
        Finds (or creates) a namespace-qualified child element under an XML parent.
    #>
    param (
        [Parameter(Mandatory)][System.Xml.XmlElement]$Parent,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$NamespaceUri
    )

    foreach ($childNode in $Parent.ChildNodes) {
        if ($childNode.NodeType -eq [System.Xml.XmlNodeType]::Element -and
            $childNode.LocalName -eq $Name -and
            $childNode.NamespaceURI -eq $NamespaceUri) {
            return [System.Xml.XmlElement]$childNode
        }
    }

    $childElement = $Parent.OwnerDocument.CreateElement($Name, $NamespaceUri)
    [void]$Parent.AppendChild($childElement)
    return $childElement
}

function ConvertTo-Tiny11AnswerFile {
    <#
    .SYNOPSIS
        Injects the selected install image index into autounattend.xml.
    .DESCRIPTION
        Namespace-aware edit of the windowsPE/Microsoft-Windows-Setup/ImageInstall/OSImage/
        InstallFrom node so Setup installs the edition actually chosen via
        Select-InstallImageIndex, instead of relying on the answer file's own (possibly
        stale) assumptions. Also strips empty/placeholder product keys so Setup doesn't
        fail edition matching against them.
    #>
    param (
        [Parameter(Mandatory)][string]$XmlContent,
        [int]$ImageIndex = 1
    )

    if ($ImageIndex -lt 1) { $ImageIndex = 1 }

    $unattendNs = 'urn:schemas-microsoft-com:unattend'
    $wcmNs = 'http://schemas.microsoft.com/WMIConfig/2002/State'

    $xmlDoc = [xml]::new()
    $xmlDoc.PreserveWhitespace = $true
    $xmlDoc.LoadXml($XmlContent)

    if ($xmlDoc.DocumentElement.NamespaceURI -ne $unattendNs) {
        throw "Unexpected autounattend.xml namespace: $($xmlDoc.DocumentElement.NamespaceURI)"
    }

    if (-not $xmlDoc.DocumentElement.HasAttribute('xmlns:wcm')) {
        $xmlDoc.DocumentElement.SetAttribute('wcm', 'http://www.w3.org/2000/xmlns/', $wcmNs)
    }

    $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
    $nsMgr.AddNamespace('u', $unattendNs)

    $windowsPESettings = $xmlDoc.SelectSingleNode('/u:unattend/u:settings[@pass="windowsPE"]', $nsMgr)
    if (-not $windowsPESettings) {
        $windowsPESettings = $xmlDoc.CreateElement('settings', $unattendNs)
        $windowsPESettings.SetAttribute('pass', 'windowsPE')
        [void]$xmlDoc.DocumentElement.PrependChild($windowsPESettings)
    }

    $setupComponent = $windowsPESettings.SelectSingleNode('u:component[@name="Microsoft-Windows-Setup"]', $nsMgr)
    if (-not $setupComponent) {
        $setupComponent = $xmlDoc.CreateElement('component', $unattendNs)
        $setupComponent.SetAttribute('name', 'Microsoft-Windows-Setup')
        $setupComponent.SetAttribute('processorArchitecture', 'amd64')
        $setupComponent.SetAttribute('publicKeyToken', '31bf3856ad364e35')
        $setupComponent.SetAttribute('language', 'neutral')
        $setupComponent.SetAttribute('versionScope', 'nonSxS')
        [void]$windowsPESettings.AppendChild($setupComponent)
    }

    $productKeyNodes = @($setupComponent.SelectNodes('u:UserData/u:ProductKey', $nsMgr))
    foreach ($productKeyNode in $productKeyNodes) {
        $keyNode = $productKeyNode.SelectSingleNode('u:Key', $nsMgr)
        $keyValue = if ($keyNode) { $keyNode.InnerText.Trim() } else { '' }

        if ([string]::IsNullOrWhiteSpace($keyValue) -or $keyValue -eq '00000-00000-00000-00000-00000') {
            [void]$productKeyNode.ParentNode.RemoveChild($productKeyNode)
        }
    }

    $imageInstall = Get-AnswerFileChildElement -Parent $setupComponent -Name 'ImageInstall' -NamespaceUri $unattendNs
    $osImage = Get-AnswerFileChildElement -Parent $imageInstall -Name 'OSImage' -NamespaceUri $unattendNs
    $installFrom = Get-AnswerFileChildElement -Parent $osImage -Name 'InstallFrom' -NamespaceUri $unattendNs

    $existingMetadataNodes = @($installFrom.SelectNodes('u:MetaData', $nsMgr))
    foreach ($metadataNode in $existingMetadataNodes) {
        [void]$installFrom.RemoveChild($metadataNode)
    }

    $metadata = $xmlDoc.CreateElement('MetaData', $unattendNs)
    $actionAttribute = $xmlDoc.CreateAttribute('wcm', 'action', $wcmNs)
    $actionAttribute.Value = 'add'
    [void]$metadata.Attributes.Append($actionAttribute)

    $keyElement = $xmlDoc.CreateElement('Key', $unattendNs)
    $keyElement.InnerText = '/IMAGE/INDEX'
    [void]$metadata.AppendChild($keyElement)

    $valueElement = $xmlDoc.CreateElement('Value', $unattendNs)
    $valueElement.InnerText = [string]$ImageIndex
    [void]$metadata.AppendChild($valueElement)

    [void]$installFrom.AppendChild($metadata)

    return $xmlDoc.OuterXml
}

function Set-Tiny11EditionConfig {
    <#
    .SYNOPSIS
        Pins the selected edition via sources\ei.cfg and removes sources\PID.txt.
    .DESCRIPTION
        Without this, Setup can fall back to a stale firmware-embedded product key that
        doesn't match the edition actually selected via Select-InstallImageIndex, causing
        an edition-mismatch failure at install time.
    #>
    param (
        [string]$ContentRoot,
        [string]$EditionId
    )
    Write-Phase 'Apply edition enforcement (ei.cfg / PID.txt)'
    $sourcesDir = Join-Path $ContentRoot 'sources'
    New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null

    $pidPath = Join-Path $sourcesDir 'PID.txt'
    if (Test-Path $pidPath) {
        Remove-Item -Path $pidPath -Force
        Write-Output '  Removed sources\PID.txt so setup will not force a stale product key.'
    }

    if ([string]::IsNullOrWhiteSpace($EditionId)) {
        Write-Output '  Skipped sources\ei.cfg: selected edition ID is unknown.'
        return
    }

    $eiCfgPath = Join-Path $sourcesDir 'ei.cfg'
    $eiCfg = @"
[EditionID]
$EditionId
[Channel]
Retail
[VL]
0
"@.Trim()

    Set-Content -Path $eiCfgPath -Value $eiCfg -Encoding ASCII -Force
    Write-Output "  Written sources\ei.cfg for EditionID '$EditionId'."
}

#---------[ Registry Tweak Functions ]---------#
# These functions operate on offline registry hives loaded at HKLM\z* paths.
# Call them AFTER loading the hives and BEFORE unloading.

function Set-BypassHardwareChecks {
    <#
    .SYNOPSIS
        Bypasses Windows 11 hardware requirements in the loaded registry hives.
    .DESCRIPTION
        Suppresses unsupported hardware notifications and sets LabConfig keys to
        bypass CPU, RAM, Secure Boot, Storage, and TPM 2.0 checks.
        Also allows in-place upgrades on unsupported hardware.
    #>
    Write-Phase 'Apply hardware bypass registry tweaks'

    # Suppress "unsupported hardware" watermark/notification on desktop
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'

    # LabConfig keys: bypass individual hardware checks during Windows Setup
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'        # Skip CPU compatibility check (e.g. 8th gen+ Intel)
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'        # Skip minimum 4 GB RAM requirement
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'  # Skip Secure Boot requirement
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'    # Skip 64 GB minimum storage requirement
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'        # Skip TPM 2.0 requirement

    # Allow in-place upgrades on systems without TPM 2.0 or supported CPU
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
}

function Disable-SponsoredApps {
    <#
    .SYNOPSIS
        Disables all sponsored apps, content delivery, and suggestions.
    .DESCRIPTION
        Disables OEM pre-installed apps, silent app installs, Start menu suggestions,
        subscribed content IDs, push-to-install, MRT offerings, and cloud content features.
        Also clears the Start menu pinned layout and removes CDM tracking data.
    #>
    Write-Phase 'Disable sponsored apps and content suggestions'

    # Disable OEM pre-installed app suggestions in Start menu
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
    # Disable pre-installed app promotions
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
    # Disable silent installation of suggested apps in the background
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
    # Disable Windows Consumer Features (blocks Microsoft consumer app suggestions via policy)
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    # Disable content delivery entirely (prevents all CDM-driven content like spotlight, tips)
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
    # Clear Start menu pinned layout to remove default promoted apps
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
    # Disable Windows feature management (prevents dynamic feature rollouts)
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'REG_DWORD' '0'
    # Mark that pre-installed apps were never enabled (prevents re-enabling)
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
    # Disable "soft landing" tips and suggestions after app installations
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 'REG_DWORD' '0'
    # Disable subscribed content (dynamic promotional content from Microsoft)
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'REG_DWORD' '0'
    # Disable specific subscribed content IDs:
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'  # "Suggested" in Settings
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'  # Timeline suggestions
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'  # Tips/suggestions notifications
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'  # Suggested content in Settings app
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'  # Suggested content in Settings
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'  # Suggested content in Settings
    # Disable Start menu app suggestions
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
    # Disable Microsoft Store push-to-install feature (remote app install from web)
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
    # Disable Malicious Software Removal Tool (MRT) offerings via Windows Update
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
    # Remove Content Delivery Manager subscription tracking data
    Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
    # Remove suggested apps tracking data
    Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
    # Disable consumer account state content (prevents Microsoft account promotions)
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
    # Disable cloud-optimized content (prevents cloud-based content suggestions)
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'
}

function Enable-LocalAccountOOBE {
    <#
    .SYNOPSIS
        Enables local account creation during OOBE (Out-of-Box Experience).
    .DESCRIPTION
        Sets BypassNRO to skip the network requirement during setup, allowing
        creation of a local account instead of requiring a Microsoft account.
        Also copies autounattend.xml to Sysprep for automated OOBE setup.
    #>
    param (
        [string]$MountDir,
        [string]$ScriptRoot
    )
    Write-Phase 'Enable local account option during OOBE'
    # Bypass Network Requirement for OOBE — allows setup without internet (enables local account)
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
    # Copy autounattend.xml to Sysprep folder to automate OOBE local account setup
    Copy-Item -Path "$ScriptRoot\autounattend.xml" -Destination "$MountDir\Windows\System32\Sysprep\autounattend.xml" -Force | Out-Null
}

function Disable-ReservedStorage {
    <#
    .SYNOPSIS
        Disables Windows Reserved Storage (7 GB reserved for updates).
    #>
    Write-Phase 'Disable reserved storage'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'
}

function Disable-BitLockerAutoEncryption {
    <#
    .SYNOPSIS
        Disables automatic BitLocker Device Encryption.
    #>
    Write-Phase 'Disable BitLocker device encryption'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
}

function Disable-ChatIcon {
    <#
    .SYNOPSIS
        Hides the Teams Chat icon from the taskbar.
    #>
    Write-Phase 'Hide chat icon'
    # Hide Chat icon via group policy (3 = hidden)
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
    # Disable "Meet Now" / Chat taskbar button in Explorer
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'
}

function Disable-OneDriveSync {
    <#
    .SYNOPSIS
        Disables OneDrive folder backup/sync via policy.
    #>
    Write-Phase 'Disable OneDrive sync policy'
    # Prevent OneDrive from syncing (FileSyncNGSC = Next Generation Sync Client)
    Set-RegistryValue "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"
}

function Disable-Telemetry {
    <#
    .SYNOPSIS
        Disables telemetry and data collection.
    .DESCRIPTION
        Disables Advertising ID, tailored experiences, online speech recognition,
        handwriting/typing data collection, personalization, and the telemetry
        data push service (dmwappushservice).
    #>
    Write-Phase 'Disable telemetry and personalization data collection'
    # Disable Advertising ID for app cross-promotion
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    # Disable tailored experiences based on diagnostic data
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    # Disable online speech recognition / cloud speech services
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
    # Disable Tablet Input Panel Connector (handwriting data collection)
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
    # Restrict implicit ink data collection (pen/touch input personalization)
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
    # Restrict implicit text data collection (typing personalization)
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
    # Disable harvesting contacts for typing personalization
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
    # Decline personalization privacy policy (prevents input data sending)
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
    # Set telemetry level to 0 (Security only — minimum data collection via policy)
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
    # Disable dmwappushservice (WAP Push Message Routing Service — telemetry helper). Start=4 means disabled
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'
}

function Disable-DevHomeOutlookInstall {
    <#
    .SYNOPSIS
        Prevents post-OOBE automatic installation of Dev Home and Outlook.
    .DESCRIPTION
        Marks update tasks as already completed and removes the OOBE-triggered
        UScheduler entries so Windows won't auto-install these apps.
    #>
    Write-Phase 'Prevent Dev Home and Outlook auto-install'
    # Mark Outlook update work as already completed so the UScheduler won't install it
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    # Mark DevHome update work as already completed
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
    # Remove OOBE-triggered scheduled tasks for Outlook and DevHome installation
    Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
    Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'
}

function Disable-Copilot {
    <#
    .SYNOPSIS
        Disables Windows Copilot AI assistant and Edge sidebar.
    #>
    Write-Phase 'Disable Copilot integrations'
    # Disable Windows Copilot AI assistant via group policy
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
    # Disable Edge sidebar (Hubs) via policy
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
    # Disable search box web/cloud suggestions in Windows Explorer
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
}

function Disable-TeamsInstall {
    <#
    .SYNOPSIS
        Prevents automatic installation of Microsoft Teams.
    #>
    Write-Phase 'Prevent Teams auto-install'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'
}

function Disable-NewOutlook {
    <#
    .SYNOPSIS
        Prevents the new Outlook (Windows Mail replacement) from running.
    #>
    Write-Phase 'Prevent new Outlook app launch'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'
}

#---------[ Execution Grouping Functions ]---------#

function Confirm-ExecutionPolicy {
    if ((Get-ExecutionPolicy) -eq 'Restricted') {
        Write-Output "Your current PowerShell Execution Policy is set to Restricted, which prevents scripts from running. Do you want to change it to RemoteSigned? (yes/no)"
        $response = Read-Host
        if ($response -eq 'yes') {
            Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
        } else {
            Write-Output "The script cannot be run without changing the execution policy. Exiting..."
            Wait-ForAcknowledgement -Prompt 'Press Enter to close this window'
            exit
        }
    }
}

function Confirm-AdminPrivileges {
    $adminSID = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $script:adminGroupName = ($adminSID.Translate([System.Security.Principal.NTAccount])).Value
    $myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
    $adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator
    if (! $myWindowsPrincipal.IsInRole($adminRole)) {
        Write-Output "Restarting Tiny11 image creator as admin in a new window, you can close this one."
        $entryScriptPath = $script:EntryScriptPath
        if (-not $entryScriptPath) {
            $entryScriptPath = $PSCommandPath
        }

        $argumentList = @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            $entryScriptPath
        )

        if ($ISO) {
            $argumentList += @('-ISO', $ISO)
        }
        if ($SCRATCH) {
            $argumentList += @('-SCRATCH', $SCRATCH)
        }

        Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Verb RunAs | Out-Null
        Wait-ForAcknowledgement -Prompt 'Press Enter to close this non-elevated window'
        exit
    }
}

function Invoke-Tiny11EmergencyCleanup {
    <#
    .SYNOPSIS
        Best-effort recovery from a mid-pipeline failure.
    .DESCRIPTION
        Discards any images left mounted (install.wim or boot.wim) and unloads offline
        registry hives so a failed run doesn't block the next one. Called from the
        top-level catch block in asl-win11maker.ps1 — every step here is best-effort and
        swallows its own errors since we're already in a failure path.
    #>
    Write-Log 'Running emergency cleanup after failure...' 'WARN'

    try {
        Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Log "  Emergency dismount: $($_.Path)" 'WARN'
            Dismount-WindowsImage -Path $_.Path -Discard -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        Write-Log "  Emergency image dismount failed: $_" 'ERROR'
    }

    foreach ($hive in @('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM')) {
        & 'reg' 'unload' "HKLM\$hive" 2>$null | Out-Null
    }

    Write-Log 'Emergency cleanup complete.' 'WARN'
}

function Confirm-AutounattendXml {
    if (-not (Test-Path -Path "$PSScriptRoot/autounattend.xml")) {
        Invoke-RestMethod "https://raw.githubusercontent.com/ntdevlabs/tiny11builder/refs/heads/main/autounattend.xml" -OutFile "$PSScriptRoot/autounattend.xml"
    }
}

function Initialize-Tiny11Session {
    $logsDir = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    $timestamp = Get-Date -f yyyyMMdd_HHmms
    Start-Transcript -Path "$logsDir\asl-win11_$timestamp.log"
    $script:structuredLogPath = "$logsDir\asl-win11_$timestamp.structured.log"

    $Host.UI.RawUI.WindowTitle = "ASL-Win11 image creator"
    Clear-Host
    Write-Phase 'Initialize asl-win11 build session'
    Write-Output 'Welcome to the asl-win11 image creator! Release: 09-07-25'

    $script:hostArchitecture = $Env:PROCESSOR_ARCHITECTURE
    $script:tiny11Root = "$script:BuildScratchRoot\asl-win11"
    $script:mountDir = "$script:BuildScratchRoot\scratchdir"
    $script:installWimPath = "$script:tiny11Root\sources\install.wim"
    $script:bootWimPath = "$script:tiny11Root\sources\boot.wim"
    New-Item -ItemType Directory -Force -Path "$script:tiny11Root\sources" | Out-Null
}

function Resolve-SourceDriveLetter {
    do {
        if (-not $ISO) {
            $script:DriveLetter = Read-Host "Please enter the drive letter for the Windows 11 image"
        } else {
            $script:DriveLetter = $ISO
        }
        if ($script:DriveLetter -match '^[c-zC-Z]$') {
            $script:DriveLetter = $script:DriveLetter + ":"
            Write-Output "Drive letter set to $script:DriveLetter"
        } else {
            Write-Output "Invalid drive letter. Please enter a letter between C and Z."
        }
    } while ($script:DriveLetter -notmatch '^[c-zC-Z]:$')
}

function Confirm-InstallWimSource {
    if ((Test-Path "$script:DriveLetter\sources\boot.wim") -eq $false -or (Test-Path "$script:DriveLetter\sources\install.wim") -eq $false) {
        if ((Test-Path "$script:DriveLetter\sources\install.esd") -eq $true) {
            Write-Output "Found install.esd, converting to install.wim..."
            Get-WindowsImage -ImagePath $script:DriveLetter\sources\install.esd
            $esdIndex = Read-Host "Please enter the image index"
            Write-Output ' '
            Write-Output 'Converting install.esd to install.wim. This may take a while...'
            Export-WindowsImage -SourceImagePath $script:DriveLetter\sources\install.esd -SourceIndex $esdIndex -DestinationImagePath $script:installWimPath -CompressionType Maximum -CheckIntegrity
        } else {
            Write-Output "Can't find Windows OS Installation files in the specified Drive Letter.."
            Write-Output "Please enter the correct DVD Drive Letter.."
            Wait-ForAcknowledgement -Prompt 'Press Enter to exit'
            exit
        }
    }
}

function Copy-SourceImageFiles {
    Write-Phase 'Copy source image files'
    Copy-Item -Path "$script:DriveLetter\*" -Destination $script:tiny11Root -Recurse -Force | Out-Null
    Set-ItemProperty -Path "$script:tiny11Root\sources\install.esd" -Name IsReadOnly -Value $false > $null 2>&1
    Remove-Item "$script:tiny11Root\sources\install.esd" > $null 2>&1
    Write-Output '  Source image copy complete.'
}

function Select-InstallImageIndex {
    Start-Sleep -Seconds 2
    Clear-Host
    Write-Phase 'Select image index'
    $imagesIndex = (Get-WindowsImage -ImagePath $script:installWimPath).ImageIndex
    while ($imagesIndex -notcontains $script:index) {
        Get-WindowsImage -ImagePath $script:installWimPath
        $script:index = Read-Host "Please enter the image index"
    }
}

function Mount-InstallImage {
    Write-Phase 'Mount install image'
    Write-Output '  Mounting Windows image. This may take a while.'
    & takeown "/F" $script:installWimPath
    & icacls $script:installWimPath "/grant" "$($script:adminGroupName):(F)"
    try {
        Set-ItemProperty -Path $script:installWimPath -Name IsReadOnly -Value $false -ErrorAction Stop
    } catch {
        Write-Error "$script:installWimPath not found"
    }
    New-Item -ItemType Directory -Force -Path $script:mountDir > $null
    Invoke-WithoutProgress { Mount-WindowsImage -ImagePath $script:installWimPath -Index $script:index -Path $script:mountDir }
}

function Show-ImageMetadata {
    Write-Phase 'Inspect selected image metadata'
    $imageIntl = & dism /English /Get-Intl "/Image:$script:mountDir"
    $languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

    if ($languageLine) {
        $languageCode = $Matches[1]
        Write-Output "Default system UI language code: $languageCode"
    } else {
        Write-Output "Default system UI language code not found."
    }

    $imageInfo = & 'dism' '/English' '/Get-WimInfo' "/wimFile:$script:installWimPath" "/index:$script:index"
    $lines = $imageInfo -split '\r?\n'

    foreach ($line in $lines) {
        if ($line -like '*Architecture : *') {
            $script:architecture = $line -replace 'Architecture : ', ''
            if ($script:architecture -eq 'x64') {
                $script:architecture = 'amd64'
            }
            Write-Output "Architecture: $script:architecture"
            break
        }
    }

    if (-not $script:architecture) {
        Write-Output "Architecture information not found."
    }

    # Build/edition metadata for Write-BuildInfo and the ei.cfg edition-enforcement step.
    $script:detectedImageName = Get-DismInfoField -Lines $lines -FieldName 'Name'
    $script:editionId = Get-DismInfoField -Lines $lines -FieldName 'Edition ID'
    $versionField = Get-DismInfoField -Lines $lines -FieldName 'Version'
    $serviceBuildField = Get-DismInfoField -Lines $lines -FieldName 'ServicePack Build'
    $script:detectedFullVersion = if ($serviceBuildField) { "$versionField.$serviceBuildField" } else { $versionField }

    if ($script:detectedFullVersion -match '(\d+\.\d+)$') {
        $script:detectedBuildNumber = $Matches[1]
    } else {
        $script:detectedBuildNumber = ''
    }

    if ($script:editionId) {
        Write-Output "Edition ID: $script:editionId"
    } else {
        Write-Output "Edition ID not found; ei.cfg will be skipped."
    }
}

function Get-DismInfoField {
    <#
    .SYNOPSIS
        Extracts a "Field Name : value" line from DISM text output.
    #>
    param (
        [string[]]$Lines,
        [string]$FieldName
    )

    foreach ($line in $Lines) {
        if ($line -match "^\s*$([regex]::Escape($FieldName))\s*:\s*(.+?)\s*$") {
            return $Matches[1]
        }
    }
    return ''
}

function Mount-OfflineRegistryHives {
    Write-Phase 'Load offline registry hives'
    reg load HKLM\zCOMPONENTS $script:mountDir\Windows\System32\config\COMPONENTS | Out-Null
    reg load HKLM\zDEFAULT $script:mountDir\Windows\System32\config\default | Out-Null
    reg load HKLM\zNTUSER $script:mountDir\Users\Default\ntuser.dat | Out-Null
    reg load HKLM\zSOFTWARE $script:mountDir\Windows\System32\config\SOFTWARE | Out-Null
    reg load HKLM\zSYSTEM $script:mountDir\Windows\System32\config\SYSTEM | Out-Null
}

function Dismount-OfflineRegistryHives {
    Write-Phase 'Unload offline registry hives'
    reg unload HKLM\zCOMPONENTS | Out-Null
    reg unload HKLM\zDEFAULT | Out-Null
    reg unload HKLM\zNTUSER | Out-Null
    reg unload HKLM\zSOFTWARE | Out-Null
    reg unload HKLM\zSYSTEM | Out-Null
}

function Complete-InstallImage {
    Write-Phase 'Finalize install image'
    Write-Output '  Cleaning up component store...'
    dism.exe /Image:$script:mountDir /Cleanup-Image /StartComponentCleanup /ResetBase
    Write-Output '  Component cleanup complete.'
    Write-Output '  Saving and unmounting install image...'
    Invoke-WithoutProgress { Dismount-WindowsImage -Path $script:mountDir -Save }

    Write-Output '  Exporting optimized install image...'
    Invoke-WithoutProgress { Dism.exe /Export-Image /SourceImageFile:"$script:installWimPath" /SourceIndex:$script:index /DestinationImageFile:"$script:tiny11Root\sources\install2.wim" /Compress:recovery }
    Remove-Item -Path $script:installWimPath -Force | Out-Null
    Rename-Item -Path "$script:tiny11Root\sources\install2.wim" -NewName "install.wim" | Out-Null
    Write-Output '  Install image finalized.'
}

function Set-BootImageBypassTweaks {
    Write-Phase 'Apply boot image setup bypasses'
    Write-Output '  Continuing with boot.wim.'
    Start-Sleep -Seconds 2
    Clear-Host

    Write-Output '  Mounting boot image...'
    & takeown "/F" $script:bootWimPath | Out-Null
    & icacls $script:bootWimPath "/grant" "$($script:adminGroupName):(F)"
    Set-ItemProperty -Path $script:bootWimPath -Name IsReadOnly -Value $false
    Invoke-WithoutProgress { Mount-WindowsImage -ImagePath $script:bootWimPath -Index 2 -Path $script:mountDir }

    Write-Output '  Loading boot image registry hives...'
    reg load HKLM\zCOMPONENTS $script:mountDir\Windows\System32\config\COMPONENTS
    reg load HKLM\zDEFAULT $script:mountDir\Windows\System32\config\default
    reg load HKLM\zNTUSER $script:mountDir\Users\Default\ntuser.dat
    reg load HKLM\zSOFTWARE $script:mountDir\Windows\System32\config\SOFTWARE
    reg load HKLM\zSYSTEM $script:mountDir\Windows\System32\config\SYSTEM

    Set-BypassHardwareChecks

    Write-Output '  Boot image tweaks complete.'
    Dismount-OfflineRegistryHives

    Write-Output '  Saving and unmounting boot image...'
    Invoke-WithoutProgress { Dismount-WindowsImage -Path $script:mountDir -Save }
    Clear-Host
}

function New-Tiny11Iso {
    Write-Phase 'Build ISO image'
    Write-Output '  Preparing unattended file for OOBE local account bypass...'
    $preparedAutounattendXml = Get-Content -Path "$PSScriptRoot\autounattend.xml" -Raw
    try {
        $preparedAutounattendXml = ConvertTo-Tiny11AnswerFile -XmlContent $preparedAutounattendXml -ImageIndex $script:index
        Write-Output "  Injected image index $script:index into autounattend.xml."
    } catch {
        Write-Log "Could not inject image index into autounattend.xml: $_" 'WARN'
    }
    Set-Content -Path "$script:tiny11Root\autounattend.xml" -Value $preparedAutounattendXml -Encoding UTF8 -Force

    Set-Tiny11EditionConfig -ContentRoot $script:tiny11Root -EditionId $script:editionId

    Write-Output '  Creating ISO image...'
    $outputDir = Join-Path $PSScriptRoot 'output'
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    $script:isoPath = "$outputDir\asl-win11_$(Get-Date -f yyyyMMdd).iso"
    $ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$script:hostArchitecture\Oscdimg"
    $localOSCDIMGPath = "$PSScriptRoot\oscdimg.exe"

    if ([System.IO.Directory]::Exists($ADKDepTools)) {
        Write-Output "Will be using oscdimg.exe from system ADK."
        $OSCDIMG = "$ADKDepTools\oscdimg.exe"
    } else {
        Write-Output "ADK folder not found. Will be using bundled oscdimg.exe."
        $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"

        if (-not (Test-Path -Path $localOSCDIMGPath)) {
            Write-Output "Downloading oscdimg.exe..."
            Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath

            if (Test-Path $localOSCDIMGPath) {
                Write-Output "oscdimg.exe downloaded successfully."
            } else {
                Write-Error "Failed to download oscdimg.exe."
                Wait-ForAcknowledgement -Prompt 'Press Enter to exit'
                exit 1
            }
        } else {
            Write-Output "oscdimg.exe already exists locally."
        }

        $OSCDIMG = $localOSCDIMGPath
    }

    & "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$script:tiny11Root\boot\etfsboot.com#pEF,e,b$script:tiny11Root\efi\microsoft\boot\efisys.bin" "$script:tiny11Root" "$script:isoPath"
}

function Write-BuildInfo {
    <#
    .SYNOPSIS
        Emits a build metadata JSON file alongside the finished ISO.
    .DESCRIPTION
        Machine-readable companion to the ISO (Windows build number, full version, image
        name, edition ID, selected index, and output path) for CI or other tooling to
        consume without re-parsing DISM output.
    #>
    param (
        [string]$OutputPath
    )
    Write-Phase 'Write build info'
    try {
        $buildInfo = [ordered]@{
            windows_build = $script:detectedBuildNumber
            full_version  = $script:detectedFullVersion
            image_name    = $script:detectedImageName
            edition_id    = $script:editionId
            image_index   = $script:index
            iso_path      = $script:isoPath
            generated_at  = (Get-Date -Format 'o')
        }
        $buildInfo | ConvertTo-Json | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
        Write-Output "  Build info written to $OutputPath"
    } catch {
        Write-Log "Failed to write build info to $OutputPath : $_" 'WARN'
    }
}

function Invoke-Tiny11Cleanup {
    Write-Phase 'Cleanup working files'
    Write-Output 'Creation completed! Press any key to exit the script...'
    Read-Host "Press Enter to continue"
    Write-Output "Performing Cleanup..."
    Remove-Item -Path $script:tiny11Root -Recurse -Force | Out-Null
    Remove-Item -Path $script:mountDir -Recurse -Force | Out-Null
    Write-Output "Ejecting Iso drive"
    Get-Volume -DriveLetter $script:DriveLetter[0] | Get-DiskImage | Dismount-DiskImage
    Write-Output "Iso drive ejected"
    Write-Output "Removing oscdimg.exe..."
    Remove-Item -Path "$PSScriptRoot\oscdimg.exe" -Force -ErrorAction SilentlyContinue
    Write-Output "Removing autounattend.xml..."
    Remove-Item -Path "$PSScriptRoot\autounattend.xml" -Force -ErrorAction SilentlyContinue

    Write-Output "Cleanup check :"
    if (Test-Path -Path $script:tiny11Root) {
        Write-Output "tiny11 folder still exists. Attempting to remove it again..."
        Remove-Item -Path $script:tiny11Root -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -Path $script:tiny11Root) {
            Write-Output "Failed to remove tiny11 folder."
        } else {
            Write-Output "tiny11 folder removed successfully."
        }
    } else {
        Write-Output "tiny11 folder does not exist. No action needed."
    }
    if (Test-Path -Path $script:mountDir) {
        Write-Output "scratchdir folder still exists. Attempting to remove it again..."
        Remove-Item -Path $script:mountDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -Path $script:mountDir) {
            Write-Output "Failed to remove scratchdir folder."
        } else {
            Write-Output "scratchdir folder removed successfully."
        }
    } else {
        Write-Output "scratchdir folder does not exist. No action needed."
    }
    if (Test-Path -Path "$PSScriptRoot\oscdimg.exe") {
        Write-Output "oscdimg.exe still exists. Attempting to remove it again..."
        Remove-Item -Path "$PSScriptRoot\oscdimg.exe" -Force -ErrorAction SilentlyContinue
        if (Test-Path -Path "$PSScriptRoot\oscdimg.exe") {
            Write-Output "Failed to remove oscdimg.exe."
        } else {
            Write-Output "oscdimg.exe removed successfully."
        }
    } else {
        Write-Output "oscdimg.exe does not exist. No action needed."
    }
    if (Test-Path -Path "$PSScriptRoot\autounattend.xml") {
        Write-Output "autounattend.xml still exists. Attempting to remove it again..."
        Remove-Item -Path "$PSScriptRoot\autounattend.xml" -Force -ErrorAction SilentlyContinue
        if (Test-Path -Path "$PSScriptRoot\autounattend.xml") {
            Write-Output "Failed to remove autounattend.xml."
        } else {
            Write-Output "autounattend.xml removed successfully."
        }
    } else {
        Write-Output "autounattend.xml does not exist. No action needed."
    }
}

