# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A PowerShell pipeline that builds a trimmed-down Windows 11 install ISO (a "tiny11"-style image): mount a
real Windows 11 ISO, strip bloat (provisioned apps, scheduled tasks, Edge, OneDrive, telemetry), apply
registry tweaks, optionally inject drivers (host system and/or KVM/QEMU virtio), then repackage everything
into a new bootable ISO with `oscdimg.exe`. One script, two build modes:

- **Serviceable build** (default) — can still take Windows Update/features/languages post-install.
- **Core build** (`-Core` switch) — additionally strips WinSxS/Windows Update/Windows Defender/WinRE for a
  non-serviceable, disposable testbed image (e.g. for VMs). Cannot add updates, languages, or features
  afterward.

There used to be a second, separate `asl-win11-coremaker.ps1` script for the core build; it has been folded
into `asl-win11maker.ps1` behind the `-Core` switch and deleted. Core-build-only functions in
`asl-win11.functions.ps1` are always called from inside an `if ($Core) { ... }` guard in the runner — never
assume one runs for the serviceable build without checking.

The script must run on Windows, under PowerShell 5.1, elevated (it self-relaunches as admin if not), with a
Windows 11 ISO already mounted to a drive letter.

## Submodules are reference-only

`reference/winutil/`, `reference/tiny11-automated/`, `reference/tiny11builder-ntdevlabs/`, and
`reference/rufus/` are git submodules of other projects, kept under `reference/` purely for
comparison/lookup (see `docs/script-comparison.md`, which diffs this repo's ISO-building logic against
winutil's `Invoke-WinUtilISOScript.ps1`). **Do not edit code inside these submodules and don't treat them as
part of this project's build/test surface.** They exist to look up how another project solved something, not
to be modified or kept in sync. If you add another external project for reference, add it as a submodule
under `reference/` too.

## Commands

Syntax-check all top-level `*.ps1` files (fast, no module dependency):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-RepoSyntaxCheck.ps1
```

Lint with PSScriptAnalyzer (requires `Install-Module PSScriptAnalyzer -Scope CurrentUser` once):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-RepoScriptAnalyzer.ps1
```
Both scripts scan every `*.ps1` in the repo root (excluding themselves) and exit non-zero on errors. Lint
severity is restricted to `Error`/`Warning`, and `PSScriptAnalyzerSettings.psd1` deliberately excludes several
style-only rules (`PSUseShouldProcessForStateChangingFunctions`, `PSAvoidUsingWriteHost`,
`PSUseSingularNouns`, `PSUseBOMForUnicodeEncodedFile`) — this is treated as a legacy script repo, so don't
"fix" those without being asked.

Run the main builder (from an elevated PowerShell 5.1 session, with the Windows 11 ISO mounted):
```powershell
Set-ExecutionPolicy Bypass -Scope Process
.\asl-win11maker.ps1 -ISO E -SCRATCH D
```
`-SCRATCH` is optional; omitting it uses `work/` under the repo root as the scratch build root.

Other parameters, all optional:
- `-INDEX <n>` / `-ESDINDEX <n>` — pin the install.wim / install.esd image index non-interactively; prompts
  when omitted.
- `-BypassMode None|Hive|Unattend|Both` — Windows 11 hardware-check bypass strategy. **Default is `None`** —
  this is a deliberate behavior change from the pre-combined-builder scripts, which always applied the
  LabConfig bypass to `boot.wim`. `Hive` edits the offline registry hives directly (install.wim + boot.wim);
  `Unattend` embeds Rufus-style `reg add` commands as `RunSynchronousCommand` entries in `autounattend.xml`
  instead, for environments where direct hive access isn't available.
- `-Core` — build the non-serviceable core image instead of the serviceable one.
- `-InjectSystemDrivers` — export drivers from the host system and inject into install.wim + boot.wim.
- `-DriverPath <folder>` — inject an arbitrary local driver folder into install.wim + boot.wim.
- `-InjectVirtioDrivers` [`-VirtioIso <path>`] [`-SkipVirtioGuestTools`] — inject KVM/QEMU virtio-win drivers
  (critical: boot.wim needs the virtio storage drivers or Setup can't see the VM disk) and stage the
  virtio-win guest tools to install at first logon. `-VirtioIso` accepts a drive letter, an `.iso` path, or
  an extracted folder; omitting it downloads the latest stable `virtio-win.iso`.
- `-EnableDotNet35` — core build only; enables .NET Framework 3.5 from source media without prompting.

There is no automated test suite — the scripts mutate a real Windows image and require admin rights plus a
multi-GB ISO, so correctness is validated by syntax check + lint + manual runs, not unit tests.

## Architecture

### `asl-win11maker.ps1` — entry point / orchestrator
Thin runner: dot-sources `asl-win11.functions.ps1`, then calls a **linear, ordered pipeline** of functions.
Each call is annotated `REQUIRED` (core pipeline step — don't reorder/remove) or `OPTIONAL` (a specific
removal/tweak — safe to comment out to keep that feature in the final image). A third category,
`SWITCH-GATED`, covers driver injection and `-Core`-only blocks: these are wrapped in `if (...)` rather than
comment-out, because they're controlled by command-line parameters, not by editing the script. When adding a
new *always-on* tweak, follow the `OPTIONAL` pattern: implement it as a function in the functions library,
then add one `OPTIONAL`-tagged call in the appropriate phase of this pipeline. When adding a new
*parameter-controlled* feature, follow the `SWITCH-GATED` pattern instead.

The pipeline shape is: resolve/validate ISO source → copy source media into scratch → mount `install.wim` →
inject drivers into install.wim (switch-gated) → remove provisioned app packages → core-build-only file-level
stripping (switch-gated) → load offline registry hives → apply hardware-bypass strategy → apply registry
tweaks → core-build-only registry tweaks (switch-gated) → unload hives → DISM component cleanup +
recovery-compressed export (→ ESD instead, for `-Core`) → `Update-BootImage` (bypass tweaks + driver
injection + `-Core`'s `Setup\CmdLine` key, all in one boot.wim mount) → build the ISO with `oscdimg` → clean
up temp files (incl. any virtio ISO this run mounted) and eject the source ISO.

Three arrays near the top of the script are the primary customization surface — comment out an entry to keep
that package/task/component in the final image instead of touching the pipeline logic:
- `$appPackagePrefixes` — provisioned appx/MSIX package prefixes (all builds)
- `$scheduledTaskPaths` — scheduled task definition files to delete (all builds)
- `$systemPackagePatterns` — Windows system component (CBS/FoD) packages, consumed only by
  `Remove-SystemPackages` under `-Core`

See `docs/tweak-catalog.md` for the full four-way inventory (this repo vs. ntdevlabs vs. tiny11-automated vs.
winutil) of what's in each array and every registry tweak, including what's deliberately left commented out
or unported.

### `asl-win11.functions.ps1` — function library
All reusable logic, dot-sourced into the caller's scope (functions read/write `$script:`-scoped state set up
by `Initialize-Tiny11Session`, e.g. `$script:mountDir`, `$script:tiny11Root`, `$script:installWimPath`,
`$script:bootWimPath`, `$script:DriveLetter`, `$script:index`, `$script:adminGroupName`, plus the newer
`$script:architecture`, `$script:languageCode`, `$script:preparedAutounattendXml`, `$script:hostDriverPath`,
`$script:virtioRoot`, `$script:virtioIsoMountedPath` — this is why these functions are dot-sourced rather
than imported as a module, and why they aren't safely callable standalone without the session having been
initialized first). They also read the entry script's bound parameters directly by name (e.g. `$BypassMode`,
`$Core`, `$INDEX`) via PowerShell's normal scope inheritance — the same mechanism `$ISO`/`$SCRATCH` have
always used — so a new parameter is visible to every function without extra plumbing.

**Logging convention:** `Write-Log`/`Write-Phase` use `Write-Host`, not `Write-Output` — this is deliberate.
Several functions (`Resolve-VirtioDriverSource`, `Export-HostSystemDrivers`, etc.) `return` a value the
caller captures directly (e.g. `$script:virtioRoot = Resolve-VirtioDriverSource ...`); if their internal
logging used `Write-Output`, those log lines would land in the success stream and corrupt the captured
return value. `Start-Transcript` still captures `Write-Host` output, so nothing is lost. Follow this same
pattern in any new function that both logs and returns a value the caller captures.

Loosely grouped:
- **Removal**: `Remove-ProvisionedAppPackages`, `Remove-Edge`, `Remove-OneDriveSetup`, `Remove-ScheduledTasks`,
  `Remove-IsoSupportFolder`; core-build-only: `Remove-SystemPackages`, `Remove-EdgeWebViewWinSxS`,
  `Remove-WindowsRecoveryEnvironment`, `Compress-WinSxS`, `Enable-DotNet35`
- **Answer file / edition**: `Get-AnswerFileChildElement`, `ConvertTo-Tiny11AnswerFile` (injects
  `/IMAGE/INDEX`), `Add-AnswerFileBypassCommands` (Rufus-style `Unattend` bypass mode), `Set-Tiny11EditionConfig`
  (ei.cfg/PID.txt)
- **Driver injection**: `Add-DriversToImage`, `Export-HostSystemDrivers`, `Resolve-VirtioDriverSource`,
  `Add-VirtioDriversToImage`, `Install-VirtioGuestToolsAtFirstLogon`
- **Registry/behavior tweaks**: `Disable-*` / `Enable-*` functions (telemetry, Copilot, Teams, sponsored apps,
  reserved storage, BitLocker auto-encryption, OneDrive sync, new Outlook, Dev Home/Outlook install,
  Windows Update, diagnostic services, Windows AI, etc.), plus `Set-BypassHardwareChecks` and the
  `Invoke-HardwareBypassStrategy` dispatcher that reads `-BypassMode`; core-build-only:
  `Disable-WindowsDefender`, `Set-BootImageSetupCmdLine`
- **Session/orchestration**: `Confirm-ExecutionPolicy`, `Confirm-AdminPrivileges` (self-elevate, forwards
  every bound parameter via `$script:EntryBoundParameters`), `Confirm-AutounattendXml` (downloads it from the
  upstream `ntdevlabs/tiny11builder` GitHub repo if missing locally), `Initialize-Tiny11Session`,
  `Show-CoreBuildWarning`, `Resolve-SourceDriveLetter`, `Confirm-InstallWimSource` (handles ESD→WIM
  conversion, honors `-ESDINDEX`), `Copy-SourceImageFiles`, `Resolve-InstallImageIndex` (honors `-INDEX`),
  `Mount-InstallImage`, `Show-ImageMetadata`, `Initialize-PreparedAnswerFile` (prepares `autounattend.xml`
  once so the Sysprep copy, ISO-root copy, and Unattend bypass mode never drift apart),
  `Mount-OfflineRegistryHives` / `Dismount-OfflineRegistryHives`, `Complete-InstallImage` (calls
  `Export-CoreInstallEsd` under `-Core`), `Update-BootImage`, `New-Tiny11Iso`, `Write-BuildInfo`,
  `Invoke-Tiny11Cleanup`, `Invoke-Tiny11EmergencyCleanup`, `Confirm-DotNet35Enablement`

### Working directories (all gitignored)
- `work/` — default scratch build root (source copy, mounted image contents) when `-SCRATCH` isn't given
- `work\drivers\` (or `<SCRATCH>:\drivers\`) — staging for host-exported drivers, staged virtio drivers, and
  a downloaded `virtio-win.iso`, when driver injection is used. Removed by `Invoke-Tiny11Cleanup` /
  `Invoke-Tiny11EmergencyCleanup` alongside dismounting any virtio ISO this run mounted.
- `logs/` — `Start-Transcript` output per run, plus a parallel structured log (`Write-Log`)
- `output/` — final built ISO lands here (`New-Tiny11Iso`), alongside `asl-win11-buildinfo.json`
  (`Write-BuildInfo`)

### External binaries
- `oscdimg.exe` — used to author the final bootable ISO. Sourced from the Windows ADK if installed at the
  standard path, otherwise downloaded from the Microsoft symbol server into the repo root and deleted again
  during `Invoke-Tiny11Cleanup`.
- `autounattend.xml` — unattended-setup answer file (bypasses MSA requirement on OOBE, deploys with
  `/compact`). Auto-fetched from GitHub if not present locally; also deleted during cleanup.
- `virtio-win.iso` — only fetched when `-InjectVirtioDrivers` is used without `-VirtioIso`; downloaded from
  `fedorapeople.org` into the scratch `drivers\` folder, not the repo root.

### Reference docs
- `docs/script-comparison.md` — the four-way (ntdevlabs / tiny11-automated / winutil / Rufus) feature
  comparison this combined-builder work was derived from.
- `docs/tweak-catalog.md` — the full inventory of app package prefixes, scheduled tasks, and registry tweaks
  across all four tools, with what this repo applies by default vs. ships commented-out vs. deliberately
  doesn't port.
