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

`-ISO` accepts either a drive letter of an already-mounted ISO/DVD (eg `E`) or a path to a Windows 11 `.iso`
file, which the script mounts itself via `Mount-DiskImage` and dismounts again during cleanup — this is
resolved in `Resolve-SourceDriveLetter`, mirroring the existing `-VirtioIso` drive-letter-or-path-or-folder
pattern.

Other parameters, all optional:
- `-INDEX <n>` / `-ESDINDEX <n>` — pin the install.wim / install.esd image index non-interactively; prompts
  when omitted. Ignored if `-Edition` is also given.
- `-Edition <name>` — look up the image index by edition name instead (eg `Pro`, `Home`, `Education`,
  `Professional`). `Resolve-EditionImageIndex` matches case-insensitively as a substring against either the
  image's friendly name (`Windows 11 Pro`) or its DISM Edition ID (`Professional`, or `Core` for Home) — covers
  both common naming and DISM's internal naming, which don't always agree. Applies to install.wim (via
  `Resolve-InstallImageIndex`) and, when converting from install.esd, the ESD source too (via
  `Confirm-InstallWimSource`). Errors out if the name matches zero or more than one image.
- `-BypassMode None|Hive|Unattend|Both` — Windows 11 hardware-check bypass strategy. **Default is `None`** —
  this is a deliberate behavior change from the pre-combined-builder scripts, which always applied the
  LabConfig bypass to `boot.wim`. `Hive` edits the offline registry hives directly (install.wim + boot.wim);
  `Unattend` embeds Rufus-style `reg add` commands as `RunSynchronousCommand` entries in `autounattend.xml`
  instead, for environments where direct hive access isn't available.
- `-Core` — build the non-serviceable core image instead of the serviceable one.
- `-InjectSystemDrivers` — export drivers from the host system and inject the full set into install.wim;
  the storage-class subset is also staged into `$WinpeDriver$` at the ISO root for Setup's WinPE environment
  (see `Add-WinPEStorageDrivers`) — boot.wim itself is never mounted for this.
- `-DriverPath <folder>` — same treatment as `-InjectSystemDrivers` but for an arbitrary local driver folder:
  full set into install.wim, storage-class subset into `$WinpeDriver$`.
- `-InjectVirtioDrivers` [`-VirtioIso <path>`] [`-SkipVirtioGuestTools`] — inject KVM/QEMU virtio-win drivers
  into install.wim, and stage the storage driver (viostor/vioscsi) into `$WinpeDriver$` (critical: Setup's
  WinPE environment needs to see the VM disk before it can install to it), plus stage the virtio-win guest
  tools to install at first logon. `-VirtioIso` accepts a drive letter, an `.iso` path, or an extracted
  folder; omitting it downloads the latest stable `virtio-win.iso`.
- `-EnableDotNet35` — core build only; enables .NET Framework 3.5 from source media without prompting.
- `-UseSourceCache` [`-RefreshSourceCache`] — cache the pristine, just-extracted install.wim/boot.wim under
  `<SCRATCH>\sourcecache\` and restore from it on reruns instead of re-copying from the mounted ISO (and
  redoing the install.esd→install.wim conversion, when the source ships an ESD). Lets you iterate on
  `-BypassMode`, driver injection, or the removal lists without repeating the slow ISO extraction each time;
  `-ISO` becomes unnecessary once a valid cache exists. `-RefreshSourceCache` forces a rebuild from the ISO
  (e.g. after swapping in a different Windows 11 ISO). The cache is separate from, and never mutated by, the
  per-run working copy in `<SCRATCH>\asl-win11\` — `Complete-InstallImage` renames/deletes files in that
  working copy in place, so reusing it directly as the cache would let one run's `-Core`/`ResetBase`/tweaks
  silently carry into the next.
- `-LocalAccountName <name>` — embeds a `<UserAccounts><LocalAccounts><LocalAccount>` block into
  `autounattend.xml` (`Add-AnswerFileLocalAccount`, modeled on Rufus's `UNATTEND_SET_USER` —
  `reference/rufus/src/wue.c:344-383`) so OOBE creates the account automatically, in Administrators,
  instead of requiring a Microsoft account. Unlike Rufus (blank password + force-change-at-first-logon via
  the magic Base64 "Password" placeholder), the password is set to the same value as the account name in
  plain text — no password generation/storage logic needed, at the cost of a weak, publicly-guessable
  password. Fine for disposable/dev/VM images; never use on an image reachable by an untrusted network or
  user. Rejects reserved account names (`Administrator`, `Guest`, `SYSTEM`, etc.) and sanitizes disallowed
  characters, matching Rufus's validation.
- `-ProductKey <key>` — embeds a real product key into `autounattend.xml`'s `UserData/ProductKey/Key` so
  Setup activates automatically. Optional: `autounattend.xml` always carries a `UserData/ProductKey` element
  (empty `Key` by default) with `WillShowUI` forced to `Never`, because Windows Setup shows the blocking
  "Enter your product key" screen (and aborts the install if that screen is Cancelled) whenever the
  `ProductKey` element is absent entirely — even an empty one satisfies it. Same requirement Rufus works
  around (`reference/rufus/src/wue.c:145-151`). This is what makes a fully unattended install possible without
  a key; `-ProductKey` only matters if you want automatic activation instead of an unactivated install.
- `-CompressionMode None|Fast|Max|Recovery` — DISM `/Export-Image /Compress` mode for the final install.wim
  (and, under `-Core`, the install.esd conversion). **Default is `Fast`** — matches the original tiny11
  scripts' hardcoded behavior. `Max` shrinks the image further at the cost of a much slower export;
  `Recovery` matches the WIMBoot-style compression Windows Setup's own install.esd uses (smallest, slowest);
  `None` skips recompression (largest, fastest — useful for quick local iteration).

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

The pipeline shape is: prevent the system from sleeping mid-build → populate scratch source files (from the
`-UseSourceCache` cache when valid, else resolve/validate ISO source and copy source media into scratch) →
mount `install.wim` → inject drivers into install.wim, plus stage the storage-class subset into `$WinpeDriver$`
at the ISO root for Setup's own WinPE environment (switch-gated) → remove provisioned app packages →
core-build-only file-level stripping (switch-gated) → load offline registry hives → apply hardware-bypass
strategy → apply registry tweaks → core-build-only registry tweaks (switch-gated) → unload hives → DISM
component cleanup + recovery-compressed export (→ ESD instead, for `-Core`) → `Update-BootImage` (bypass
tweaks + `-Core`'s `Setup\CmdLine` key, in one boot.wim mount — no driver injection here, see above) → build
the ISO with `oscdimg` → clean up temp files (incl. any virtio ISO this run mounted), release the
sleep-prevention request, and eject the source ISO (skipped if this run used the source cache and never
mounted one).

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
  `/IMAGE/INDEX` and `UserData/AcceptEula` + `UserData/ProductKey` with `WillShowUI` forced to `Never`, so
  Setup's product-key screen never blocks the install; embeds `-ProductKey` when given, else an empty key),
  `Add-AnswerFileBypassCommands` (Rufus-style `Unattend` bypass mode),
  `Add-AnswerFileLocalAccount` (Rufus-style `-LocalAccountName` local account, password = account name),
  `Set-Tiny11EditionConfig` (ei.cfg/PID.txt)
- **Driver injection**: `Add-DriversToImage` (install.wim only — DISM `Add-Driver`), `Export-HostSystemDrivers`,
  `Resolve-VirtioDriverSource`, `Add-VirtioDriversToImage` (also returns its staging dir, for
  `Add-WinPEStorageDrivers` to reuse), `Install-VirtioGuestToolsAtFirstLogon`, `Test-StorageDriverInf`
  (storage/RAID-class heuristic: INF `Class=SCSIAdapter|HDC`, or a filename fallback covering
  iaahci/iastor/vmd/irst/rst/viostor/vioscsi/nvme), `Copy-WinPEDriverFolder` (collision-safe copy),
  `Add-WinPEStorageDrivers` (stages the storage-class subset of a driver source into `$WinpeDriver$` at the
  ISO root — Windows Setup auto-loads drivers from there during its windowsPE pass, confirmed via Microsoft
  KB2686316 to work from optical/ISO media and not just USB, so Setup can see an unusual disk controller
  without ever mounting boot.wim; ported from winutil's `Add-WinUtilISOStagedDrivers`
  (`reference/winutil/functions/private/Invoke-WinUtilISOScript.ps1`), which replaced its own old
  boot.wim-mount driver injection for the same reason — avoids bloating boot.wim with every non-storage
  driver and an extra mount/commit cycle)
- **Registry/behavior tweaks**: `Disable-*` / `Enable-*` functions (telemetry, Copilot, Teams, sponsored apps,
  reserved storage, BitLocker auto-encryption, OneDrive sync, new Outlook, Dev Home/Outlook install,
  Windows Update, diagnostic services, Windows AI, etc.), plus `Set-BypassHardwareChecks` and the
  `Invoke-HardwareBypassStrategy` dispatcher that reads `-BypassMode`; core-build-only:
  `Disable-WindowsDefender`, `Set-BootImageSetupCmdLine`
- **Session/orchestration**: `Confirm-ExecutionPolicy`, `Confirm-AdminPrivileges` (self-elevate, forwards
  every bound parameter via `$script:EntryBoundParameters`), `Confirm-AutounattendXml` (downloads it from the
  upstream `ntdevlabs/tiny11builder` GitHub repo if missing locally), `Set-SleepPrevention` /
  `Clear-SleepPrevention` (P/Invoke `SetThreadExecutionState` so a multi-hour build doesn't get frozen by
  Windows suspending the machine mid-DISM-operation; `Clear-SleepPrevention` is called before the final
  `Invoke-Tiny11Cleanup` prompt so it's fine for the system to sleep while idle there),
  `Initialize-Tiny11Session`, `Show-CoreBuildWarning`, `Initialize-SourceImage` (dispatches to the
  `-UseSourceCache` cache via `Test-SourceCachePopulated` when valid, else calls the three functions below and
  refreshes the cache), `Resolve-SourceDriveLetter` (accepts a drive letter or a `.iso` path — mounts the
  latter via `Mount-DiskImage` and sets `$script:sourceIsoMountedPath`, mirroring `Resolve-VirtioDriverSource`),
  `Resolve-EditionImageIndex` (name→index lookup backing `-Edition`, shared by `Confirm-InstallWimSource`'s ESD
  path and `Resolve-InstallImageIndex`'s install.wim path), `Confirm-InstallWimSource` (handles ESD→WIM
  conversion, honors `-Edition` then `-ESDINDEX`), `Copy-SourceImageFiles`, `Resolve-InstallImageIndex` (honors
  `-Edition` then `-INDEX`), `Mount-InstallImage`, `Show-ImageMetadata`, `Initialize-PreparedAnswerFile`
  (prepares `autounattend.xml` once, injecting the image index, product-key handling (`-ProductKey`), and,
  when `-LocalAccountName` is given, the local account, so the Sysprep copy, ISO-root copy, and Unattend
  bypass mode never drift apart),
  `Mount-OfflineRegistryHives` / `Dismount-OfflineRegistryHives`, `Complete-InstallImage` (calls
  `Export-CoreInstallEsd` under `-Core`), `Update-BootImage`, `New-Tiny11Iso` (names the output ISO
  `asl-win11_<tags>_<yyyyMMdd>.iso` via `Get-Tiny11IsoNameTag`, which sanitizes `$script:editionId` and
  appends a tag per active non-default option — `Core`, `Bypass<Mode>`, `Virtio`, `SysDrivers`,
  `CustomDrivers`, `LocalAcct`, `Compress<Mode>` (when `-CompressionMode` isn't the default `Fast`) — so
  multiple ISOs in `output\` stay distinguishable at a glance), `Write-BuildInfo`,
  `Invoke-Tiny11Cleanup` (dismounts `$script:sourceIsoMountedPath` by path when this run mounted the source ISO
  itself; falls back to ejecting `$script:DriveLetter`'s volume when the caller passed an already-mounted
  drive letter instead; skips both when `$script:DriveLetter` was never set, i.e. this run restored from the
  source cache), `Invoke-Tiny11EmergencyCleanup`, `Confirm-DotNet35Enablement`

### Working directories (all gitignored)
- `work/` — default scratch build root (source copy, mounted image contents) when `-SCRATCH` isn't given
- `work\asl-win11\` (or `<SCRATCH>:\asl-win11\`) — per-run working copy of the source files; mounted,
  mutated, and finalized by the pipeline each run. Removed and recreated every run regardless of
  `-UseSourceCache` — cheap to recreate from the cache below, so nothing is lost by not preserving it.
- `work\sourcecache\` (or `<SCRATCH>:\sourcecache\`) — only populated when `-UseSourceCache` is passed: a
  pristine, untouched copy of `sources\install.wim`/`boot.wim` (already ESD-converted if the source shipped
  an ESD), taken right after the first run's ISO copy and before anything mounts or mutates it. Reruns with
  `-UseSourceCache` restore from here instead of touching the ISO, so `-ISO` becomes unnecessary. Never
  written to except by `Initialize-SourceImage` populating or (`-RefreshSourceCache`) replacing it; not
  touched by `Invoke-Tiny11Cleanup`.
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
