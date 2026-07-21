# Script Comparison: tiny11maker vs Invoke-WinUtilISOScript

Comparison of `Invoke-WinUtilISOScript.ps1` (winutil submodule) against `tiny11maker.ps1` + `tiny11maker.functions.ps1` to identify gaps in each.

---

## What winutil has that tiny11maker LACKS

### 1. Driver Injection (`-InjectCurrentSystemDrivers`)
- Exports all drivers from the running system via `Export-WindowsDriver -Online`
- Injects into install.wim via DISM `/Add-Driver /Recurse`
- Also injects into boot.wim index 2 (so setup PE has the same drivers)
- Temp directory created/cleaned up automatically
- **Verdict: Significant missing feature** — valuable for hardware compatibility

### 2. autounattend.xml XML Manipulation
- `ConvertTo-WinUtilISOAnswerFile`: namespace-aware XML processing that injects the `IMAGE/INDEX` metadata into the answer file so Windows Setup installs the correct edition
- Removes empty/invalid product keys from the XML before embedding
- `Get-WinUtilISOScriptChildElement`: helper for namespace-safe element creation
- **Verdict: tiny11maker just copies autounattend.xml as-is; it does not inject the image index into the XML**

### 3. Setup Script Pre-staging from autounattend.xml
- Parses `<sg:File>` extension nodes in autounattend.xml
- Writes each referenced script to its Windows path under the mount dir with correct encoding:
  - `.ps1`, `.xml` → UTF-8
  - `.reg`, `.vbs`, `.js` → UTF-16 LE with BOM
- Ensures scripts survive Windows Setup stripping unrecognized XML namespaces
- **Verdict: Currently absent from tiny11maker**

### 4. Edition Enforcement (`-InstallEditionId`)
- `Write-WinUtilISOEditionConfig`: writes `sources\ei.cfg` to pin the edition
- Deletes `sources\PID.txt` to prevent setup from forcing a stale firmware product key
- **Verdict: tiny11maker doesn't write ei.cfg or remove PID.txt**

### 5. ISO `support\` Folder Removal
- Removes the `support\` folder from the ISO contents directory
- Reduces final ISO size
- **Verdict: Not done in tiny11maker**

### 6. Additional Scheduled Task Removals (6 more than tiny11maker's 5)
winutil removes these task paths that tiny11maker skips:
- `Microsoft\Windows\InstallService` (recursive)
- `Microsoft\Windows\UpdateOrchestrator` (recursive)
- `Microsoft\Windows\UpdateAssistant` (recursive)
- `Microsoft\Windows\WaaSMedic` (recursive)
- `Microsoft\Windows\WindowsUpdate` (recursive)
- `Microsoft\WindowsUpdate` (recursive)
- **Verdict: More thorough WU task cleanup**

### 7. Additional Windows Update Registry Tweaks
winutil applies these that tiny11maker omits:

| Registry Path | Value | Note |
|---|---|---|
| `...WindowsUpdate\AU\AUOptions` | 1 | Disable auto-update options |
| `...WindowsUpdate\AU\UseWUServer` | 1 | Force WSUS server policy |
| `...WindowsUpdate\DisableWindowsUpdateAccess` | 1 | Block WU access policy |
| `WUServer` | `http://localhost:8080` | More specific localhost URL |
| `WUStatusServer` | `http://localhost:8080` | Same |
| `...UScheduler_Oobe\WindowsUpdate\workCompleted` | 1 | Block WU OOBE install |
| `...DeliveryOptimization\Config\DODownloadMode` | 0 | Disable delivery optimization |
| `Services\BITS\Start` | 4 (disabled) | Background Intelligent Transfer |
| `Services\UsoSvc\Start` | 4 (disabled) | Update Orchestrator Service |
| `Services\WaaSMedicSvc\Start` | 4 (disabled) | WaaS Medic Service |

tiny11maker instead **deletes** the WaaSMedicSVC and UsoSvc keys entirely (more aggressive) and sets `DisableOnline = 1` on OOBE (which winutil doesn't do).

### 8. Pluggable Logger (`-Log` scriptblock parameter)
- winutil accepts a custom logging function
- Enables integration into larger workflows (e.g., GUI progress display in WinUtil itself)
- **Verdict: tiny11maker always writes to transcript/stdout**

---

## What tiny11maker HAS that winutil LACKS

### 1. Full End-to-End ISO Build Workflow
winutil is a *processing step only* — it receives an already-mounted image path. tiny11maker owns the full pipeline:
- ESD → WIM conversion
- Interactive image index selection
- `Copy-SourceImageFiles` (ISO copy to scratch)
- `Mount-InstallImage`, `Show-ImageMetadata`
- `Complete-InstallImage` (DISM cleanup + recovery export)
- `Set-BootImageBypassTweaks` (boot.wim hardware bypass)
- `New-Tiny11Iso` (oscdimg ISO creation)
- `Invoke-Tiny11Cleanup` (eject, delete temps, retry logic)
- `Confirm-AutounattendXml` (download from GitHub if missing)

### 2. Edge Removal (File + Registry)
- `Remove-Edge`: removes Edge browser dirs, EdgeUpdate, EdgeCore
- Optional WebView2 removal (`-SkipWebView` switch)
- Cleans up Edge/EdgeUpdate uninstall registry entries
- **Not implemented in winutil**

### 3. OneDrive Setup Removal
- `Remove-OneDriveSetup`: removes `Windows\System32\OneDriveSetup.exe`
- Uses `takeown`/`icacls` for permission elevation
- **Not implemented in winutil**

### 4. Hardware Bypass in Boot.wim (`Set-BootImageBypassTweaks`)
- Mounts boot.wim index 2, loads hives, applies LabConfig bypass keys, saves
- winutil's driver injection touches boot.wim, but does **not** apply hardware bypass registry tweaks to it
- **Verdict: tiny11maker applies bypass to both install.wim and the setup PE**

### 5. Much Larger App Removal List (53 vs 19 packages)
tiny11maker removes 34+ additional package prefixes beyond winutil's 19, including:
- All Xbox app family (TCUI, App, GameOverlay, GamingOverlay, IdentityProvider, SpeechToText)
- Cortana (`Microsoft.549981C3F5F10`)
- Dolby OEM apps, Intel Management Status
- Mixed Reality Portal
- SkypeApp, People, Phone Link, WindowsCamera, WindowsAlarms, WindowsMaps
- Mail/Calendar (`windowscommunicationsapps`), OneNote UWP, OfficePushNotification
- Microsoft Family Safety, 3D Viewer, Wallet, Sticky Notes, ZuneVideo

winutil has `Microsoft.Paint` which tiny11maker currently has commented out.

### 6. DISM Image Cleanup Step
- `Complete-InstallImage` runs `/Cleanup-Image /StartComponentCleanup /ResetBase` before export
- Significantly reduces final image size
- **Not done in winutil (caller's responsibility)**

### 7. OOBE-Specific WU Suppression
- Sets `HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE\DisableOnline = 1`
- Uses RunOnce commands to stop/disable WU service on first boot post-OOBE
- Fully deletes WaaSMedicSVC and UsoSvc service keys (vs winutil setting Start=4)
- `DoNotConnectToWindowsUpdateInternetLocations = 1` policy key
