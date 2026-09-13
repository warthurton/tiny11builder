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

`reference/winutil/`, `reference/tiny11-automated/`, `reference/tiny11builder-ntdevlabs/`,
`reference/rufus/`, `reference/UnattendedWinstall/`, and `reference/unattend-generator/` are git submodules of
other projects, kept under `reference/` purely for comparison/lookup (see `docs/script-comparison.md`, which
diffs this repo's ISO-building logic against winutil's `Invoke-WinUtilISOScript.ps1`). **Do not edit code
inside these submodules and don't treat them as part of this project's build/test surface.** They exist to
look up how another project solved something, not to be modified or kept in sync. If you add another external
project for reference, add it as a submodule under `reference/` too.

`reference/UnattendedWinstall/` ([memstechtips/UnattendedWinstall](https://github.com/memstechtips/UnattendedWinstall))
and `reference/unattend-generator/` ([cschneegans/unattend-generator](https://github.com/cschneegans/unattend-generator),
source for the [Windows Unattended Answer File Generator](https://schneegans.de/windows/unattend-generator/))
are both answer-file generators/tooling, added for a possible future integration of a proper
`autounattend.xml` generator/customizer in place of this repo's current approach (downloading ntdevlabs'
static template and string-patching it — see `Confirm-AutounattendXml`, `ConvertTo-Tiny11AnswerFile`, and the
other `Add-AnswerFile*`/`Initialize-PreparedAnswerFile` functions in `asl-win11.functions.ps1`). No such
integration exists yet; these are reference-only until that work happens.

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

To build several image variants (hardware checks fully enforced / Entra-join-ready / fully tweaked) from one
ISO in a single pass instead, use `asl-win11-multibuild.ps1` (see "Multi-profile builds" below) in place of
`asl-win11maker.ps1`:
```powershell
.\asl-win11-multibuild.ps1 -ISO E -SCRATCH D -Edition Pro
```

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
  folder; omitting it first looks for any already-extracted cache folder under
  `<SCRATCH>:\virtiocache\` (from a prior run's `Expand-VirtioIso`) and reuses the most recently written one
  with no network access, falling back to downloading the latest stable `virtio-win.iso` only when no cache
  exists. An `.iso` path (given or downloaded) is extracted via 7-Zip (`Expand-VirtioIso`) rather than
  mounted, into a persistent `<SCRATCH>:\virtiocache\<iso name>\` cache reused on reruns — no
  `Mount-DiskImage`/`Dismount-DiskImage` lifecycle to track, and nothing left mounted if a run crashes.
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
  Setup validates and auto-activates against it silently (`WillShowUI` forced to `Never`). Optional:
  `autounattend.xml` always carries a `UserData/ProductKey` element, because Windows Setup shows the
  blocking "Enter your product key" screen (and aborts the install if that screen is Cancelled) whenever the
  `ProductKey` element is absent entirely. Product-key precedence when `-ProductKey` isn't given
  (`Initialize-PreparedAnswerFile`):
  1. **Generic Volume License Key (GVLK)** for the detected edition (`Get-GenericVolumeLicenseKey`,
     `$script:editionId` from `Show-ImageMetadata`'s `/Get-CurrentEdition` call) — real, Microsoft-published
     per-edition keys intended to select an edition on a generic ISO and pass Setup's validation, without
     being a genuine license (see
     [learn.microsoft.com/windows-server/get-started/kms-client-activation-keys](https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys)).
     They don't activate Windows (no KMS host on the network to answer them — same "not activated" end state
     as no key at all) but they do satisfy Setup silently: `WillShowUI=Never` plus a GVLK validates
     successfully, giving a fully unattended product-key pass with no manual click. Windows 11 Home
     (`Core`/`CoreSingleLanguage`) has no GVLK — it was never sold as a volume-licensed SKU — so this always
     falls through to step 2 for Home.
  2. **Placeholder key fallback** (`reference/tiny11-automated`'s pattern) when the edition is undetected or
     has no GVLK: the placeholder key `00000-00000-00000-00000-00000` with `WillShowUI` set to `Always`.
     Not silent — Setup shows the product-key screen once, and you click "I don't have a product key" to
     continue. (An earlier attempt used a genuinely empty `<Key/>` with `WillShowUI` left untouched, matching
     Rufus's approach — `reference/rufus/src/wue.c:145-151` — but this repo's actual "Setup has failed to
     validate the product key" failures turned out to be unrelated to key formatting entirely; see the
     install.wim mount/unmount note above. The placeholder/`Always` fallback remains for editions with no
     GVLK, since it's a known-working pattern regardless.)

  `-ProductKey` only matters if you want automatic silent activation against a real license instead of the
  GVLK's silent-but-unactivated install.
- `-CompressionMode None|Fast|Max|Recovery` — DISM `/Export-Image /Compress` mode for the final install.wim
  (and, under `-Core`, the install.esd conversion). **Default is `Fast`** — matches the original tiny11
  scripts' hardcoded behavior. `Max` shrinks the image further at the cost of a much slower export;
  `Recovery` matches the WIMBoot-style compression Windows Setup's own install.esd uses (smallest, slowest);
  `None` skips recompression (largest, fastest — useful for quick local iteration).
- `-KeepCorporateApps` — keeps OneDrive, Outlook, Teams, and Copilot instead of removing/disabling them
  (carves their prefixes out of `$appPackagePrefixes` and skips `Remove-OneDriveSetup`, `Disable-ChatIcon`,
  `Disable-OneDriveSync`, `Disable-DevHomeOutlookInstall`, `Disable-Copilot`, `Disable-TeamsInstall`, and
  `Disable-NewOutlook`), and skips `Enable-LocalAccountOOBE` — even if `-LocalAccountName` is also given, it's
  ignored (with a warning; the running script's own `$LocalAccountName` variable is cleared) so OOBE offers
  its normal work/school account sign-in. Every other debloat/telemetry tweak still applies. Intended for an
  image meant to be joined to Microsoft Entra ID / enrolled via Autopilot or Intune. Used by
  `asl-win11-multibuild.ps1`'s `Entra` profile; rarely worth passing by hand otherwise.
- `-ProfileName <name>` — cosmetic tag folded into the output ISO's filename (`Get-Tiny11IsoNameTag`) and the
  build-info JSON's filename, so multiple runs sharing one `output\` folder don't overwrite each other. No
  effect on the build itself. Set automatically by `asl-win11-multibuild.ps1`; only useful by hand if you're
  scripting several manual runs against the same output folder yourself.

### Multi-profile builds — `asl-win11-multibuild.ps1`

A thin orchestrator, separate from `asl-win11maker.ps1`, for building several image variants from one source
ISO in a single invocation instead of re-running the builder by hand with different flags. It forwards almost
all of `asl-win11maker.ps1`'s parameters straight through and adds one of its own:

- `-Profiles <Standard|Entra|Optimized>[,...]` — which profiles to build (any order; always executed in
  `Standard`, `Entra`, `Optimized` order). Defaults to all three.

The three profiles:
- **Standard** — the regular debloated build, with `-BypassMode` forced to `None` regardless of what's
  passed to the orchestrator, so Setup's TPM/Secure Boot/RAM hardware checks stay fully enforced. This is
  deliberately the one build in the set that never bypasses hardware requirements.
- **Entra** — the same debloat/telemetry tweaks as Standard, plus `-KeepCorporateApps` (see above), for a
  build meant to be joined to Microsoft Entra ID / enrolled via Autopilot or Intune. Honors whatever
  `-BypassMode` was passed to the orchestrator (default `None`); ignores `-LocalAccountName`.
- **Optimized** — today's "everything on" build: whatever `-BypassMode`/`-LocalAccountName`/`-ProductKey` you
  pass are used as-is, no `-KeepCorporateApps`. Equivalent to calling `asl-win11maker.ps1` directly with those
  same flags.

Each profile runs as its own **separate `powershell.exe` child process** (not a dot-sourced call in-loop) —
`asl-win11maker.ps1` unconditionally `exit`s at the end of its top-level `try` block (and also `exit`s early
if it has to self-relaunch elevated), either of which would kill an in-process orchestrator loop too. The
orchestrator elevates itself once up front (`Confirm-AdminPrivileges`, reused from the function library) so
every child inherits an already-elevated token and its own elevation check is a no-op, instead of each child
racing off to relaunch itself in a detached window. Every child is also always run with `-UseSourceCache`
under the hood (not exposed as its own switch) so only the first profile that needs it touches the mounted
ISO or converts `install.esd`; the rest restore from the cache — this is what makes building three profiles
take roughly one ISO-extraction's worth of time instead of three. `-RefreshSourceCache`, if passed, is
applied only to the first profile actually built.

Each profile's own final "press Enter to continue" prompt (`Invoke-Tiny11Cleanup`) still applies — the
orchestrator doesn't suppress it, so you'll press Enter once per profile as each one finishes.

Cumulative-update slipstreaming (`DISM /Add-Package` against a downloaded `.msu`) was considered alongside
this feature but deliberately deferred — not implemented anywhere in this repo yet.

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
the ISO with `oscdimg` → clean up temp files, release the sleep-prevention request, and eject the source ISO
(skipped if this run used the source cache and never mounted one).

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
`$script:virtioRoot` — this is why these functions are dot-sourced rather
than imported as a module, and why they aren't safely callable standalone without the session having been
initialized first). `$script:autounattendTemplatePath` is set earlier than the rest, by
`Confirm-AutounattendXml` (which runs before `Initialize-Tiny11Session`) — it only needs
`$script:BuildScratchRoot`, set at the very top of `asl-win11maker.ps1` before the pipeline starts. They also
read the entry script's bound parameters directly by name (e.g. `$BypassMode`, `$Core`, `$INDEX`) via
PowerShell's normal scope inheritance — the same mechanism `$ISO`/`$SCRATCH` have always used — so a new
parameter is visible to every function without extra plumbing.

**Logging convention:** `Write-Log`/`Write-Phase` use `Write-Host`, not `Write-Output` — this is deliberate.
Several functions (`Resolve-VirtioDriverSource`, `Export-HostSystemDrivers`, etc.) `return` a value the
caller captures directly (e.g. `$script:virtioRoot = Resolve-VirtioDriverSource ...`); if their internal
logging used `Write-Output`, those log lines would land in the success stream and corrupt the captured
return value. `Start-Transcript` still captures `Write-Host` output, so nothing is lost. Follow this same
pattern in any new function that both logs and returns a value the caller captures.

**DISM logging convention:** every DISM invocation goes through `Invoke-Dism` (a thin `dism.exe` wrapper that
mirrors each output line into `$script:structuredLogPath`, prefixed `[DISM]`), *except* the three long-running
calls in `Complete-InstallImage` / `Export-CoreInstallEsd` (`/Cleanup-Image /ResetBase` and the two
`/Export-Image` calls) — those still invoke `dism.exe` directly so DISM's own progress output stays live in
the console/transcript instead of being buffered until the process exits. `Invoke-Dism` replaced several
call sites that previously piped to `| Out-Null` (silently discarding output) or only ever landed in a
variable for parsing (never logged anywhere); it returns the same line-array shape as a plain `& dism ...`
call, so existing `-split`/`Where-Object`/regex parsing on the result is unaffected.

**install.wim mount/unmount must use raw `dism.exe`, not the PowerShell `Mount-WindowsImage`/
`Dismount-WindowsImage -Save` cmdlets:** `Mount-InstallImage` and `Complete-InstallImage` use
`dism.exe /Mount-Image` and `dism.exe /Unmount-Image /Commit` instead. This was found the hard way:
isolation testing (bisecting driver injection, `ResetBase`, appx removal, and registry tweaks
individually, then a completely unedited mount+save, against real installs) traced a hard "Setup has
failed to validate the product key" failure specifically to `Dismount-WindowsImage -Save` corrupting
install.wim's edition/licensing metadata on commit — reproducible with zero content changes, independent
of single- vs multi-edition source WIMs. Swapping to raw `dism.exe` mount/commit resolved it. `boot.wim`
(`Update-BootImage`) still uses the PowerShell cmdlets and that's fine — the same no-op mount+save was
proven harmless there in the same testing, because Setup never consults boot.wim for edition/key matching,
only install.wim. Don't "clean up" install.wim's mount/unmount back to the PowerShell cmdlets even though
they're more idiomatic — it reintroduces this failure.

Loosely grouped:
- **Removal**: `Remove-ProvisionedAppPackages`, `Remove-Edge`, `Remove-OneDriveSetup`, `Remove-ScheduledTasks`,
  `Remove-IsoSupportFolder`; core-build-only: `Remove-SystemPackages`, `Remove-EdgeWebViewWinSxS`,
  `Remove-WindowsRecoveryEnvironment`, `Compress-WinSxS`, `Enable-DotNet35`
- **Answer file / edition**: `Get-GenericVolumeLicenseKey` (Windows 11 GVLK/KMS-client-key lookup table by
  DISM edition ID; no entry for Home/`Core`, which has no GVLK), `Get-AnswerFileChildElement`,
  `ConvertTo-Tiny11AnswerFile` (injects `/IMAGE/INDEX` and `UserData/AcceptEula` + `UserData/ProductKey`, so
  Setup's product-key screen never blocks the install; embeds whatever key the caller passes — real
  `-ProductKey`, a GVLK, or nothing — with `WillShowUI` forced to `Never` when there's a real key, else the
  tiny11-automated-style placeholder key `00000-00000-00000-00000-00000` with `WillShowUI` set to `Always`;
  see the `-ProductKey` parameter entry above for the full precedence chain and history),
  `Add-AnswerFileBypassCommands` (Rufus-style `Unattend` bypass mode),
  `Add-AnswerFileLocalAccount` (Rufus-style `-LocalAccountName` local account, password = account name),
  `Add-AnswerFileLocale` (embeds the mounted image's own detected UI language — `$script:languageCode` from
  `Show-ImageMetadata` — as `InputLocale`/`SystemLocale`/`UserLocale`/`UILanguage` in the oobeSystem pass's
  `Microsoft-Windows-International-Core` component, Rufus-style, so OOBE doesn't prompt for
  language/region/keyboard; skipped if the image's language couldn't be detected),
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
  (prepares `autounattend.xml` once, injecting the image index, product-key handling (`-ProductKey`), the
  detected image locale (`$script:languageCode`), and, when `-LocalAccountName` is given, the local account,
  so the Sysprep copy, ISO-root copy, and Unattend bypass mode never drift apart),
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
- `work\drivers\` (or `<SCRATCH>:\drivers\`) — staging for host-exported drivers and staged virtio drivers,
  when driver injection is used. Removed by `Invoke-Tiny11Cleanup` / `Invoke-Tiny11EmergencyCleanup` every
  run.
- `work\virtiocache\` (or `<SCRATCH>:\virtiocache\`) — only populated when `-InjectVirtioDrivers` is used: a
  downloaded `virtio-win.iso` (under `virtiocache\download\`, skipped on reruns once cached) and/or its
  `Expand-VirtioIso` extraction, keyed by the source `.iso`'s file name so a different virtio-win version
  gets its own cache folder. Like `sourcecache\`, never touched by `Invoke-Tiny11Cleanup` — survives across
  runs; delete it manually to force a re-download/re-extract.
- `logs/` — `Start-Transcript` output per run, plus a parallel structured log (`Write-Log`)
- `output/` — final built ISO lands here (`New-Tiny11Iso`), alongside `asl-win11-buildinfo.json`
  (`Write-BuildInfo`)

### External binaries
- `oscdimg.exe` — used to author the final bootable ISO. Sourced from the Windows ADK if installed at the
  standard path, otherwise downloaded from the Microsoft symbol server into the repo root and left there
  (not deleted by `Invoke-Tiny11Cleanup`) so reruns reuse the download instead of re-fetching it every time.
- `autounattend.xml` — unattended-setup answer file template (bypasses MSA requirement on OOBE, deploys with
  `/compact`). Lives under `$script:BuildScratchRoot` (`work\autounattend.xml` or `<SCRATCH>:\autounattend.xml`),
  not the repo root — auto-fetched from GitHub by `Confirm-AutounattendXml` if not already present there, and
  still deleted during `Invoke-Tiny11Cleanup`. `Initialize-PreparedAnswerFile` reads this template and writes
  the per-run, index/product-key/local-account-injected copy to `$script:tiny11Root\autounattend.xml` (already
  a work-directory path) for the actual ISO.
- `virtio-win.iso` — only fetched when `-InjectVirtioDrivers` is used without `-VirtioIso`; downloaded from
  `fedorapeople.org` into the scratch `virtiocache\download\` folder (cached across runs), not the repo root.
- `7z.exe` (7-Zip) — used to extract virtio-win `.iso` sources instead of mounting them (`Expand-VirtioIso`).
  Resolved from `PATH` or the standard `C:\Program Files\7-Zip\` install location; must already be installed
  (not auto-downloaded) — install it from https://www.7-zip.org/ if missing, or pass `-VirtioIso` pointing at
  an already-extracted driver folder to bypass it entirely.

### Reference docs
- `docs/script-comparison.md` — the four-way (ntdevlabs / tiny11-automated / winutil / Rufus) feature
  comparison this combined-builder work was derived from.
- `docs/tweak-catalog.md` — the full inventory of app package prefixes, scheduled tasks, and registry tweaks
  across all four tools, with what this repo applies by default vs. ships commented-out vs. deliberately
  doesn't port.
