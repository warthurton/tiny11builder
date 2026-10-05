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
    <#
    .DESCRIPTION
        Uses Write-Host (via the blank spacer line and Write-Log) rather than
        Write-Output so this never leaks into the return value of a function that logs
        a phase header and then returns something the caller captures.
    #>
    param (
        [string]$Title
    )

    Write-Host ''
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
        Uses Write-Host rather than Write-Output so log lines never leak into a function's
        return value when a caller captures it (e.g. `$x = Resolve-VirtioDriverSource ...`)
        — Start-Transcript still captures Write-Host output, so nothing is lost from logs.
    #>
    param (
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    if ($script:structuredLogPath) {
        Add-Content -Path $script:structuredLogPath -Value $line -ErrorAction SilentlyContinue
    }
}

function Invoke-Dism {
    <#
    .SYNOPSIS
        Runs dism.exe and mirrors every line of its output into the structured log file.
    .DESCRIPTION
        Several DISM calls used to throw their output away entirely via `| Out-Null`, and
        others were only ever captured into a variable for parsing - in both cases nothing
        ended up in a log, so a failure or an unexpected package/edition list left no trail
        to check afterward. This wraps dism.exe, appends every output line to
        $script:structuredLogPath (prefixed so it's easy to pick out), and returns the
        lines unchanged so existing parsing (-split, Where-Object, regex matches, etc.)
        keeps working exactly as before.
        Not used for the long-running /Cleanup-Image or /Export-Image calls in
        Complete-InstallImage / Export-CoreInstallEsd - those still run dism.exe directly so
        DISM's own progress output stays live in the console/transcript instead of being
        buffered until the process exits.
    #>
    param (
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $output = & dism.exe @ArgumentList
    if ($script:structuredLogPath) {
        $output | ForEach-Object { Add-Content -Path $script:structuredLogPath -Value "[DISM] $_" -ErrorAction SilentlyContinue }
    }
    return $output
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
    $packages = Invoke-Dism -ArgumentList @('/English', "/image:$ImagePath", '/Get-ProvisionedAppxPackages') |
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
        Invoke-Dism -ArgumentList @('/English', "/image:$ImagePath", '/Remove-ProvisionedAppxPackage', "/PackageName:$package") | Out-Null
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

function Remove-SystemPackages {
    <#
    .SYNOPSIS
        Removes Windows system component (CBS) packages from a mounted image.
    .DESCRIPTION
        Core-build-only: Feature-on-Demand and optional-component removal via DISM
        /Get-Packages + /Remove-Package. Unlike provisioned appx packages, these are base
        OS components (IE11, WordPad, Tablet PC Math, ...) whose removal makes the image
        non-serviceable for that component going forward.
        Four per-language patterns (handwriting/OCR/speech/text-to-speech) are appended
        automatically from -LanguageCode, alongside the fixed language-neutral patterns in
        -PackagePatterns.
    #>
    param (
        [string]$MountDir,
        [string[]]$PackagePatterns,
        [string]$LanguageCode
    )
    Write-Phase 'Remove system component packages'

    $patterns = @($PackagePatterns)
    if ($LanguageCode) {
        $patterns += @(
            "Microsoft-Windows-LanguageFeatures-Handwriting-$LanguageCode-Package~31bf3856ad364e35"
            "Microsoft-Windows-LanguageFeatures-OCR-$LanguageCode-Package~31bf3856ad364e35"
            "Microsoft-Windows-LanguageFeatures-Speech-$LanguageCode-Package~31bf3856ad364e35"
            "Microsoft-Windows-LanguageFeatures-TextToSpeech-$LanguageCode-Package~31bf3856ad364e35"
        )
    }

    $allPackages = Invoke-Dism -ArgumentList @("/image:$MountDir", '/Get-Packages', '/Format:Table')
    $allPackages = $allPackages -split "`n" | Select-Object -Skip 1

    $removedCount = 0
    foreach ($pattern in $patterns) {
        $packagesToRemove = $allPackages | Where-Object { $_ -like "$pattern*" }
        foreach ($package in $packagesToRemove) {
            $packageIdentity = ($package -split '\s+')[0]
            Write-Output "  Removing: $packageIdentity"
            Invoke-Dism -ArgumentList @("/image:$MountDir", '/Remove-Package', "/PackageName:$packageIdentity") | Out-Null
            $removedCount += 1
        }
    }
    Write-Output "Removed $removedCount system package(s)."
}

function Enable-DotNet35 {
    <#
    .SYNOPSIS
        Enables .NET Framework 3.5 from the source media's sxs folder.
    .DESCRIPTION
        Core-build-only. Must be done offline before the image is finalized - .NET 3.5
        cannot be added after the ISO is built without a matching source.
    #>
    param (
        [string]$MountDir,
        [string]$SourceRoot
    )
    Write-Phase 'Enable .NET Framework 3.5'
    Invoke-Dism -ArgumentList @("/image:$MountDir", '/enable-feature', '/featurename:NetFX3', '/All', "/source:$SourceRoot\sources\sxs", '/LimitAccess') | Out-Null
    Write-Output '  .NET Framework 3.5 enabled.'
}

function Remove-EdgeWebViewWinSxS {
    <#
    .SYNOPSIS
        Removes the Edge WebView2 WinSxS side-by-side assembly for the image architecture.
    .DESCRIPTION
        Core-build-only. Complements Remove-Edge (which removes the System32 WebView2
        runtime and Program Files installation); this removes the architecture-specific
        WinSxS copy that Remove-Edge does not touch.
    #>
    param (
        [string]$MountDir,
        [string]$Architecture,
        [string]$AdminGroupName
    )
    Write-Phase 'Remove Edge WebView2 WinSxS assembly'

    $filter = switch ($Architecture) {
        'amd64' { 'amd64_microsoft-edge-webview_31bf3856ad364e35*' }
        'arm64' { 'arm64_microsoft-edge-webview_31bf3856ad364e35*' }
        default { $null }
    }

    if (-not $filter) {
        Write-Output "  Unknown architecture '$Architecture'; skipping WinSxS WebView2 removal."
        return
    }

    $folderPath = Get-ChildItem -Path "$MountDir\Windows\WinSxS" -Filter $filter -Directory -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName

    if (-not $folderPath) {
        Write-Output '  WebView2 WinSxS folder not found; nothing to remove.'
        return
    }

    & 'takeown' '/f' $folderPath '/r' | Out-Null
    & 'icacls' $folderPath '/grant' "${AdminGroupName}:(F)" '/T' '/C' | Out-Null
    Remove-Item -Path $folderPath -Recurse -Force
    Write-Output '  Removed WebView2 WinSxS assembly.'
}

function Remove-WindowsRecoveryEnvironment {
    <#
    .SYNOPSIS
        Removes Windows Recovery Environment (WinRE) to save space on non-serviceable builds.
    .DESCRIPTION
        Core-build-only. Deletes winre.wim and replaces it with an empty placeholder so
        components that expect the file to exist don't error. Disables recovery/reset
        features.
    #>
    param (
        [string]$MountDir
    )
    Write-Phase 'Remove Windows Recovery Environment'
    $recoveryPath = "$MountDir\Windows\System32\Recovery"
    $winrePath = "$recoveryPath\winre.wim"

    & 'takeown' '/f' $recoveryPath '/r' | Out-Null
    & 'icacls' $recoveryPath '/grant' 'Administrators:F' '/T' '/C' | Out-Null

    if (Test-Path $winrePath) {
        Remove-Item -Path $winrePath -Force
    }
    New-Item -Path $winrePath -ItemType File -Force | Out-Null
    Write-Output '  WinRE removed (empty placeholder left in place).'
}

function Compress-WinSxS {
    <#
    .SYNOPSIS
        Strips WinSxS down to an architecture-specific allowlist of essential assemblies.
    .DESCRIPTION
        Core-build-only, non-serviceable size reduction: copies only the assemblies
        required for basic operation (VC++ runtimes, common controls, GDI+, servicing
        stack, catalogs, manifests) into a new folder, then replaces WinSxS with it. This
        makes the image unable to add Windows Updates, languages, or features.

        Ported from asl-win11-coremaker.ps1, which had two bugs fixed here: the copy loop
        ran twice for amd64 (once inside the architecture branch, once again
        unconditionally afterward), and $dirsToCopy was undefined for any architecture
        other than amd64/arm64, which would have thrown when the unconditional copy ran.
    #>
    param (
        [string]$MountDir,
        [string]$Architecture,
        [string]$AdminGroupName
    )
    Write-Phase 'Compress WinSxS to essential assemblies'

    $sourceDirectory = "$MountDir\Windows\WinSxS"
    $destinationDirectory = "$MountDir\Windows\WinSxS_edit"

    Write-Output '  Taking ownership of the WinSxS folder. This might take a while...'
    & 'takeown' '/f' $sourceDirectory '/r' | Out-Null
    & 'icacls' $sourceDirectory '/grant' "${AdminGroupName}:(F)" '/T' '/C' | Out-Null

    $dirsToCopy = switch ($Architecture) {
        'amd64' {
            @(
                'x86_microsoft.windows.common-controls_6595b64144ccf1df_*'
                'x86_microsoft.windows.gdiplus_6595b64144ccf1df_*'
                'x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*'
                'x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*'
                'x86_microsoft-windows-s..ngstack-onecorebase_31bf3856ad364e35_*'
                'x86_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*'
                'x86_microsoft-windows-servicingstack_31bf3856ad364e35_*'
                'x86_microsoft-windows-servicingstack-inetsrv_*'
                'x86_microsoft-windows-servicingstack-onecore_*'
                'amd64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*'
                'amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*'
                'amd64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*'
                'amd64_microsoft.windows.common-controls_6595b64144ccf1df_*'
                'amd64_microsoft.windows.gdiplus_6595b64144ccf1df_*'
                'amd64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*'
                'amd64_microsoft.windows.isolationautomation_6595b64144ccf1df_*'
                'amd64_microsoft-windows-s..stack-inetsrv-extra_31bf3856ad364e35_*'
                'amd64_microsoft-windows-s..stack-msg.resources_31bf3856ad364e35_*'
                'amd64_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*'
                'amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*'
                'amd64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*'
                'amd64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*'
                'amd64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*'
                'Catalogs'
                'FileMaps'
                'Fusion'
                'InstallTemp'
                'Manifests'
                'x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*'
                'x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*'
                'x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*'
            )
        }
        'arm64' {
            @(
                'arm64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*'
                'Catalogs'
                'FileMaps'
                'Fusion'
                'InstallTemp'
                'Manifests'
                'SettingsManifests'
                'Temp'
                'x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*'
                'x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*'
                'x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*'
                'x86_microsoft.windows.common-controls_6595b64144ccf1df_*'
                'x86_microsoft.windows.gdiplus_6595b64144ccf1df_*'
                'x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*'
                'x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*'
                'arm_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*'
                'arm_microsoft.windows.common-controls_6595b64144ccf1df_*'
                'arm_microsoft.windows.gdiplus_6595b64144ccf1df_*'
                'arm_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*'
                'arm_microsoft.windows.isolationautomation_6595b64144ccf1df_*'
                'arm64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*'
                'arm64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*'
                'arm64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*'
                'arm64_microsoft.windows.common-controls_6595b64144ccf1df_*'
                'arm64_microsoft.windows.gdiplus_6595b64144ccf1df_*'
                'arm64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*'
                'arm64_microsoft.windows.isolationautomation_6595b64144ccf1df_*'
                'arm64_microsoft-windows-servicing-adm_31bf3856ad364e35_*'
                'arm64_microsoft-windows-servicingcommon_31bf3856ad364e35_*'
                'arm64_microsoft-windows-servicing-onecore-uapi_31bf3856ad364e35_*'
                'arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*'
                'arm64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*'
                'arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*'
            )
        }
        default {
            Write-Log "Unknown architecture '$Architecture'; skipping WinSxS compression to avoid deleting an unrecognized layout." 'WARN'
            $null
        }
    }

    if (-not $dirsToCopy) {
        return
    }

    New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null

    foreach ($dir in $dirsToCopy) {
        $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory -ErrorAction SilentlyContinue
        foreach ($sourceDir in $sourceDirs) {
            $destDir = Join-Path -Path $destinationDirectory -ChildPath $sourceDir.Name
            Copy-Item -Path $sourceDir.FullName -Destination $destDir -Recurse -Force
        }
    }

    Write-Output '  Deleting original WinSxS. This may take a while...'
    Remove-Item -Path $sourceDirectory -Recurse -Force
    Rename-Item -Path $destinationDirectory -NewName 'WinSxS'
    Write-Output '  WinSxS compressed to essential assemblies.'
}

#---------[ Answer File & Edition Enforcement Functions ]---------#

function Get-GenericVolumeLicenseKey {
    <#
    .SYNOPSIS
        Looks up the Windows 11 Generic Volume License Key (GVLK / KMS client setup key) for a
        DISM edition ID, e.g. "Professional" -> W269N-WFGWX-YVC9B-4J6C9-T83GX.
    .DESCRIPTION
        GVLKs are real, Microsoft-published per-edition keys (see
        https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys),
        published specifically so a generic multi-edition ISO's Setup can select an edition and
        pass product-key validation without a real retail license. They do NOT activate Windows
        on their own - there's no KMS host on the network to answer them - so the installed
        system ends up "not activated", the same end state as installing with no key at all.
        What they buy is a fully silent Setup: WillShowUI=Never plus a GVLK validates
        successfully, whereas WillShowUI=Never plus a blank/placeholder key hard-fails (see
        ConvertTo-Tiny11AnswerFile), and the placeholder+WillShowUI=Always fallback needs one
        manual "I don't have a product key" click. Used by Initialize-PreparedAnswerFile as the
        default -ProductKey substitute whenever the detected edition has a known GVLK.

        Windows 11 Home ("Core"/"CoreSingleLanguage") deliberately has no entry - Home was never
        sold as a volume-licensed SKU, so Microsoft doesn't publish a GVLK for it; callers must
        fall back to the placeholder-key/WillShowUI=Always path for that edition.
    #>
    param (
        [string]$EditionId
    )

    $gvlkMap = @{
        'Professional'             = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
        'ProfessionalN'            = 'MH37W-N47XK-V7XM9-C7227-GCQG9'
        'ProfessionalWorkstation'  = 'NRG8B-VKK3Q-CXVCJ-9G2XF-6Q84J'
        'ProfessionalWorkstationN' = '9FNHH-K3HBT-3W4TD-6383H-6XYWF'
        'ProfessionalEducation'    = '6TP4R-GNPTD-KYYHQ-7B7DP-J447Y'
        'ProfessionalEducationN'   = 'YVWGF-BXNMC-HTQYQ-CPQ99-66QFC'
        'Education'                = 'NW6C2-QMPVW-D7KKK-3GKT6-VCFB2'
        'EducationN'               = '2WH4N-8QGBV-H22JP-CT43Q-MDWWJ'
        'Enterprise'               = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
        'EnterpriseN'              = 'DPH2V-TTNVB-4X9Q3-TJR4H-KHJW4'
    }

    return $gvlkMap[$EditionId]
}

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
        Injects the selected install image index and product-key handling into autounattend.xml.
    .DESCRIPTION
        Namespace-aware edit of the windowsPE/Microsoft-Windows-Setup/ImageInstall/OSImage/
        InstallFrom node so Setup installs the edition actually chosen via
        Resolve-InstallImageIndex, instead of relying on the answer file's own (possibly
        stale) assumptions.

        Also ensures UserData/AcceptEula is present and UserData/ProductKey/Key exists, so
        Setup never blocks on the "Enter your product key" screen being entirely absent (Rufus
        hits the same requirement — reference/rufus/src/wue.c:145-151: "WinPE will complain if
        we don't provide a product key. *Any* product key."). When -ProductKey supplies a real
        key, it's embedded with WillShowUI forced to 'Never' so Setup validates and
        auto-activates against it silently. Without a real key, a genuinely empty <Key/> plus
        no WillShowUI (Rufus's own approach) turned out to still trip a hard "Setup has failed
        to validate the product key" failure in practice on at least one real install, so this
        falls back to tiny11-automated's pattern instead (reference/tiny11-automated's
        Schneegans-generated template): the placeholder key '00000-00000-00000-00000-00000'
        with WillShowUI set to 'Always'. That trades full silence for reliability — Setup shows
        the product-key screen once, where clicking "I don't have a product key" continues the
        install — rather than a hard failure with no way to proceed.
    #>
    param (
        [Parameter(Mandatory)][string]$XmlContent,
        [int]$ImageIndex = 1,
        [string]$ProductKey = ''
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

    # No explicit xmlns:wcm declaration needed here: .NET's XmlWriter automatically emits
    # the namespace declaration on whichever element ends up carrying a wcm:-prefixed
    # attribute (see the wcm:action attribute below), the same way the source
    # autounattend.xml declares xmlns:wcm locally on each <component> that needs it.

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

    $userData = Get-AnswerFileChildElement -Parent $setupComponent -Name 'UserData' -NamespaceUri $unattendNs

    $acceptEulaElement = Get-AnswerFileChildElement -Parent $userData -Name 'AcceptEula' -NamespaceUri $unattendNs
    $acceptEulaElement.InnerText = 'true'

    $productKeyElement = Get-AnswerFileChildElement -Parent $userData -Name 'ProductKey' -NamespaceUri $unattendNs

    $placeholderProductKey = '00000-00000-00000-00000-00000'
    $productKeyValue = if ($ProductKey) { $ProductKey.Trim() } else { '' }
    if ($productKeyValue -eq $placeholderProductKey) { $productKeyValue = '' }
    $hasRealProductKey = [bool]$productKeyValue

    $productKeyKeyElement = Get-AnswerFileChildElement -Parent $productKeyElement -Name 'Key' -NamespaceUri $unattendNs
    $productKeyKeyElement.InnerText = if ($hasRealProductKey) { $productKeyValue } else { $placeholderProductKey }

    $willShowUiElement = Get-AnswerFileChildElement -Parent $productKeyElement -Name 'WillShowUI' -NamespaceUri $unattendNs
    $willShowUiElement.InnerText = if ($hasRealProductKey) { 'Never' } else { 'Always' }

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

function Add-AnswerFileBypassCommands {
    <#
    .SYNOPSIS
        Embeds Windows 11 hardware-bypass reg-add commands into autounattend.xml.
    .DESCRIPTION
        Rufus-style fallback (reference/rufus/src/wue.c:244-251) for the LabConfig bypass:
        appends <RunSynchronous><RunSynchronousCommand> entries to the windowsPE
        Microsoft-Windows-Setup component that run `reg add` against
        HKLM\SYSTEM\Setup\LabConfig during Setup itself, instead of pre-editing the offline
        SYSTEM hive. Useful as a fallback when direct hive access isn't available.
        Rufus itself only sets BypassTPMCheck/BypassSecureBootCheck/BypassRAMCheck; this
        emits all five LabConfig keys for parity with Set-BypassHardwareChecks.
    #>
    param (
        [Parameter(Mandatory)][string]$XmlContent
    )

    $unattendNs = 'urn:schemas-microsoft-com:unattend'
    $wcmNs = 'http://schemas.microsoft.com/WMIConfig/2002/State'

    $xmlDoc = [xml]::new()
    $xmlDoc.PreserveWhitespace = $true
    $xmlDoc.LoadXml($XmlContent)

    if ($xmlDoc.DocumentElement.NamespaceURI -ne $unattendNs) {
        throw "Unexpected autounattend.xml namespace: $($xmlDoc.DocumentElement.NamespaceURI)"
    }

    # No explicit xmlns:wcm declaration needed here: .NET's XmlWriter automatically emits
    # the namespace declaration on whichever element ends up carrying a wcm:-prefixed
    # attribute (see the wcm:action attributes below), the same way the source
    # autounattend.xml declares xmlns:wcm locally on each <component> that needs it.

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

    $existingRunSynchronous = @($setupComponent.SelectNodes('u:RunSynchronous', $nsMgr))
    foreach ($node in $existingRunSynchronous) {
        [void]$setupComponent.RemoveChild($node)
    }

    $runSynchronous = $xmlDoc.CreateElement('RunSynchronous', $unattendNs)

    $bypassKeys = @('BypassCPUCheck', 'BypassRAMCheck', 'BypassSecureBootCheck', 'BypassStorageCheck', 'BypassTPMCheck')
    $order = 1
    foreach ($bypassKey in $bypassKeys) {
        $commandElement = $xmlDoc.CreateElement('RunSynchronousCommand', $unattendNs)
        $actionAttribute = $xmlDoc.CreateAttribute('wcm', 'action', $wcmNs)
        $actionAttribute.Value = 'add'
        [void]$commandElement.Attributes.Append($actionAttribute)

        $orderElement = $xmlDoc.CreateElement('Order', $unattendNs)
        $orderElement.InnerText = [string]$order
        [void]$commandElement.AppendChild($orderElement)

        $pathElement = $xmlDoc.CreateElement('Path', $unattendNs)
        $pathElement.InnerText = "reg add HKLM\SYSTEM\Setup\LabConfig /v $bypassKey /t REG_DWORD /d 1 /f"
        [void]$commandElement.AppendChild($pathElement)

        [void]$runSynchronous.AppendChild($commandElement)
        $order++
    }

    [void]$setupComponent.AppendChild($runSynchronous)

    return $xmlDoc.OuterXml
}

function Add-AnswerFileLocalAccount {
    <#
    .SYNOPSIS
        Embeds a local-account creation block into autounattend.xml.
    .DESCRIPTION
        Rufus-style local account creation (reference/rufus/src/wue.c:344-383): adds
        <UserAccounts><LocalAccounts><LocalAccount> under the oobeSystem pass's
        Microsoft-Windows-Shell-Setup component, in Administrators, appended after
        whatever that component already has (matching Rufus's own OOBE-then-UserAccounts
        order, which is the order actually exercised in practice).

        Deliberately does NOT follow Rufus's blank-password / "change at first logon" flow
        (wue.c:363-382, which needs a magic Base64 "Password" placeholder plus a
        FirstLogonCommand to force a change). Setting the account's password to the same
        value as its name means no password generation/storage/encoding logic is needed
        here at all - the cost is a weak, publicly-guessable password, which is fine for a
        disposable/dev image never exposed to an untrusted network or user, but this is not
        a hardening feature.
    #>
    param (
        [Parameter(Mandatory)][string]$XmlContent,
        [Parameter(Mandatory)][string]$AccountName
    )

    # From https://learn.microsoft.com/en-us/archive/technet-wiki/13813.localized-names-for-administrator-account-in-windows
    # (English subset only - Rufus also blocks several localized "Administrator" spellings).
    $unallowedAccountNames = @('Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount', 'HelpAssistant', 'KRBTGT', 'Local', 'NONE', 'SYSTEM')
    if ($unallowedAccountNames -contains $AccountName) {
        throw "'$AccountName' is a reserved Windows account name and can't be used for -LocalAccountName."
    }

    $sanitizedName = $AccountName -replace '[/\\\[\]:;|=.,+*?<>%@&"]', '_'
    if ($sanitizedName -ne $AccountName) {
        Write-Log "Local account name '$AccountName' contained unallowed characters; sanitized to '$sanitizedName'." 'WARN'
    }
    if ([string]::IsNullOrWhiteSpace($sanitizedName)) {
        throw "-LocalAccountName resolved to an empty name after sanitization."
    }

    $unattendNs = 'urn:schemas-microsoft-com:unattend'
    $wcmNs = 'http://schemas.microsoft.com/WMIConfig/2002/State'

    $xmlDoc = [xml]::new()
    $xmlDoc.PreserveWhitespace = $true
    $xmlDoc.LoadXml($XmlContent)

    if ($xmlDoc.DocumentElement.NamespaceURI -ne $unattendNs) {
        throw "Unexpected autounattend.xml namespace: $($xmlDoc.DocumentElement.NamespaceURI)"
    }

    $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
    $nsMgr.AddNamespace('u', $unattendNs)

    $oobeSettings = $xmlDoc.SelectSingleNode('/u:unattend/u:settings[@pass="oobeSystem"]', $nsMgr)
    if (-not $oobeSettings) {
        $oobeSettings = $xmlDoc.CreateElement('settings', $unattendNs)
        $oobeSettings.SetAttribute('pass', 'oobeSystem')
        [void]$xmlDoc.DocumentElement.AppendChild($oobeSettings)
    }

    $shellSetupComponent = $oobeSettings.SelectSingleNode('u:component[@name="Microsoft-Windows-Shell-Setup"]', $nsMgr)
    if (-not $shellSetupComponent) {
        $shellSetupComponent = $xmlDoc.CreateElement('component', $unattendNs)
        $shellSetupComponent.SetAttribute('name', 'Microsoft-Windows-Shell-Setup')
        $shellSetupComponent.SetAttribute('processorArchitecture', 'amd64')
        $shellSetupComponent.SetAttribute('publicKeyToken', '31bf3856ad364e35')
        $shellSetupComponent.SetAttribute('language', 'neutral')
        $shellSetupComponent.SetAttribute('versionScope', 'nonSxS')
        [void]$oobeSettings.AppendChild($shellSetupComponent)
    }

    $existingUserAccounts = @($shellSetupComponent.SelectNodes('u:UserAccounts', $nsMgr))
    foreach ($node in $existingUserAccounts) {
        [void]$shellSetupComponent.RemoveChild($node)
    }

    $userAccounts = $xmlDoc.CreateElement('UserAccounts', $unattendNs)
    $localAccounts = $xmlDoc.CreateElement('LocalAccounts', $unattendNs)
    $localAccount = $xmlDoc.CreateElement('LocalAccount', $unattendNs)
    $actionAttribute = $xmlDoc.CreateAttribute('wcm', 'action', $wcmNs)
    $actionAttribute.Value = 'add'
    [void]$localAccount.Attributes.Append($actionAttribute)

    $nameElement = $xmlDoc.CreateElement('Name', $unattendNs)
    $nameElement.InnerText = $sanitizedName
    [void]$localAccount.AppendChild($nameElement)

    $displayNameElement = $xmlDoc.CreateElement('DisplayName', $unattendNs)
    $displayNameElement.InnerText = $sanitizedName
    [void]$localAccount.AppendChild($displayNameElement)

    $groupElement = $xmlDoc.CreateElement('Group', $unattendNs)
    $groupElement.InnerText = 'Administrators'
    [void]$localAccount.AppendChild($groupElement)

    $passwordElement = $xmlDoc.CreateElement('Password', $unattendNs)
    $passwordValueElement = $xmlDoc.CreateElement('Value', $unattendNs)
    $passwordValueElement.InnerText = $sanitizedName
    [void]$passwordElement.AppendChild($passwordValueElement)
    $plainTextElement = $xmlDoc.CreateElement('PlainText', $unattendNs)
    $plainTextElement.InnerText = 'true'
    [void]$passwordElement.AppendChild($plainTextElement)
    [void]$localAccount.AppendChild($passwordElement)

    [void]$localAccounts.AppendChild($localAccount)
    [void]$userAccounts.AppendChild($localAccounts)
    [void]$shellSetupComponent.AppendChild($userAccounts)

    return $xmlDoc.OuterXml
}

function Add-AnswerFileLocale {
    <#
    .SYNOPSIS
        Embeds locale/keyboard settings into autounattend.xml so OOBE doesn't ask.
    .DESCRIPTION
        Rufus-style regional-options block (reference/rufus/src/wue.c:462-478): adds an
        oobeSystem-pass <component name="Microsoft-Windows-International-Core"> setting
        InputLocale/SystemLocale/UserLocale/UILanguage. Rufus sources these from the host
        machine running Rufus; this repo already detects the mounted image's own default UI
        language via DISM in Show-ImageMetadata ($script:languageCode, e.g. "en-US"), which is
        the more correct source here since the builder machine's locale has no bearing on the
        image being built. Without this block Setup has no locale answer for the oobeSystem
        pass and falls back to asking interactively. Skipped entirely if the image's language
        couldn't be detected, rather than guessing.
    #>
    param (
        [Parameter(Mandatory)][string]$XmlContent,
        [Parameter(Mandatory)][string]$LanguageCode
    )

    $unattendNs = 'urn:schemas-microsoft-com:unattend'

    $xmlDoc = [xml]::new()
    $xmlDoc.PreserveWhitespace = $true
    $xmlDoc.LoadXml($XmlContent)

    if ($xmlDoc.DocumentElement.NamespaceURI -ne $unattendNs) {
        throw "Unexpected autounattend.xml namespace: $($xmlDoc.DocumentElement.NamespaceURI)"
    }

    $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
    $nsMgr.AddNamespace('u', $unattendNs)

    $oobeSettings = $xmlDoc.SelectSingleNode('/u:unattend/u:settings[@pass="oobeSystem"]', $nsMgr)
    if (-not $oobeSettings) {
        $oobeSettings = $xmlDoc.CreateElement('settings', $unattendNs)
        $oobeSettings.SetAttribute('pass', 'oobeSystem')
        [void]$xmlDoc.DocumentElement.AppendChild($oobeSettings)
    }

    $intlComponent = $oobeSettings.SelectSingleNode('u:component[@name="Microsoft-Windows-International-Core"]', $nsMgr)
    if (-not $intlComponent) {
        $intlComponent = $xmlDoc.CreateElement('component', $unattendNs)
        $intlComponent.SetAttribute('name', 'Microsoft-Windows-International-Core')
        $intlComponent.SetAttribute('processorArchitecture', 'amd64')
        $intlComponent.SetAttribute('publicKeyToken', '31bf3856ad364e35')
        $intlComponent.SetAttribute('language', 'neutral')
        $intlComponent.SetAttribute('versionScope', 'nonSxS')
        [void]$oobeSettings.PrependChild($intlComponent)
    }

    foreach ($elementName in @('InputLocale', 'SystemLocale', 'UserLocale', 'UILanguage')) {
        $element = Get-AnswerFileChildElement -Parent $intlComponent -Name $elementName -NamespaceUri $unattendNs
        $element.InnerText = $LanguageCode
    }

    return $xmlDoc.OuterXml
}

function Set-Tiny11EditionConfig {
    <#
    .SYNOPSIS
        Pins the selected edition via sources\ei.cfg and removes sources\PID.txt.
    .DESCRIPTION
        Without this, Setup can fall back to a stale firmware-embedded product key that
        doesn't match the edition actually selected via Resolve-InstallImageIndex, causing
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

#---------[ Driver Injection Functions ]---------#

function Add-DriversToImage {
    <#
    .SYNOPSIS
        Injects every driver found under a folder into a mounted image via DISM.
    .DESCRIPTION
        Thin wrapper around dism /Add-Driver /Recurse, shared by host-driver, custom
        -DriverPath, and virtio driver injection into install.wim. boot.wim no longer goes
        through this path (see Add-WinPEStorageDrivers) - installing the full driver set
        into WinPE would bloat boot.wim with GPU/audio/printer drivers it never needs, and
        require an extra mount/commit cycle just to add them.
        Uses Write-Host, not Write-Output, per this file's logging convention: callers like
        Add-VirtioDriversToImage return a value the caller captures directly, and stray
        Write-Output text here would corrupt that captured value.
    #>
    param (
        [string]$MountPath,
        [string]$DriverPath,
        [string]$Label
    )
    Write-Host "  Injecting drivers into $Label from $DriverPath..."
    Invoke-Dism -ArgumentList @('/English', "/image:$MountPath", '/Add-Driver', "/Driver:$DriverPath", '/Recurse') | Out-Null
    Write-Host "  Driver injection into $Label complete."
}

function Export-HostSystemDrivers {
    <#
    .SYNOPSIS
        Exports every third-party driver from the currently running system.
    .DESCRIPTION
        Sets $script:hostDriverPath so both install.wim and boot.wim injection reuse the
        same export instead of re-exporting. Staged under the build scratch root so the
        existing cleanup path owns it.
    #>
    Write-Phase 'Export host system drivers'
    $destination = Join-Path $script:BuildScratchRoot 'drivers\host'
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Export-WindowsDriver -Online -Destination $destination | Out-Null
    Write-Host "  Host drivers exported to $destination."
    $script:hostDriverPath = $destination
    return $destination
}

function Resolve-SevenZipPath {
    <#
    .SYNOPSIS
        Locates 7z.exe, used to extract virtio-win.iso instead of mounting it.
    #>
    $command = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidates = @(
        "$Env:ProgramFiles\7-Zip\7z.exe",
        "${Env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    throw "7-Zip (7z.exe) was not found on PATH or in the standard install location. Install 7-Zip " +
        "(https://www.7-zip.org/) or pass -VirtioIso pointing at an already-extracted driver folder instead."
}

function Expand-VirtioIso {
    <#
    .SYNOPSIS
        Extracts a virtio-win .iso into a cached folder via 7-Zip instead of mounting it.
    .DESCRIPTION
        Cached under <SCRATCH>\virtiocache\<iso base name>\, keyed by the ISO's own file
        name so a different virtio-win version naturally gets its own cache folder instead
        of silently reusing a stale extraction. Unlike work\drivers\, this directory is
        never touched by Invoke-Tiny11Cleanup / Invoke-Tiny11EmergencyCleanup - like
        sourcecache\, it survives across runs; delete it manually to force a re-extract.

        Mounting the ISO (the old approach) required Mount-DiskImage/Dismount-DiskImage and
        tracking $script:virtioIsoMountedPath so a crashed run didn't leave the driver ISO
        mounted. Extracting to a persistent cache avoids that lifecycle entirely and means
        reruns with the same -VirtioIso skip the extraction step too.
    #>
    param ([Parameter(Mandatory)][string]$IsoPath)

    $cacheKey = [System.IO.Path]::GetFileNameWithoutExtension($IsoPath)
    $extractDir = Join-Path $script:BuildScratchRoot "virtiocache\$cacheKey"

    $alreadyExtracted = (Test-Path -LiteralPath $extractDir) -and
        (Get-ChildItem -Path $extractDir -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($alreadyExtracted) {
        Write-Host "  Reusing cached virtio-win extraction at $extractDir"
        return $extractDir
    }

    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -Path $extractDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

    $sevenZip = Resolve-SevenZipPath
    Write-Host "  Extracting virtio-win.iso to $extractDir..."
    & $sevenZip 'x' $IsoPath "-o$extractDir" '-y' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip failed to extract '$IsoPath' (exit code $LASTEXITCODE)."
    }

    return $extractDir
}

function Resolve-VirtioDriverSource {
    <#
    .SYNOPSIS
        Resolves the virtio-win driver root, downloading the stable ISO if none was given.
    .DESCRIPTION
        -VirtioIso may be a drive letter (already-mounted ISO), a path to an .iso file
        (extracted here via Expand-VirtioIso rather than mounted), or an already-extracted
        folder. When omitted, first looks for an already-extracted virtio-win cache folder
        under <SCRATCH>\virtiocache\ (any prior Expand-VirtioIso output, keyed by ISO file
        name) and reuses the most recently written one if found - no network access at all.
        Only when no such cache exists does it download the latest stable virtio-win.iso -
        cached under <SCRATCH>\virtiocache\download\ so reruns skip the download - and
        extract that.

        The downloaded file is size-sanity-checked before extraction: fedorapeople.org (the
        upstream virtio-win host) sits behind an "Anubis" JavaScript proof-of-work anti-bot
        gate that serves a small HTML challenge page (with a 200 status) to non-browser
        HTTP clients instead of the real ISO. Without this check, that HTML page gets
        written to virtio-win.iso and only fails much later, cryptically, at extraction. If
        the auto-download keeps failing this check, download virtio-win.iso manually in a
        browser (which can pass the JS challenge) and pass it via -VirtioIso instead.
    #>
    param (
        [string]$VirtioIso
    )
    Write-Phase 'Resolve virtio-win driver source'

    if ($VirtioIso -and (Test-Path $VirtioIso -PathType Container)) {
        Write-Host "  Using extracted virtio driver folder: $VirtioIso"
        return $VirtioIso
    }

    if ($VirtioIso -and $VirtioIso -match '^[c-zC-Z]:?$') {
        $driveLetter = $VirtioIso.TrimEnd(':') + ':'
        Write-Host "  Using virtio driver source already mounted at $driveLetter"
        return $driveLetter
    }

    $isoPath = $null
    if ($VirtioIso -and (Test-Path $VirtioIso -PathType Leaf)) {
        $isoPath = $VirtioIso
        Write-Host "  Using local virtio ISO: $isoPath"
    } else {
        $virtioCacheRoot = Join-Path $script:BuildScratchRoot 'virtiocache'
        $cachedExtraction = Get-ChildItem -Path $virtioCacheRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'download' } |
            Where-Object { Get-ChildItem -Path $_.FullName -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1 } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($cachedExtraction) {
            Write-Host "  No -VirtioIso given; reusing most recent cached extraction at $($cachedExtraction.FullName)."
            return $cachedExtraction.FullName
        }

        $downloadDir = Join-Path $script:BuildScratchRoot 'virtiocache\download'
        New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
        $isoPath = Join-Path $downloadDir 'virtio-win.iso'
        $minimumExpectedBytes = 100MB

        $cachedDownloadValid = (Test-Path -LiteralPath $isoPath) -and
            (Get-Item -LiteralPath $isoPath).Length -ge $minimumExpectedBytes
        if ($cachedDownloadValid) {
            Write-Host "  Reusing cached download at $isoPath."
        } else {
            Write-Host '  No -VirtioIso given; downloading the latest stable virtio-win.iso...'
            $downloadUrl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'
            Invoke-WebRequest -Uri $downloadUrl -OutFile $isoPath -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'

            $downloadedSize = (Get-Item $isoPath).Length
            if ($downloadedSize -lt $minimumExpectedBytes) {
                $preview = (Get-Content -Path $isoPath -TotalCount 1 -ErrorAction SilentlyContinue)
                Remove-Item -Path $isoPath -Force -ErrorAction SilentlyContinue
                throw "Downloaded virtio-win.iso is only $downloadedSize bytes (expected several hundred MB) - " +
                    "this is almost certainly an anti-bot challenge page from $downloadUrl, not the real ISO " +
                    "(first line of response: '$preview'). Download virtio-win.iso manually in a browser and " +
                    "pass it via -VirtioIso instead."
            }
            Write-Host "  Downloaded virtio-win.iso to $isoPath ($downloadedSize bytes)."
        }
    }

    return Expand-VirtioIso -IsoPath $isoPath
}

function Add-VirtioDriversToImage {
    <#
    .SYNOPSIS
        Stages the virtio drivers matching this image's architecture/OS and injects them.
    .DESCRIPTION
        The virtio-win ISO is laid out <root>\<driver>\<osdir>\<arch>\. Copying only the
        folders matching $script:architecture and w11 (falling back to w10 when a driver
        hasn't shipped a w11-specific build yet) avoids /Add-Driver /Recurse pulling in
        every other OS variant's INF files.

        Returns the staging directory path so the caller can pass the same, already-staged
        folder to Add-WinPEStorageDrivers afterward instead of re-resolving/re-copying it -
        that call picks the storage-class subset (viostor/vioscsi) back out of everything
        staged here for the boot-media $WinpeDriver$ drop. Returns $null when nothing was
        staged.
    #>
    param (
        [string]$MountPath,
        [string]$VirtioRoot
    )
    Write-Phase 'Inject virtio-win drivers'

    $archFolder = switch ($script:architecture) {
        'amd64' { 'amd64' }
        'arm64' { 'ARM64' }
        default { 'amd64' }
    }

    $stagingDir = Join-Path $script:BuildScratchRoot 'drivers\virtio'
    New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

    $driverDirs = Get-ChildItem -Path $VirtioRoot -Directory -ErrorAction SilentlyContinue
    $stagedCount = 0
    foreach ($driverDir in $driverDirs) {
        foreach ($osDirName in @('w11', 'w10')) {
            $candidate = Join-Path $driverDir.FullName "$osDirName\$archFolder"
            if (Test-Path $candidate) {
                $destination = Join-Path $stagingDir $driverDir.Name
                Copy-Item -Path $candidate -Destination $destination -Recurse -Force
                $stagedCount += 1
                break
            }
        }
    }

    if ($stagedCount -eq 0) {
        Write-Log "No virtio driver folders matched architecture '$archFolder' under $VirtioRoot; nothing staged." 'WARN'
        return $null
    }

    Write-Host "  Staged $stagedCount virtio driver folder(s)."
    Add-DriversToImage -MountPath $MountPath -DriverPath $stagingDir -Label 'virtio'
    return $stagingDir
}

function Test-StorageDriverInf {
    <#
    .SYNOPSIS
        Detects whether a driver .inf targets mass-storage/RAID hardware.
    .DESCRIPTION
        Backing check for Add-WinPEStorageDrivers: WinPE only needs to see the target disk,
        not the full hardware set (GPU/audio/NIC/etc.), so only storage-class drivers are
        worth staging into $WinpeDriver$ (and, via Add-DriversToImage, injecting into
        boot.wim - see Update-BootImage). Matches only the INF's own Class directive against
        SCSIAdapter/HDC.

        This used to also fall back to a filename pattern (iaahci/iastor/vmd/irst/rst/
        viostor/vioscsi/nvme) for driver families that sometimes omit or vary the Class
        line. That fallback was removed after winutil's Test-WinUtilISOStorageDriver
        (reference/winutil/functions/private/Invoke-WinUtilISOScript.ps1) dropped the same
        pattern upstream (commit abcbc23, "fix: inject Setup storage into boot.wim"): a
        same-vendor "companion" INF (e.g. an Intel RST management/UI component, not the
        storage driver itself) can share enough of the filename pattern to match, while
        declaring a non-storage Class - so the filename fallback both staged drivers Setup
        never needed for WinPE and risked missing the actual narrower signal. Matching only
        Class=SCSIAdapter|HDC is narrower but correct: every virtio (vioscsi/viostor) and
        NVMe storage driver this repo has needed in practice declares one of those two
        classes properly, so nothing in this repo's own driver sources is known to rely on
        the removed fallback.
    #>
    param ([Parameter(Mandatory)][System.IO.FileInfo]$InfFile)

    try {
        return (Get-Content -LiteralPath $InfFile.FullName -Raw -ErrorAction Stop) -match '(?im)^\s*Class\s*=\s*(SCSIAdapter|HDC)\s*(?:;.*)?$'
    } catch {
        Write-Log "Could not classify driver '$($InfFile.FullName)' for WinPE staging: $_" 'WARN'
        return $false
    }
}

function Copy-WinPEDriverFolder {
    <#
    .SYNOPSIS
        Copies a driver package folder into a destination, avoiding name collisions.
    .DESCRIPTION
        Different driver sources (host export, -DriverPath, virtio) can both contain a
        folder with the same name; appends a numeric suffix instead of overwriting.
    #>
    param (
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $folderName = Split-Path $Source -Leaf
    $targetPath = Join-Path $Destination $folderName
    $suffix = 1
    while (Test-Path -LiteralPath $targetPath) {
        $targetPath = Join-Path $Destination "${folderName}_$suffix"
        $suffix++
    }

    Copy-Item -LiteralPath $Source -Destination $targetPath -Recurse -Force
    return $targetPath
}

function Add-WinPEStorageDrivers {
    <#
    .SYNOPSIS
        Stages storage/RAID-controller drivers into $WinpeDriver$ at the ISO root.
    .DESCRIPTION
        Windows Setup auto-loads drivers from a $WinpeDriver$ folder at the root of the
        installation media during its windowsPE pass - Setup.exe scans every drive letter
        C: and above for one (Microsoft KB2686316; confirmed working from optical/ISO media,
        not just USB). This is the primary mechanism for getting Setup to see an unusual
        disk controller (virtio, an exotic RAID card, etc.) without injecting the *entire*
        driver source into boot.wim via Add-DriversToImage, which would bloat boot.wim with
        every non-storage driver (GPU/audio/NIC/etc.) install.wim's own driver injection
        already covers for the installed OS. Update-BootImage additionally re-injects this
        same already-storage-filtered folder into boot.wim directly via DISM as a second
        delivery path (mirroring winutil's abcbc23 fix) - that reuses the exact set staged
        here rather than re-scanning the driver source, so it doesn't reintroduce the bloat
        this function exists to avoid.

        Only drivers Test-StorageDriverInf classifies as storage/RAID are staged; everything
        else under -SourcePath is intentionally left out. Mirrors winutil's
        Add-WinUtilISOStagedDrivers / $WinpeDriver$ approach
        (reference/winutil/functions/private/Invoke-WinUtilISOScript.ps1).

        Per KB2686316, a driver staged here won't override one Setup already loaded into
        boot.wim's in-memory driverstore for the same device - but that only matters when
        boot.wim can already see the disk on its own, in which case $WinpeDriver$ was never
        needed for that device anyway.
    #>
    param (
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Write-Log "WinPE storage-driver source not found, skipping: $SourcePath" 'WARN'
        return
    }

    $driverInfs = @(Get-ChildItem -Path $SourcePath -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue)
    if ($driverInfs.Count -eq 0) {
        Write-Host "  No driver INF files found under $SourcePath for $Label; nothing staged for WinPE."
        return
    }

    $driverFolders = @($driverInfs | Group-Object { $_.Directory.FullName })
    $winpeDriverDir = Join-Path $ContentRoot '$WinpeDriver$'
    $stagedCount = 0

    foreach ($driverFolderGroup in $driverFolders) {
        $driverFolder = [string]$driverFolderGroup.Name
        $storageInfs = @($driverFolderGroup.Group | Where-Object { Test-StorageDriverInf -InfFile $_ })
        if ($storageInfs.Count -eq 0) { continue }

        New-Item -Path $winpeDriverDir -ItemType Directory -Force | Out-Null
        $target = Copy-WinPEDriverFolder -Source $driverFolder -Destination $winpeDriverDir
        $stagedCount++
        Write-Host "  Staged $Label storage driver package '$driverFolder' for WinPE as '$target'."
    }

    if ($stagedCount -eq 0) {
        Write-Host "  No storage-class drivers found under $SourcePath for $Label; nothing staged for WinPE."
    } else {
        Write-Host "  Staged $stagedCount $Label storage driver package(s) into `$WinpeDriver`$."
    }
}

function Install-VirtioGuestToolsAtFirstLogon {
    <#
    .SYNOPSIS
        Stages the virtio-win guest tools installer and runs it at first logon.
    .DESCRIPTION
        Copies virtio-win-guest-tools.exe from the ISO root into
        Windows\Setup\Scripts\, then writes an offline RunOnce entry invoking it
        /install /quiet /norestart. The Burn bundle installs every guest feature
        (qemu-ga, balloon driver, vioserial, SPICE agent, ...) in one pass.
        Requires the offline registry hives to already be loaded.
    #>
    param (
        [string]$MountDir,
        [string]$VirtioRoot
    )
    Write-Phase 'Stage virtio guest tools for first logon'

    $installerSource = Join-Path $VirtioRoot 'virtio-win-guest-tools.exe'
    if (-not (Test-Path $installerSource)) {
        Write-Log "virtio-win-guest-tools.exe not found under $VirtioRoot; skipping guest tools install." 'WARN'
        return
    }

    $scriptsDir = Join-Path $MountDir 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
    Copy-Item -Path $installerSource -Destination $scriptsDir -Force

    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'InstallVirtioGuestTools' 'REG_SZ' 'C:\Windows\Setup\Scripts\virtio-win-guest-tools.exe /install /quiet /norestart'
    Write-Output '  virtio guest tools staged; will install at first logon.'
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

function Invoke-HardwareBypassStrategy {
    <#
    .SYNOPSIS
        Applies the hardware-bypass strategy selected via -BypassMode.
    .DESCRIPTION
        Dispatches between the offline registry-hive bypass (Hive), the Rufus-style
        answer-file RunSynchronousCommand bypass (Unattend), both, or neither (None,
        the default). The Unattend path mutates $script:preparedAutounattendXml so both
        Enable-LocalAccountOOBE and New-Tiny11Iso pick up the change.
    #>
    Write-Phase 'Apply hardware bypass strategy'
    Write-Output "  Bypass mode: $BypassMode"

    if ($BypassMode -in @('Hive', 'Both')) {
        Set-BypassHardwareChecks
    }

    if ($BypassMode -in @('Unattend', 'Both')) {
        try {
            $script:preparedAutounattendXml = Add-AnswerFileBypassCommands -XmlContent $script:preparedAutounattendXml
            Write-Output '  Embedded LabConfig bypass commands into autounattend.xml.'
        } catch {
            Write-Log "Could not embed hardware bypass commands into autounattend.xml: $_" 'WARN'
        }
    }

    if ($BypassMode -eq 'None') {
        Write-Output '  Hardware bypass skipped (BypassMode = None).'
    }
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
        Also copies the already-prepared autounattend.xml to Sysprep for automated OOBE
        setup - see Initialize-PreparedAnswerFile, which is what makes this the same
        content New-Tiny11Iso writes to the ISO root.
    #>
    param (
        [string]$MountDir
    )
    Write-Phase 'Enable local account option during OOBE'
    # Bypass Network Requirement for OOBE — allows setup without internet (enables local account)
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
    # Write the prepared autounattend.xml to Sysprep folder to automate OOBE local account setup
    Set-Content -Path "$MountDir\Windows\System32\Sysprep\autounattend.xml" -Value $script:preparedAutounattendXml -Encoding UTF8 -Force
}

function Remove-SensitiveAnswerFilesAtFirstLogon {
    <#
    .SYNOPSIS
        Stages a first-logon cleanup of on-disk autounattend.xml/unattend.xml copies.
    .DESCRIPTION
        autounattend.xml can carry sensitive content: a real -ProductKey, and - when
        -LocalAccountName is used - a plaintext password equal to the account name
        (CLAUDE.md's documented trade-off for that switch). Windows Setup and this repo's
        own pipeline both leave copies of that content sitting on the installed system where
        any later user/process with filesystem access can read it back out:
          - Windows\System32\Sysprep\autounattend.xml - written directly into install.wim
            offline by Enable-LocalAccountOOBE, so Setup can find an answer file via that
            well-known location during OOBE.
          - Windows\Panther\unattend.xml / unattend-original.xml - Setup's own copy of
            whatever autounattend.xml it consumed from the ISO root (New-Tiny11Iso), made
            live during installation; this repo never writes these directly, but every build
            produces an autounattend.xml Setup will copy here regardless of -KeepCorporateApps
            or -LocalAccountName.
        Ported from unattend-generator's DeleteModifier
        (reference/unattend-generator/modifier/Delete.cs), which deletes the same Panther
        copies (plus a Wifi.xml this repo doesn't embed) via a first-logon script for the
        same reason - see docs/answer-file-generators-options.md.
        A single RunOnce command line (not a staged script, matching Disable-WindowsUpdate's
        style) runs once after the first interactive logon, once Setup no longer needs any
        of these files; cmd.exe's `del` silently no-ops on paths that don't exist (e.g. the
        Sysprep copy under a -KeepCorporateApps build, which skips Enable-LocalAccountOOBE),
        so this is safe to apply unconditionally.
    #>
    Write-Phase 'Stage sensitive answer-file cleanup for first logon'
    $paths = @(
        'C:\Windows\System32\Sysprep\autounattend.xml'
        'C:\Windows\Panther\unattend.xml'
        'C:\Windows\Panther\unattend-original.xml'
    )
    $quotedPaths = ($paths | ForEach-Object { "`"$_`"" }) -join ' '
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'RemoveSensitiveAnswerFiles' 'REG_SZ' "cmd.exe /c del /f /q $quotedPaths"
    Write-Output '  Sensitive answer-file cleanup staged; will run at first logon.'
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

function Disable-WindowsUpdate {
    <#
    .SYNOPSIS
        Aggressively disables Windows Update.
    .DESCRIPTION
        Merges asl-win11-coremaker.ps1's aggressive suppression (RunOnce commands to
        stop/disable wuauserv on first boot, WU server URLs redirected to localhost,
        deleting WaaSMedicSVC/UsoSvc outright, OOBE DisableOnline) with winutil's
        additions (AUOptions, UseWUServer, the OOBE-scheduler workCompleted marker,
        DODownloadMode=0, and BITS disabled via Start=4).
        Where the two conflict, the coremaker form wins:
          - coremaker deletes WaaSMedicSVC/UsoSvc outright; winutil instead sets Start=4
            on WaaSMedicSvc/UsoSvc/wuauserv. Deleting is more aggressive and wins here,
            since this function targets non-serviceable Core builds.
          - coremaker points WUServer/WUStatusServer at bare "localhost"; winutil uses
            "http://localhost:8080". The bare form (coremaker's) is kept.
        Commented out by default for the serviceable build; force-enabled under -Core.
    #>
    Write-Phase 'Disable Windows Update'

    # RunOnce commands: stop and disable the WU service on first boot after OOBE
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'StopWUPostOOBE1' 'REG_SZ' 'net stop wuauserv'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'StopWUPostOOBE2' 'REG_SZ' 'sc stop wuauserv'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'StopWUPostOOBE3' 'REG_SZ' 'sc config wuauserv start= disabled'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'DisableWUPostOOBE1' 'REG_SZ' 'reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'DisableWUPostOOBE2' 'REG_SZ' 'reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f'

    # Group Policy: block Windows Update access and internet locations entirely
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DoNotConnectToWindowsUpdateInternetLocations' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DisableWindowsUpdateAccess' 'REG_DWORD' '1'
    # Redirect WU server URLs to localhost (winutil instead uses http://localhost:8080)
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUServer' 'REG_SZ' 'localhost'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUStatusServer' 'REG_SZ' 'localhost'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'UpdateServiceUrlAlternate' 'REG_SZ' 'localhost'
    # winutil addition: AUOptions=1 (notify before download), UseWUServer forces the (now-localhost) WSUS server
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'UseWUServer' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 'REG_DWORD' '1'
    # winutil addition: mark the OOBE WU scheduler task as already completed
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate' 'workCompleted' 'REG_DWORD' '1'
    Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate'
    # winutil addition: disable Delivery Optimization
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 'REG_DWORD' '0'
    # winutil addition: disable BITS (Background Intelligent Transfer Service)
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\BITS' 'Start' 'REG_DWORD' '4'

    # Disable online OOBE features and the WU service directly
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'DisableOnline' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv' 'Start' 'REG_DWORD' '4'
    # coremaker form: delete these services outright rather than just disabling them (winutil sets Start=4 instead)
    Remove-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC'
    Remove-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc'
}

function Disable-DiagnosticServices {
    <#
    .SYNOPSIS
        Disables diagnostic/telemetry-adjacent services beyond the core Disable-Telemetry tweaks.
    .DESCRIPTION
        Ported from tiny11-automated: DiagTrack (Connected User Experiences and
        Telemetry), WerSvc (Windows Error Reporting), PcaSvc (Program Compatibility
        Assistant), and SysMain (Superfetch - not useful on SSDs) all set to Start=4.
    #>
    Write-Phase 'Disable diagnostic services'
    foreach ($serviceName in @('DiagTrack', 'WerSvc', 'PcaSvc', 'SysMain')) {
        Set-RegistryValue "HKLM\zSYSTEM\ControlSet001\Services\$serviceName" 'Start' 'REG_DWORD' '4'
    }
}

function Disable-WindowsAI {
    <#
    .SYNOPSIS
        Disables Windows AI / Recall data analysis and related feedback notifications.
    .DESCRIPTION
        Ported from tiny11-automated: the WindowsAI policy keys (both HKLM and the
        default NTUSER hive, since Recall is a per-user feature), plus
        DoNotShowFeedbackNotifications and AllowDeviceNameInTelemetry.
    #>
    Write-Phase 'Disable Windows AI / Recall'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'TurnOffWindowsAI' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowDeviceNameInTelemetry' 'REG_DWORD' '0'
}

function Disable-WindowsDefender {
    <#
    .SYNOPSIS
        Disables Windows Defender services and hides its Settings pages.
    .DESCRIPTION
        Core-build-only: disables real-time protection, network inspection, and ATP
        services by setting Start=4, and hides the Windows Update / virus protection
        pages in Settings since both are non-functional on a non-serviceable image.
    #>
    Write-Phase 'Disable Windows Defender'
    foreach ($serviceName in @('WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'Sense')) {
        Set-RegistryValue "HKLM\zSYSTEM\ControlSet001\Services\$serviceName" 'Start' 'REG_DWORD' '4'
    }
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' 'REG_SZ' 'hide:virus;windowsupdate'
}

function Set-BootImageSetupCmdLine {
    <#
    .SYNOPSIS
        Points the boot image directly at setup.exe.
    .DESCRIPTION
        Core-build-only. Requires the boot.wim offline hives to already be loaded.
    #>
    Set-RegistryValue 'HKEY_LOCAL_MACHINE\zSYSTEM\Setup' 'CmdLine' 'REG_SZ' 'X:\sources\setup.exe'
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
    <#
    .DESCRIPTION
        Forwards every bound parameter from the original invocation via
        $script:EntryBoundParameters (set in asl-win11maker.ps1 right after the param
        block), so a self-elevated relaunch never silently drops a switch or value the
        user passed on the command line.
    #>
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

        foreach ($paramName in $script:EntryBoundParameters.Keys) {
            $paramValue = $script:EntryBoundParameters[$paramName]
            if ($paramValue -is [switch]) {
                if ($paramValue.IsPresent) {
                    $argumentList += "-$paramName"
                }
            } elseif ($paramValue -is [array]) {
                # e.g. -Profiles Standard,Entra: forward as separate values, not one
                # comma/space-joined string that would fail the parameter's ValidateSet.
                $argumentList += "-$paramName"
                $argumentList += @($paramValue | ForEach-Object { [string]$_ })
            } else {
                $argumentList += @("-$paramName", [string]$paramValue)
            }
        }

        Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Verb RunAs | Out-Null
        Wait-ForAcknowledgement -Prompt 'Press Enter to close this non-elevated window'
        exit
    }
}

function Show-CoreBuildWarning {
    <#
    .SYNOPSIS
        Prints the non-serviceable-image warning for -Core builds. No-op otherwise.
    #>
    if (-not $Core) {
        return
    }
    Write-Phase 'Core build selected'
    Write-Output '  This generates a significantly reduced Windows 11 image. It is not suitable for'
    Write-Output '  regular use due to its lack of serviceability - you cannot add languages, updates,'
    Write-Output '  or features post-creation. This is a rapid testing/development image, not a full'
    Write-Output '  Windows 11 substitute.'
}

function Confirm-DotNet35Enablement {
    <#
    .SYNOPSIS
        Decides whether to enable .NET Framework 3.5 for a -Core build.
    .DESCRIPTION
        Returns $true/$false. If -EnableDotNet35 was explicitly bound on the command
        line, honors it without prompting. Otherwise prompts interactively, since this
        cannot be changed after the image is built.
    #>
    if ($script:EntryBoundParameters -and $script:EntryBoundParameters.ContainsKey('EnableDotNet35')) {
        return [bool]$EnableDotNet35
    }
    $response = Read-Host 'Enable .NET Framework 3.5? This cannot be done after the image is created (y/n)'
    return $response -eq 'y'
}

function Invoke-Tiny11EmergencyCleanup {
    <#
    .SYNOPSIS
        Best-effort recovery from a mid-pipeline failure.
    .DESCRIPTION
        Discards any images left mounted (install.wim or boot.wim) and unloads offline
        registry hives so a failed run doesn't block the next one. Also removes staged
        driver folders. Called from the top-level catch block in asl-win11maker.ps1 — every
        step here is best-effort and swallows its own errors since we're already in a
        failure path.
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

    if ($script:sourceIsoMountedPath) {
        try {
            Dismount-DiskImage -ImagePath $script:sourceIsoMountedPath -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }
    if ($script:BuildScratchRoot) {
        $driversRoot = Join-Path $script:BuildScratchRoot 'drivers'
        if (Test-Path $driversRoot) {
            Remove-Item -Path $driversRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log 'Emergency cleanup complete.' 'WARN'
}

function Confirm-AutounattendXml {
    <#
    .SYNOPSIS
        Ensures the autounattend.xml template is present, downloading it if not.
    .DESCRIPTION
        Lives under $script:BuildScratchRoot rather than $PSScriptRoot so a downloaded
        template never sits alongside the repo's own script files. Sets
        $script:autounattendTemplatePath so Initialize-PreparedAnswerFile and
        Invoke-Tiny11Cleanup both target the same location.
    #>
    New-Item -ItemType Directory -Force -Path $script:BuildScratchRoot | Out-Null
    $script:autounattendTemplatePath = Join-Path $script:BuildScratchRoot 'autounattend.xml'
    if (-not (Test-Path -LiteralPath $script:autounattendTemplatePath)) {
        Invoke-RestMethod "https://raw.githubusercontent.com/ntdevlabs/tiny11builder/refs/heads/main/autounattend.xml" -OutFile $script:autounattendTemplatePath
    }
}

function Set-SleepPrevention {
    <#
    .SYNOPSIS
        Tells Windows to stay awake for the duration of the build.
    .DESCRIPTION
        The DISM/oscdimg phases run unattended for a long time with no user input, which
        is exactly when Windows' idle timer suspends the machine. A suspended process is
        frozen (not failed) until the next wake, which silently turns a 20-minute build
        into an overnight one. SetThreadExecutionState only affects this process's calling
        thread and is automatically released on exit, so a crash doesn't leave the system
        pinned awake. Call Clear-SleepPrevention before any point where waiting for user
        input is fine (e.g. the final "press Enter" prompt) so the machine can still sleep
        there.
    #>
    if (-not ('Tiny11.PowerState' -as [type])) {
        Add-Type -Namespace Tiny11 -Name PowerState -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
    }
    # ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x1) - keep the system awake; display
    # sleep is fine. Written as decimal (2147483649): PowerShell reinterprets 0x80000000 as a
    # negative Int32 (sign bit set) rather than promoting to Int64, and casting that negative
    # value to [uint32] throws - decimal literals over Int32.MaxValue don't have that problem.
    [Tiny11.PowerState]::SetThreadExecutionState([uint32]2147483649) | Out-Null
}

function Clear-SleepPrevention {
    if ('Tiny11.PowerState' -as [type]) {
        # ES_CONTINUOUS (0x80000000 / 2147483648) alone - release the system-awake request.
        [Tiny11.PowerState]::SetThreadExecutionState([uint32]2147483648) | Out-Null
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
    $script:sourceCacheRoot = "$script:BuildScratchRoot\sourcecache"

    # Remove any debris left behind by a prior interrupted run (eg a partial
    # sources\install2.wim from an export that never finished) before recreating -
    # otherwise DISM's /Export-Image below can find a stale, corrupt file already sitting
    # at its destination path and fail against it instead of writing a fresh one.
    if (Test-Path -LiteralPath $script:tiny11Root) {
        Remove-Item -Path $script:tiny11Root -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path "$script:tiny11Root\sources" | Out-Null
}

function Resolve-SourceDriveLetter {
    <#
    .SYNOPSIS
        Resolves the Windows 11 source to a mounted drive letter.
    .DESCRIPTION
        -ISO may be a drive letter of an already-mounted ISO/DVD (eg 'E'), or a path to a
        Windows 11 .iso file, which this function mounts itself via Mount-DiskImage
        (mirroring the existing -VirtioIso / Resolve-VirtioDriverSource pattern). Sets
        $script:sourceIsoMountedPath whenever this function did the mounting, so
        Invoke-Tiny11Cleanup / Invoke-Tiny11EmergencyCleanup dismount it by path instead of
        just ejecting whatever happens to be at that drive letter.
    #>
    $promptedSource = $ISO
    do {
        if (-not $promptedSource) {
            $promptedSource = Read-Host "Please enter the drive letter for the Windows 11 image, or a path to a .iso file"
        }

        if ($promptedSource -match '^[c-zC-Z]:?$') {
            $script:DriveLetter = $promptedSource.TrimEnd(':') + ":"
            Write-Output "Drive letter set to $script:DriveLetter"
        } elseif ($promptedSource -match '\.iso$' -and (Test-Path $promptedSource -PathType Leaf)) {
            Write-Output "Mounting source ISO: $promptedSource"
            $mountResult = Mount-DiskImage -ImagePath $promptedSource -PassThru
            $mountedDriveLetter = ($mountResult | Get-Volume).DriveLetter
            $script:DriveLetter = "$($mountedDriveLetter):"
            $script:sourceIsoMountedPath = $promptedSource
            Write-Output "  Mounted at $script:DriveLetter"
        } else {
            Write-Output "Invalid drive letter or ISO path. Please enter a letter between C and Z, or a path to a .iso file."
            $script:DriveLetter = $null
        }

        $promptedSource = $null
    } while ($script:DriveLetter -notmatch '^[c-zC-Z]:$')
}

function Resolve-EditionImageIndex {
    <#
    .SYNOPSIS
        Finds the image index matching -Edition (eg 'Professional', 'Home', 'Education').
    .DESCRIPTION
        Matches case-insensitively as a substring against either the image's friendly name
        (eg 'Windows 11 Pro') or its DISM Edition ID (eg 'Professional', 'Core') -
        whichever the caller's input happens to match. This covers both how Windows 11
        editions are normally referred to ('Pro', 'Home') and DISM's internal edition
        naming, which doesn't always match ('Home' ships under Edition ID 'Core').
        Used for both install.wim (-Edition, via Resolve-InstallImageIndex) and
        install.esd (-Edition, via Confirm-InstallWimSource) since both are plain
        multi-edition WIM-format images as far as DISM is concerned.
    #>
    param (
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][string]$Edition
    )

    $images = Get-WindowsImage -ImagePath $ImagePath
    $matchedImages = foreach ($image in $images) {
        $wimInfo = Invoke-Dism -ArgumentList @('/English', '/Get-WimInfo', "/wimFile:$ImagePath", "/index:$($image.ImageIndex)")
        $editionId = Get-DismInfoField -Lines ($wimInfo -split '\r?\n') -FieldName 'Edition ID'
        if ($image.ImageName -like "*$Edition*" -or $editionId -like "*$Edition*") {
            [PSCustomObject]@{ Index = $image.ImageIndex; Name = $image.ImageName; EditionId = $editionId }
        }
    }
    $matchedImages = @($matchedImages)

    if ($matchedImages.Count -eq 0) {
        throw "No image in $ImagePath matches -Edition '$Edition'. Available editions: $(($images | ForEach-Object { $_.ImageName }) -join ', ')"
    }
    if ($matchedImages.Count -gt 1) {
        throw "-Edition '$Edition' matches multiple images in ${ImagePath}: $(($matchedImages | ForEach-Object { "$($_.Index): $($_.Name)" }) -join '; '). Be more specific."
    }

    Write-Output "  Matched -Edition '$Edition' to index $($matchedImages[0].Index) ($($matchedImages[0].Name))."
    return $matchedImages[0].Index
}

function Confirm-InstallWimSource {
    if ((Test-Path "$script:DriveLetter\sources\boot.wim") -eq $false -or (Test-Path "$script:DriveLetter\sources\install.wim") -eq $false) {
        if ((Test-Path "$script:DriveLetter\sources\install.esd") -eq $true) {
            Write-Output "Found install.esd, converting to install.wim..."
            Get-WindowsImage -ImagePath $script:DriveLetter\sources\install.esd
            if ($Edition) {
                $esdIndex = Resolve-EditionImageIndex -ImagePath "$script:DriveLetter\sources\install.esd" -Edition $Edition
            } elseif ($ESDINDEX) {
                $esdIndex = $ESDINDEX
                Write-Output "  Using ESD image index $esdIndex (from -ESDINDEX)."
            } else {
                $esdIndex = Read-Host "Please enter the image index"
            }
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
    <#
    .DESCRIPTION
        install.esd is optional — only present when the source media ships an ESD
        instead of a WIM (see Confirm-InstallWimSource) — so its cleanup below must use
        -ErrorAction SilentlyContinue rather than the old `> $null 2>&1` redirection
        trick. Output redirection only affects where a written error record goes; it
        does not stop $ErrorActionPreference = 'Stop' (set globally in
        asl-win11maker.ps1) from turning a missing-file error into a terminating
        exception before it ever reaches the redirect.
    #>
    Write-Phase 'Copy source image files'
    Copy-Item -Path "$script:DriveLetter\*" -Destination $script:tiny11Root -Recurse -Force | Out-Null
    Set-ItemProperty -Path "$script:tiny11Root\sources\install.esd" -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    Remove-Item "$script:tiny11Root\sources\install.esd" -ErrorAction SilentlyContinue
    Write-Output '  Source image copy complete.'
}

function Test-SourceCachePopulated {
    <#
    .SYNOPSIS
        Checks whether $script:sourceCacheRoot holds a usable pristine install.wim/boot.wim.
    #>
    (Test-Path "$script:sourceCacheRoot\sources\install.wim") -and (Test-Path "$script:sourceCacheRoot\sources\boot.wim")
}

function Initialize-SourceImage {
    <#
    .SYNOPSIS
        Populates $script:tiny11Root\sources with a pristine install.wim/boot.wim, from
        the -UseSourceCache cache when one is valid, otherwise from the mounted source ISO.
    .DESCRIPTION
        Replaces the old unconditional Resolve-SourceDriveLetter / Confirm-InstallWimSource
        / Copy-SourceImageFiles sequence. Those three steps are the ones that require the
        Windows 11 ISO to actually be mounted, and (when the source ships install.esd
        instead of install.wim) the slow Export-WindowsImage conversion — exactly the cost
        -UseSourceCache exists to skip on reruns.

        The cache is only ever read from or replaced wholesale here; nothing downstream
        mutates $script:sourceCacheRoot directly, because Complete-InstallImage renames and
        deletes files in $script:tiny11Root in place. Keeping the cache a separate copy
        means every rerun starts from the same pristine image regardless of what a prior
        run's -Core/-BypassMode/removal-list choices did to its own working copy.

        Without -UseSourceCache this behaves exactly as before: always reads from the
        mounted ISO, and never touches the cache directory.
    #>
    $cacheValid = $UseSourceCache -and -not $RefreshSourceCache -and (Test-SourceCachePopulated)

    if ($cacheValid) {
        Write-Phase 'Restore source image from cache'
        Write-Output "  Reusing cached source files from $script:sourceCacheRoot (no ISO required)."
        Copy-Item -Path "$script:sourceCacheRoot\*" -Destination $script:tiny11Root -Recurse -Force
        Write-Output '  Source image restore complete.'
        return
    }

    Resolve-SourceDriveLetter
    Confirm-InstallWimSource
    Copy-SourceImageFiles

    if ($UseSourceCache) {
        Write-Phase 'Populate source image cache'
        if (Test-Path $script:sourceCacheRoot) {
            Remove-Item -Path $script:sourceCacheRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $script:sourceCacheRoot | Out-Null
        Copy-Item -Path "$script:tiny11Root\*" -Destination $script:sourceCacheRoot -Recurse -Force
        Write-Output "  Cached pristine source files to $script:sourceCacheRoot for future -UseSourceCache reruns."
    }
}

function Resolve-InstallImageIndex {
    <#
    .SYNOPSIS
        Chooses the install image index to modify.
    .DESCRIPTION
        Honors -Edition first (name-based lookup via Resolve-EditionImageIndex), then
        -INDEX when it names a valid index in install.wim; otherwise (or if the requested
        index doesn't exist) falls back to the original interactive prompt loop.
    #>
    $imagesIndex = (Get-WindowsImage -ImagePath $script:installWimPath).ImageIndex

    if ($Edition) {
        Write-Phase 'Select image index'
        $script:index = Resolve-EditionImageIndex -ImagePath $script:installWimPath -Edition $Edition
        Write-Output "  Using image index $script:index (from -Edition '$Edition')."
        return
    }

    if ($INDEX -and ($imagesIndex -contains $INDEX)) {
        $script:index = $INDEX
        Write-Phase 'Select image index'
        Write-Output "  Using image index $script:index (from -INDEX)."
        return
    }

    if ($INDEX) {
        Write-Log "Requested -INDEX $INDEX is not present in $script:installWimPath; falling back to interactive selection." 'WARN'
    }

    Start-Sleep -Seconds 2
    Clear-Host
    Write-Phase 'Select image index'
    while ($imagesIndex -notcontains $script:index) {
        Get-WindowsImage -ImagePath $script:installWimPath
        $script:index = Read-Host "Please enter the image index"
    }
}

function Mount-InstallImage {
    <#
    .SYNOPSIS
        Mounts install.wim at the selected index for editing.
    .DESCRIPTION
        Mounts via raw `dism.exe /Mount-Image`, not the `Mount-WindowsImage` PowerShell
        cmdlet - paired with Complete-InstallImage's `dism.exe /Unmount-Image /Commit`. See
        Complete-InstallImage's description for why: the PowerShell mount/dismount-save cmdlet
        pair was isolated as the cause of a hard "Setup has failed to validate the product key"
        failure, independent of any actual edit made while mounted.
    #>
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
    dism.exe /Mount-Image /ImageFile:$script:installWimPath /Index:$script:index /MountDir:$script:mountDir
    if ($LASTEXITCODE -ne 0) {
        throw "DISM /Mount-Image of install.wim failed (exit code $LASTEXITCODE) - see C:\Windows\Logs\DISM\dism.log."
    }
}

function Show-ImageMetadata {
    Write-Phase 'Inspect selected image metadata'
    $imageIntl = Invoke-Dism -ArgumentList @('/English', '/Get-Intl', "/Image:$script:mountDir")
    $languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

    if ($languageLine) {
        $script:languageCode = $Matches[1]
        Write-Output "Default system UI language code: $script:languageCode"
    } else {
        $script:languageCode = ''
        Write-Output "Default system UI language code not found."
    }

    $imageInfo = Invoke-Dism -ArgumentList @('/English', '/Get-WimInfo', "/wimFile:$script:installWimPath", "/index:$script:index")
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

    # /Get-WimInfo never exposes an "Edition ID" field (despite the similarly-named "Edition ID"
    # DISM uses elsewhere, e.g. ei.cfg) - /Get-CurrentEdition against the now-mounted image is
    # the actual source for it, returning the DISM edition ID token (e.g. "Professional", "Core"
    # for Home, "Education") in a single "Current Edition : <id>" line.
    $currentEditionOutput = Invoke-Dism -ArgumentList @('/English', "/Image:$script:mountDir", '/Get-CurrentEdition')
    $editionLine = $currentEditionOutput | Where-Object { $_ -match '^\s*Current Edition\s*:\s*(.+?)\s*$' }

    if ($editionLine) {
        $script:editionId = $Matches[1]
    } else {
        $script:editionId = ''
    }

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

function Initialize-PreparedAnswerFile {
    <#
    .SYNOPSIS
        Prepares autounattend.xml once, so every consumer sees the same content.
    .DESCRIPTION
        Injects the selected image index, product-key handling, the mounted image's own locale
        (from $script:languageCode, so OOBE doesn't ask for language/region/keyboard), and (when
        -LocalAccountName is given) a local account, caching the result in
        $script:preparedAutounattendXml. Enable-LocalAccountOOBE (Sysprep copy),
        Invoke-HardwareBypassStrategy's Unattend mode, and New-Tiny11Iso (ISO root copy) all
        read this same cached value instead of each recomputing their own copy, which
        previously let the Sysprep and ISO-root copies drift apart.

        Product-key precedence: an explicit -ProductKey always wins. Otherwise, falls back to
        the detected edition's Generic Volume License Key (Get-GenericVolumeLicenseKey) when one
        exists, so Setup gets a fully silent, WillShowUI=Never product-key pass instead of
        ConvertTo-Tiny11AnswerFile's placeholder-key/WillShowUI=Always screen. The GVLK doesn't
        activate Windows (same "not activated" end state either way) - it only lets Setup's
        validation pass silently. Editions with no published GVLK (Home/"Core" chief among them
        - never sold as a volume-licensed SKU) or an undetected edition fall through to the
        placeholder/Always screen unchanged.
    #>
    Write-Phase 'Prepare autounattend.xml'
    $script:preparedAutounattendXml = Get-Content -Path $script:autounattendTemplatePath -Raw

    $effectiveProductKey = $ProductKey
    if (-not $effectiveProductKey -and $script:editionId) {
        $genericKey = Get-GenericVolumeLicenseKey -EditionId $script:editionId
        if ($genericKey) {
            $effectiveProductKey = $genericKey
            Write-Output "  No -ProductKey given; using the Generic Volume License Key for edition '$script:editionId' so Setup passes silently (Windows will still show as not activated - see CLAUDE.md)."
        }
    }

    try {
        $script:preparedAutounattendXml = ConvertTo-Tiny11AnswerFile -XmlContent $script:preparedAutounattendXml -ImageIndex $script:index -ProductKey $effectiveProductKey
        Write-Output "  Injected image index $script:index into autounattend.xml."
    } catch {
        Write-Log "Could not inject image index into autounattend.xml: $_" 'WARN'
    }

    if ($script:languageCode) {
        try {
            $script:preparedAutounattendXml = Add-AnswerFileLocale -XmlContent $script:preparedAutounattendXml -LanguageCode $script:languageCode
            Write-Output "  Embedded locale '$script:languageCode' into autounattend.xml."
        } catch {
            Write-Log "Could not embed locale into autounattend.xml: $_" 'WARN'
        }
    }

    if ($LocalAccountName) {
        try {
            $script:preparedAutounattendXml = Add-AnswerFileLocalAccount -XmlContent $script:preparedAutounattendXml -AccountName $LocalAccountName
            Write-Output "  Embedded local account '$LocalAccountName' into autounattend.xml (password matches the account name)."
        } catch {
            Write-Log "Could not embed local account into autounattend.xml: $_" 'WARN'
        }
    }
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
    <#
    .SYNOPSIS
        Cleans up, commits, and single-index-exports the mounted install.wim.
    .DESCRIPTION
        Unmounts via raw `dism.exe /Unmount-Image /Commit`, not the `Dismount-WindowsImage
        -Save` PowerShell cmdlet. Isolation testing (bisecting driver injection, ResetBase,
        appx removal, registry tweaks, and finally a completely unedited mount+save, each
        individually, against a real install) traced a hard "Setup has failed to validate the
        product key" failure specifically to `Dismount-WindowsImage -Save` corrupting
        install.wim's edition/licensing metadata on commit - reproducible even with zero
        content changes, and independent of single- vs multi-edition source WIMs. The same
        no-op mount+save on boot.wim (Update-BootImage) was proven harmless in the same testing,
        because Setup never consults boot.wim for edition/key matching - only install.wim.
        Swapping to `dism.exe /Mount-Image` + `/Unmount-Image /Commit` (still used for
        Mount-InstallImage and here) resolved it. Keep both of install.wim's mount/unmount
        calls on the raw dism.exe path; don't revert to the PowerShell cmdlets here even though
        they're more idiomatic.
    #>
    Write-Phase 'Finalize install image'
    Write-Output '  Cleaning up component store...'
    dism.exe /Image:$script:mountDir /Cleanup-Image /StartComponentCleanup /ResetBase
    Write-Output '  Component cleanup complete.'
    Write-Output '  Saving and unmounting install image...'
    dism.exe /Unmount-Image /MountDir:$script:mountDir /Commit
    if ($LASTEXITCODE -ne 0) {
        throw "DISM /Unmount-Image /Commit of install.wim failed (exit code $LASTEXITCODE) - see C:\Windows\Logs\DISM\dism.log."
    }

    Write-Output "  Exporting optimized install image (Compress:$($CompressionMode.ToLower()))..."
    $exportDestination = "$script:tiny11Root\sources\install2.wim"
    Remove-Item -Path $exportDestination -Force -ErrorAction SilentlyContinue
    Dism.exe /Export-Image /SourceImageFile:"$script:installWimPath" /SourceIndex:$script:index /DestinationImageFile:"$exportDestination" /Compress:$($CompressionMode.ToLower())
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exportDestination) -or (Get-Item -LiteralPath $exportDestination).Length -lt 1MB) {
        throw "DISM /Export-Image of install.wim failed (exit code $LASTEXITCODE) or produced a suspiciously small file - see C:\Windows\Logs\DISM\dism.log. Leaving the original install.wim in place."
    }
    Remove-Item -Path $script:installWimPath -Force | Out-Null
    Rename-Item -Path $exportDestination -NewName "install.wim" | Out-Null
    Write-Output '  Install image finalized.'

    if ($Core) {
        Export-CoreInstallEsd
    }
}

function Export-CoreInstallEsd {
    <#
    .SYNOPSIS
        Exports the finalized install.wim to an install.esd, using -CompressionMode.
    .DESCRIPTION
        Core-build-only. Matches asl-win11-coremaker.ps1's final export step; produces a
        smaller install.esd in place of install.wim for the non-serviceable image.
    #>
    Write-Phase 'Export core install image to ESD'
    Write-Output "  Exporting install.esd (Compress:$($CompressionMode.ToLower()))..."
    $exportDestination = "$script:tiny11Root\sources\install.esd"
    Remove-Item -Path $exportDestination -Force -ErrorAction SilentlyContinue
    Dism.exe /Export-Image /SourceImageFile:"$script:installWimPath" /SourceIndex:$script:index /DestinationImageFile:"$exportDestination" /Compress:$($CompressionMode.ToLower())
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exportDestination) -or (Get-Item -LiteralPath $exportDestination).Length -lt 1MB) {
        throw "DISM /Export-Image of install.esd failed (exit code $LASTEXITCODE) or produced a suspiciously small file - see C:\Windows\Logs\DISM\dism.log. Leaving the original install.wim in place."
    }
    Remove-Item -Path $script:installWimPath -Force
    Write-Output '  install.esd exported; install.wim removed.'
}

function Update-BootImage {
    <#
    .SYNOPSIS
        Mounts boot.wim index 2 and applies every setup-time tweak in one pass.
    .DESCRIPTION
        Handles the hardware-bypass registry tweaks (per -BypassMode), for -Core builds the
        Setup\CmdLine key that boots straight into setup.exe, and - mirroring winutil's
        abcbc23 fix ("fix: inject Setup storage into boot.wim") - re-injects the same
        storage-class driver packages already staged into $WinpeDriver$ (see
        Add-WinPEStorageDrivers, called earlier in the pipeline) directly into boot.wim's
        own driver store via DISM. $WinpeDriver$ staging alone is Setup's documented
        auto-load mechanism (KB2686316) and remains the primary path; this is a second,
        belt-and-suspenders delivery of the exact same already-storage-filtered packages
        (Test-StorageDriverInf), not a re-scan of the full driver source - so it can't bloat
        boot.wim with GPU/audio/NIC drivers the way injecting a whole driver source used to.
    #>
    Write-Phase 'Update boot image'
    Write-Output '  Continuing with boot.wim.'
    Start-Sleep -Seconds 2
    Clear-Host

    Write-Output '  Mounting boot image...'
    & takeown "/F" $script:bootWimPath | Out-Null
    & icacls $script:bootWimPath "/grant" "$($script:adminGroupName):(F)"
    Set-ItemProperty -Path $script:bootWimPath -Name IsReadOnly -Value $false
    Mount-WindowsImage -ImagePath $script:bootWimPath -Index 2 -Path $script:mountDir

    $winpeDriverDir = Join-Path $script:tiny11Root '$WinpeDriver$'
    if (Test-Path -LiteralPath $winpeDriverDir) {
        Add-DriversToImage -MountPath $script:mountDir -DriverPath $winpeDriverDir -Label 'boot.wim (storage)'
    }

    Write-Output '  Loading boot image registry hives...'
    reg load HKLM\zCOMPONENTS $script:mountDir\Windows\System32\config\COMPONENTS
    reg load HKLM\zDEFAULT $script:mountDir\Windows\System32\config\default
    reg load HKLM\zNTUSER $script:mountDir\Users\Default\ntuser.dat
    reg load HKLM\zSOFTWARE $script:mountDir\Windows\System32\config\SOFTWARE
    reg load HKLM\zSYSTEM $script:mountDir\Windows\System32\config\SYSTEM

    if ($BypassMode -in @('Hive', 'Both')) {
        Set-BypassHardwareChecks
    } else {
        Write-Output "  Skipping boot.wim hardware bypass (BypassMode = $BypassMode)."
    }

    if ($Core) {
        Set-BootImageSetupCmdLine
    }

    Write-Output '  Boot image tweaks complete.'
    Dismount-OfflineRegistryHives

    Write-Output '  Saving and unmounting boot image...'
    Dismount-WindowsImage -Path $script:mountDir -Save
    Clear-Host
}

function Get-Tiny11IsoNameTag {
    <#
    .SYNOPSIS
        Builds a filesystem-safe "_"-joined tag string summarizing this run's key
        build choices, for embedding in the output ISO's filename.
    .DESCRIPTION
        Surfaces the edition plus every build/driver/bypass/account option that makes this
        ISO different from a stock build, so multiple output ISOs sitting in the same
        output\ folder can be told apart without opening buildinfo JSON or re-running with
        -Verbose. Reads $script:editionId (set by Show-ImageMetadata) and the entry script's
        bound parameters directly by name, same as every other function in this file.
    #>
    $tags = [System.Collections.Generic.List[string]]::new()

    if ($ProfileName) {
        $tags.Add(($ProfileName -replace '[^A-Za-z0-9]', ''))
    }
    if ($script:editionId) {
        $tags.Add(($script:editionId -replace '[^A-Za-z0-9]', ''))
    }
    if ($Core) { $tags.Add('Core') }
    if ($BypassMode -and $BypassMode -ne 'None') { $tags.Add("Bypass$BypassMode") }
    if ($InjectVirtioDrivers) { $tags.Add('Virtio') }
    if ($InjectSystemDrivers) { $tags.Add('SysDrivers') }
    if ($DriverPath) { $tags.Add('CustomDrivers') }
    if ($LocalAccountName) { $tags.Add('LocalAcct') }
    if ($KeepCorporateApps) { $tags.Add('Corp') }
    if ($CompressionMode -and $CompressionMode -ne 'Fast') { $tags.Add("Compress$CompressionMode") }

    return ($tags -join '_')
}

function New-Tiny11Iso {
    Write-Phase 'Build ISO image'
    Write-Output '  Writing unattended file for OOBE local account bypass...'
    Set-Content -Path "$script:tiny11Root\autounattend.xml" -Value $script:preparedAutounattendXml -Encoding UTF8 -Force

    Set-Tiny11EditionConfig -ContentRoot $script:tiny11Root -EditionId $script:editionId

    Write-Output '  Creating ISO image...'
    $outputDir = Join-Path $PSScriptRoot 'output'
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    $nameTag = Get-Tiny11IsoNameTag
    $script:isoPath = if ($nameTag) {
        "$outputDir\asl-win11_${nameTag}_$(Get-Date -f yyyyMMdd).iso"
    } else {
        "$outputDir\asl-win11_$(Get-Date -f yyyyMMdd).iso"
    }
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
    Clear-SleepPrevention  # the build is done - fine for the system to sleep while this prompt waits
    Read-Host "Press Enter to continue"
    Write-Output "Performing Cleanup..."
    Remove-Item -Path $script:tiny11Root -Recurse -Force | Out-Null
    Remove-Item -Path $script:mountDir -Recurse -Force | Out-Null

    $driversRoot = Join-Path $script:BuildScratchRoot 'drivers'
    if (Test-Path $driversRoot) {
        Remove-Item -Path $driversRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($script:sourceIsoMountedPath) {
        Write-Output "Dismounting source ISO..."
        try {
            Dismount-DiskImage -ImagePath $script:sourceIsoMountedPath -ErrorAction SilentlyContinue | Out-Null
        } catch {
            Write-Output "Could not dismount source ISO: $_"
        }
        Write-Output "Source ISO dismounted"
    } elseif ($script:DriveLetter) {
        Write-Output "Ejecting Iso drive"
        Get-Volume -DriveLetter $script:DriveLetter[0] | Get-DiskImage | Dismount-DiskImage
        Write-Output "Iso drive ejected"
    }
    Write-Output "Removing autounattend.xml..."
    Remove-Item -Path $script:autounattendTemplatePath -Force -ErrorAction SilentlyContinue

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
    if (Test-Path -Path $script:autounattendTemplatePath) {
        Write-Output "autounattend.xml still exists. Attempting to remove it again..."
        Remove-Item -Path $script:autounattendTemplatePath -Force -ErrorAction SilentlyContinue
        if (Test-Path -Path $script:autounattendTemplatePath) {
            Write-Output "Failed to remove autounattend.xml."
        } else {
            Write-Output "autounattend.xml removed successfully."
        }
    } else {
        Write-Output "autounattend.xml does not exist. No action needed."
    }
}
