# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

PowerShell scripts that build a trimmed-down Windows 11 install ISO (a "tiny11"-style image): mount a real
Windows 11 ISO, strip bloat (provisioned apps, scheduled tasks, Edge, OneDrive, telemetry), apply registry
tweaks, then repackage everything into a new bootable ISO with `oscdimg.exe`. There are two variants:

- **`asl-win11maker.ps1`** — the regular, serviceable build (can still take Windows Update/features/languages
  post-install). This is the actively maintained, modularized script.
- **`asl-win11-coremaker.ps1`** — the "core" build: strips even WinSxS/Windows Update/WinRE for a
  non-serviceable, disposable testbed image (e.g. for VMs). This script is still monolithic/legacy-style and
  has **not** been modularized the way `asl-win11maker.ps1` has — keep that in mind when editing it; don't
  assume it shares helpers with the functions library unless you check.

Both scripts must run on Windows, under PowerShell 5.1, elevated (they self-relaunch as admin if not), with a
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

There is no automated test suite — the scripts mutate a real Windows image and require admin rights plus a
multi-GB ISO, so correctness is validated by syntax check + lint + manual runs, not unit tests.

## Architecture

### `asl-win11maker.ps1` — entry point / orchestrator
Thin runner: dot-sources `asl-win11.functions.ps1`, then calls a **linear, ordered pipeline** of functions.
Each call is annotated `REQUIRED` (core pipeline step — don't reorder/remove) or `OPTIONAL` (a specific
removal/tweak — safe to comment out to keep that feature in the final image). When adding a new tweak,
follow this pattern: implement it as a function in the functions library, then add one `OPTIONAL`-tagged call
in the appropriate phase of this pipeline.

The pipeline shape is: resolve/validate ISO source → copy source media into scratch → mount `install.wim` →
remove provisioned app packages → load offline registry hives → apply registry tweaks → unload hives →
DISM component cleanup + recovery-compressed export → apply hardware-bypass tweaks to `boot.wim` → build the
ISO with `oscdimg` → clean up temp files and eject the source ISO.

Two arrays near the top of the script — `$appPackagePrefixes` and `$scheduledTaskPaths` — are the primary
customization surface: comment out an entry to keep that package/task in the final image instead of touching
the pipeline logic.

### `asl-win11.functions.ps1` — function library
All reusable logic, dot-sourced into the caller's scope (functions read/write `$script:`-scoped state set up
by `Initialize-Tiny11Session`, e.g. `$script:mountDir`, `$script:tiny11Root`, `$script:installWimPath`,
`$script:bootWimPath`, `$script:DriveLetter`, `$script:index`, `$script:adminGroupName` — this is why these
functions are dot-sourced rather than imported as a module, and why they aren't safely callable standalone
without the session having been initialized first). Loosely grouped:
- **Removal**: `Remove-ProvisionedAppPackages`, `Remove-Edge`, `Remove-OneDriveSetup`, `Remove-ScheduledTasks`
- **Registry/behavior tweaks**: `Disable-*` / `Enable-*` functions (telemetry, Copilot, Teams, sponsored apps,
  reserved storage, BitLocker auto-encryption, OneDrive sync, new Outlook, Dev Home/Outlook install, etc.),
  plus `Set-BypassHardwareChecks`
- **Session/orchestration**: `Confirm-ExecutionPolicy`, `Confirm-AdminPrivileges` (self-elevate), 
  `Confirm-AutounattendXml` (downloads it from the upstream `ntdevlabs/tiny11builder` GitHub repo if missing
  locally), `Initialize-Tiny11Session`, `Resolve-SourceDriveLetter`, `Confirm-InstallWimSource` (handles
  ESD→WIM conversion), `Copy-SourceImageFiles`, `Select-InstallImageIndex`, `Mount-InstallImage`,
  `Show-ImageMetadata`, `Mount-OfflineRegistryHives` / `Dismount-OfflineRegistryHives`,
  `Complete-InstallImage`, `Set-BootImageBypassTweaks`, `New-Tiny11Iso`, `Invoke-Tiny11Cleanup`

### Working directories (all gitignored)
- `work/` — default scratch build root (source copy, mounted image contents) when `-SCRATCH` isn't given
- `logs/` — `Start-Transcript` output per run
- `output/` — final built ISO lands here (`New-Tiny11Iso`)

### External binaries
- `oscdimg.exe` — used to author the final bootable ISO. Sourced from the Windows ADK if installed at the
  standard path, otherwise downloaded from the Microsoft symbol server into the repo root and deleted again
  during `Invoke-Tiny11Cleanup`.
- `autounattend.xml` — unattended-setup answer file (bypasses MSA requirement on OOBE, deploys with
  `/compact`). Auto-fetched from GitHub if not present locally; also deleted during cleanup.
