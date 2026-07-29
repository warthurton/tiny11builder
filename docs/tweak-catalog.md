# Tweak Catalog: App Packages, Scheduled Tasks, and Registry Tweaks

Full four-way inventory (this repo vs. `ntdevlabs` vs. `tiny11-automated` vs. `winutil`) backing
`docs/script-comparison.md` §4 items 5–7. Where `docs/script-comparison.md` compares the *tools*, this
document catalogs the *individual tweaks* so every line in `asl-win11maker.ps1` and
`asl-win11.functions.ps1` traces back to a documented source.

**Default column key:**
- **Active** — applied unconditionally by the serviceable build
- **Commented** — present in the customization array/pipeline but commented out; opt in by uncommenting
- **Core only** — applied only when `-Core` is passed
- **`-BypassMode`** — applied only for the selected hardware-bypass strategy

---

## 1. App package prefixes (`$appPackagePrefixes`)

| Prefix | What it is | ntdevlabs | tiny11-automated | winutil | Default in this repo |
| --- | --- | :-: | :-: | :-: | --- |
| `AppUp.IntelManagementandSecurityStatus` | Intel Management & Security Status OEM bloatware | ✅ | ✅ | ❌ | Active |
| `Clipchamp.Clipchamp` | Clipchamp video editor | ✅ | ✅ | ✅ | Active |
| `DolbyLaboratories.DolbyAccess` | Dolby Access audio OEM app | ✅ | ✅ | ❌ | Active |
| `DolbyLaboratories.DolbyDigitalPlusDecoderOEM` | Dolby Digital Plus decoder OEM app | ✅ | ✅ | ❌ | Active |
| `Microsoft.BingNews` | Microsoft News (Bing News) | ✅ | ✅ | ✅ | Active |
| `Microsoft.BingSearch` | Bing Search integration app | ✅ | ✅ | ✅ | Active |
| `Microsoft.BingWeather` | Microsoft Weather (Bing Weather) | ✅ | ✅ | ✅ | Active |
| `Microsoft.Copilot` | Microsoft Copilot AI assistant app | ✅ | ✅ | ❌ | Active |
| `Microsoft.Windows.CrossDevice` | Cross-device experience (Phone Link companion) | ✅ | ✅ | ❌ | Active |
| `Microsoft.GamingApp` | Xbox Gaming App (Game Pass hub) | ✅ | ✅ | ❌ | Active |
| `Microsoft.GetHelp` | Get Help support app | ✅ | ✅ | ✅ | Active |
| `Microsoft.Getstarted` | Tips / Get Started app | ✅ | ✅ | ❌ | Active |
| `Microsoft.Microsoft3DViewer` | 3D Viewer app | ✅ | ✅ | ❌ | Active |
| `Microsoft.MicrosoftOfficeHub` | Office Hub ("Get Office" / Microsoft 365 app) | ✅ | ✅ | ✅ | Active |
| `Microsoft.MicrosoftSolitaireCollection` | Microsoft Solitaire Collection game | ✅ | ✅ | ✅ | Active |
| `Microsoft.MicrosoftStickyNotes` | Sticky Notes app | ✅ | ✅ | ✅ | Active |
| `Microsoft.MixedReality.Portal` | Mixed Reality Portal (VR/AR) | ✅ | ✅ | ❌ | Active |
| `Microsoft.MPEG2VideoExtension` | MPEG-2 video playback extension | ❌ | ✅ | ❌ | **Commented** |
| `Microsoft.MSPaint` | Paint 3D (legacy MSPaint UWP) | ✅ | ❌ | ❌ | Commented (already was) |
| `Microsoft.Office.OneNote` | OneNote UWP app | ✅ | ✅ | ❌ | Active |
| `Microsoft.OfficePushNotificationUtility` | Office push notification background service | ✅ | ✅ | ❌ | Active |
| `Microsoft.OutlookForWindows` | New Outlook for Windows app | ✅ | ✅ | ✅ | Active |
| `Microsoft.Paint` | Paint app (modern) | ✅ | ✅ | ✅ | Commented (already was) |
| `Microsoft.People` | People contacts app | ✅ | ✅ | ❌ | Active |
| `Microsoft.PowerAutomateDesktop` | Power Automate Desktop (RPA tool) | ✅ | ✅ | ✅ | Active |
| `Microsoft.Recall` | Windows Recall (older package name) | ❌ | ✅ | ❌ | **Commented** |
| `Microsoft.ScreenSketch` | Snip & Sketch screenshot tool | ❌ | ✅ | ❌ | **Commented** |
| `Microsoft.SkypeApp` | Skype UWP app | ✅ | ✅ | ❌ | Active |
| `Microsoft.StartExperiencesApp` | Start menu experiences / recommendations app | ✅ | ✅ | ✅ | Active |
| `Microsoft.StorePurchaseApp` | Microsoft Store purchase/checkout helper | ❌ | ✅ | ❌ | **Commented** |
| `Microsoft.Todos` | Microsoft To Do task manager | ✅ | ✅ | ✅ | Active |
| `Microsoft.Wallet` | Microsoft Wallet (NFC payments) | ✅ | ✅ | ❌ | Active |
| `Microsoft.WebMediaExtensions` | Web media codec extensions | ❌ | ✅ | ❌ | **Commented** |
| `Microsoft.Windows.AI` | Windows AI platform component | ❌ | ✅ | ❌ | **Commented** |
| `Microsoft.Windows.AIFabric` | Windows AI Fabric runtime | ❌ | ✅ | ❌ | **Commented** |
| `Microsoft.Windows.Copilot` | Windows Copilot integration | ✅ | ✅ | ❌ | Active |
| `Microsoft.Windows.CoreAI` | Windows Core AI component | ❌ | ✅ | ❌ | **Commented** |
| `Microsoft.Windows.DevHome` | Dev Home developer dashboard app | ✅ | ✅ | ✅ | Active |
| `Microsoft.Windows.Photos` | Photos app | ❌ | ✅ | ❌ | **Commented** |
| `Microsoft.Windows.Recall` | Windows Recall (current package name) | ❌ | ✅ | ❌ | **Commented** |
| `Microsoft.Windows.Teams` | Microsoft Teams (Chat) integration | ✅ | ✅ | ❌ | Active |
| `Microsoft.WindowsAlarms` | Alarms & Clock app | ✅ | ✅ | ❌ | Active |
| `Microsoft.WindowsCamera` | Camera app | ✅ | ✅ | ❌ | Active |
| `microsoft.windowscommunicationsapps` | Mail and Calendar apps | ✅ | ✅ | ❌ | Active |
| `Microsoft.WindowsFeedbackHub` | Feedback Hub app | ✅ | ✅ | ✅ | Active |
| `Microsoft.WindowsMaps` | Windows Maps app | ✅ | ✅ | ❌ | Active |
| `Microsoft.WindowsSoundRecorder` | Sound Recorder / Voice Recorder app | ✅ | ✅ | ✅ | Active |
| `Microsoft.WindowsTerminal` | Windows Terminal app | ✅ | ✅ | ❌ | Commented (already was) |
| `MicrosoftWindows.Client.WebExperience` | Widgets board | ❌ | ✅ | ❌ | **Commented** |
| `Microsoft.Xbox.TCUI` | Xbox Title-Callable UI (game overlay helper) | ✅ | ✅ | ❌ | Active |
| `Microsoft.XboxApp` | Xbox Console Companion app | ✅ | ✅ | ❌ | Active |
| `Microsoft.XboxGameOverlay` | Xbox Game Overlay (in-game UI) | ✅ | ✅ | ❌ | Active |
| `Microsoft.XboxGamingOverlay` | Xbox Game Bar overlay | ✅ | ✅ | ❌ | Active |
| `Microsoft.XboxIdentityProvider` | Xbox Identity Provider (sign-in service) | ✅ | ✅ | ❌ | Active |
| `Microsoft.XboxSpeechToTextOverlay` | Xbox speech-to-text overlay (accessibility) | ✅ | ✅ | ❌ | Active |
| `Microsoft.YourPhone` | Phone Link (formerly Your Phone) app | ✅ | ✅ | ❌ | Active |
| `Microsoft.ZuneMusic` | Groove Music / Media Player (Zune Music) | ✅ | ✅ | ❌ | Active |
| `Microsoft.ZuneVideo` | Movies & TV app (Zune Video) | ✅ | ✅ | ❌ | Active |
| `MicrosoftCorporationII.MicrosoftFamily` | Microsoft Family Safety app | ✅ | ✅ | ❌ | Active |
| `MicrosoftCorporationII.QuickAssist` | Quick Assist remote help app | ✅ | ✅ | ✅ | Active |
| `MSTeams` / `MicrosoftTeams` | Microsoft Teams (MSIX + legacy variants) | ✅ | ✅ | ✅ (`MSTeams` only) | Active |
| `Microsoft.549981C3F5F10` | Cortana app (internal package name) | ✅ | ✅ | ❌ | Active |

Not ported from tiny11-automated: nothing further — the table above is the full diff. winutil's list is a
strict subset of this repo's; every winutil prefix not marked ❌ above is covered.

## 2. Scheduled task paths (`$scheduledTaskPaths`)

| Task path | What it does | This repo / ntdevlabs / tiny11-automated | winutil | Default in this repo |
| --- | --- | :-: | :-: | --- |
| `Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser` | Collects app compatibility telemetry | ✅ | ✅ | Active |
| `Microsoft\Windows\Customer Experience Improvement Program` (whole folder) | CEIP usage data | ✅ | ✅ | Active |
| `Microsoft\Windows\Application Experience\ProgramDataUpdater` | Updates compat telemetry cache | ✅ | ✅ | Active |
| `Microsoft\Windows\Chkdsk\Proxy` | Filesystem error notifications | ✅ | ✅ | Active |
| `Microsoft\Windows\Windows Error Reporting\QueueReporting` | Crash/error report submission | ✅ | ✅ | Active |
| `Microsoft\Windows\InstallService` | Store/Push-Button-Reset install service tasks | ❌ | ✅ | **Commented** |
| `Microsoft\Windows\UpdateOrchestrator` | Update Orchestrator scheduled tasks | ❌ | ✅ | **Commented** |
| `Microsoft\Windows\UpdateAssistant` | Update Assistant scheduled tasks | ❌ | ✅ | **Commented** |
| `Microsoft\Windows\WaaSMedic` | WaaS Medic self-repair scheduled tasks | ❌ | ✅ | **Commented** |
| `Microsoft\Windows\WindowsUpdate` | Windows Update scheduled tasks | ❌ | ✅ | **Commented** |
| `Microsoft\WindowsUpdate` | Legacy Windows Update scheduled tasks | ❌ | ✅ | **Commented** |

The six commented entries are winutil's additions (§4 item 5: "make optional"). They're WU-specific and
would reduce WU's ability to self-heal on a *serviceable* image, hence commented rather than active by
default — enable them if you want a more aggressive strip on a build you don't plan to keep serviceable.

## 3. Registry tweaks

Grouped by the function that applies them. "Default" reflects the serviceable build; every Core-only
function is forced on regardless.

| Function | Tweaks | Source | Default |
| --- | --- | --- | --- |
| `Set-BypassHardwareChecks` | 5 LabConfig bypass keys, `AllowUpgradesWithUnsupportedTPMOrCPU`, notification-cache suppression | ntdevlabs/tiny11-automated (identical set) | Applied per `-BypassMode` (`Hive`/`Both`); default mode `None` |
| `Add-AnswerFileBypassCommands` | Same 5 LabConfig keys, embedded as `RunSynchronousCommand` in `autounattend.xml` instead of an offline hive edit | Rufus `wue.c` (Rufus itself only sets 3 of the 5; this repo emits all 5 for parity) | Applied per `-BypassMode` (`Unattend`/`Both`) |
| `Disable-SponsoredApps` | ~20 keys: OEM app suggestions, silent installs, Start pins, subscribed content IDs, push-to-install, MRT | ntdevlabs (identical) | Active |
| `Disable-Telemetry` | Advertising ID, tailored experiences, speech/ink/text collection, `AllowTelemetry=0`, `dmwappushservice` disabled | ntdevlabs (identical) | Active |
| `Disable-DevHomeOutlookInstall` | `workCompleted` markers + `UScheduler_Oobe` removal for Outlook/DevHome | ntdevlabs (identical) | Active |
| `Disable-Copilot` | `TurnOffWindowsCopilot`, Edge Hubs sidebar, search box web suggestions | ntdevlabs (identical) | Active |
| `Disable-ReservedStorage` / `Disable-BitLockerAutoEncryption` / `Disable-ChatIcon` / `Disable-OneDriveSync` / `Disable-TeamsInstall` / `Disable-NewOutlook` | One or two keys each | ntdevlabs (identical) | Active |
| `Disable-WindowsUpdate` | RunOnce WU-stop commands, WU server redirected to `localhost`, OOBE `DisableOnline`, `WaaSMedicSVC`/`UsoSvc` **deleted**, plus winutil's `AUOptions`/`UseWUServer`/`DODownloadMode=0`/BITS `Start=4` | asl-win11-coremaker.ps1 (aggressive form) merged with winutil (additive tweaks); see function docstring for the two documented conflict resolutions | **Commented** (serviceable build); Core only, forced |
| `Disable-DiagnosticServices` | `DiagTrack`/`WerSvc`/`PcaSvc`/`SysMain` set to `Start=4` | tiny11-automated | **Commented** |
| `Disable-WindowsAI` | `WindowsAI` policy keys (HKLM + NTUSER), `DoNotShowFeedbackNotifications`, `AllowDeviceNameInTelemetry` | tiny11-automated | **Commented** |
| `Disable-WindowsDefender` | `WinDefend`/`WdNisSvc`/`WdNisDrv`/`WdFilter`/`Sense` disabled, Settings pages hidden | asl-win11-coremaker.ps1 | Core only |
| `Set-BootImageSetupCmdLine` | `HKLM\SYSTEM\Setup\CmdLine = X:\sources\setup.exe` | asl-win11-coremaker.ps1 | Core only |

Not ported from tiny11-automated (recorded here per §4's "not recommended for porting" precedent):
`Apply-PerformanceTweaks` (memory/network/gaming performance registry tuning) and its Tiny11-branding keys
(`legalnoticecaption`, the `Tiny11Info` desktop shell entry) — out of scope for this repo, which focuses on
bloat/telemetry removal rather than performance tuning or rebranding.

---

## See also

- `docs/script-comparison.md` — the tool-level (not tweak-level) comparison this catalog was derived from.
- `CLAUDE.md` — architecture overview and the function groupings these tweaks live in.
