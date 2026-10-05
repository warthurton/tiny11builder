# Build Options Reference: Every Tweak, Organized by Option

`docs/tweak-catalog.md` and `docs/script-comparison.md` organize this repo's tweaks **by source tool**
("this repo vs. ntdevlabs vs. tiny11-automated vs. winutil"). This document organizes the *same* tweaks a
different way: **by the `asl-win11maker.ps1`/`asl-win11-multibuild.ps1` option that turns them on**, so you
can look at one CLI flag (or one multi-build profile) and see everything it actually does, when it happens,
and where the implementation came from. Every row here is a pointer, not a re-description — full detail
lives in `docs/tweak-catalog.md` (packages/tasks/registry), `CLAUDE.md` (parameters/architecture), or
`docs/answer-file-generators-options.md` / `docs/rufus-feature-options.md` (answer-file technique sourcing).

Current as of the 2026-10-05 pipeline (`asl-win11maker.ps1` lines 190–403); re-check this doc's line
references if the pipeline is reordered.

## Taxonomy

Three independent dimensions, used consistently across every table below:

**Category** — what kind of thing is being changed:
| Category | Examples |
| --- | --- |
| Packages | Provisioned appx/MSIX removal, Core-only CBS/FoD system packages |
| Scheduled Tasks | Telemetry/CEIP/WU task-definition file deletion |
| Registry & Policy | `Disable-*`/`Enable-*`/`Set-*` offline hive edits |
| Services | Service `Start` value changes (folded into several `Disable-*` functions, not a separate category in code) |
| Files & Components | WinSxS/Defender/WinRE/Edge-WebView file-level removal, `.NET 3.5` enablement |
| Drivers | install.wim driver injection, `$WinpeDriver$` staging, boot.wim |
| Answer-File & OOBE Behavior | Product key, locale, local account, hardware-bypass `reg add` commands, edition pinning |

**Phase** — *when* the change takes effect, independent of category:
| Phase | What it means | Who in this repo's ecosystem uses it |
| --- | --- | --- |
| **Offline pre-boot** | DISM mounts `install.wim`/`boot.wim`, the pipeline edits the mounted files/hives directly, DISM commits and unmounts — done before the ISO is even built | This repo's default approach for nearly everything (packages, tasks, most registry tweaks, drivers, file/component removal) |
| **Setup-time declarative** | A plain `<Component>` value in `autounattend.xml` that Windows Setup itself reads and applies — no script runs | This repo's product key, locale (`Add-AnswerFileLocale`), local account (`Add-AnswerFileLocalAccount`), edition index injection |
| **Setup-time embedded script** | A PowerShell (or `reg add`) command embedded in `autounattend.xml` via `RunSynchronousCommand`/`RunAsynchronousCommand`, executed live during a Setup pass (windowsPE, specialize, or oobeSystem) | This repo's `-BypassMode Unattend`/`Both` (`Add-AnswerFileBypassCommands`); `UnattendedWinstall` and `unattend-generator` use this for *everything* including package removal — see `docs/answer-file-generators-options.md` |
| **Post-OOBE first-logon** | Needs an actual logged-on user/session context, so it can only run after OOBE finishes — a scheduled task or RunOnce entry | This repo's `Install-VirtioGuestToolsAtFirstLogon` |

**Mechanism** — *how* it's technically done: DISM API (`Invoke-Dism`/`dism.exe`) · offline registry hive
mount (`Mount-OfflineRegistryHives` + `Set-RegistryValue`) · raw file ops (`Remove-Item`/`takeown`/`icacls`)
· answer-file XML component · answer-file embedded script · scheduled task definition file.

---

## Default serviceable build (no switches)

Always-on `REQUIRED`/active-`OPTIONAL` tweaks from `asl-win11maker.ps1` lines 336–392 with no switches set.

| Item | Category | Phase | Mechanism | Source |
| --- | --- | --- | --- | --- |
| Provisioned app package removal (49 active of 63 prefixes) | Packages | Offline pre-boot | DISM `Remove-AppxProvisionedPackage` | `docs/tweak-catalog.md` §1 |
| `Remove-OneDriveSetup` | Files & Components | Offline pre-boot | Raw file ops (`takeown`/`icacls` + delete) | `docs/script-comparison.md` §1 (OneDrive removal row); ntdevlabs technique |
| `Remove-IsoSupportFolder` | Files & Components | Offline pre-boot | Raw file ops | winutil (`docs/script-comparison.md` §4 item 4) |
| `Invoke-HardwareBypassStrategy` | Answer-File & OOBE Behavior | *(no-op — default `-BypassMode None`)* | — | — |
| `Disable-SponsoredApps` | Registry & Policy | Offline pre-boot | Offline hive mount | ntdevlabs — `docs/tweak-catalog.md` §3 |
| `Enable-LocalAccountOOBE` | Answer-File & OOBE Behavior | Setup-time embedded script (`BypassNRO`) | Offline hive mount for the image-side half + answer-file `reg add` | Rufus `UNATTEND_NO_ONLINE_ACCOUNT` — `docs/rufus-feature-options.md` |
| `Disable-ReservedStorage` | Registry & Policy | Offline pre-boot | Offline hive mount | ntdevlabs |
| `Disable-BitLockerAutoEncryption` | Registry & Policy | Offline pre-boot | Offline hive mount | ntdevlabs (Rufus also sets `TCGSecurityActivationDisabled`, not yet ported — `docs/rufus-feature-options.md` §4) |
| `Disable-Telemetry` | Registry & Policy | Offline pre-boot | Offline hive mount | ntdevlabs |
| `Disable-ChatIcon` | Registry & Policy | Offline pre-boot | Offline hive mount | ntdevlabs |
| `Disable-OneDriveSync` | Registry & Policy | Offline pre-boot | Offline hive mount | ntdevlabs |
| `Disable-DevHomeOutlookInstall` | Registry & Policy | Offline pre-boot | Offline hive mount | ntdevlabs |
| `Disable-Copilot` | Registry & Policy | Offline pre-boot | Offline hive mount | ntdevlabs |
| `Disable-TeamsInstall` | Registry & Policy | Offline pre-boot | Offline hive mount | ntdevlabs |
| `Disable-NewOutlook` | Registry & Policy | Offline pre-boot | Offline hive mount | ntdevlabs |
| Scheduled task removal (5 active of 11 paths) | Scheduled Tasks | Offline pre-boot | Delete task definition `.xml` files | `docs/tweak-catalog.md` §2 |
| Product key / GVLK / edition index | Answer-File & OOBE Behavior | Setup-time declarative | Answer-file XML (`ConvertTo-Tiny11AnswerFile`) | winutil's `ConvertTo-WinUtilISOAnswerFile` pattern, extended — `docs/script-comparison.md` §4 item 2 |
| Locale injection (`Add-AnswerFileLocale`) | Answer-File & OOBE Behavior | Setup-time declarative | Answer-file XML | Rufus `UNATTEND_DUPLICATE_LOCALE`-style — `docs/rufus-feature-options.md` §1 |
| `Set-Tiny11EditionConfig` (ei.cfg/PID.txt) | Answer-File & OOBE Behavior | Offline pre-boot (writes to ISO content tree) | Raw file ops | winutil `Write-WinUtilISOEditionConfig` — `docs/script-comparison.md` §4 item 3 |

**Commented out by default** (safe to uncomment, no code change needed): `Microsoft.MPEG2VideoExtension`,
`Microsoft.Recall`/`Microsoft.Windows.Recall`, `Microsoft.ScreenSketch`, `Microsoft.StorePurchaseApp`,
`Microsoft.WebMediaExtensions`, `Microsoft.Windows.AI`/`AIFabric`/`CoreAI`, `Microsoft.Windows.Photos`,
`MicrosoftWindows.Client.WebExperience` (packages — `docs/tweak-catalog.md` §1); the 6 winutil WU-task paths
(scheduled tasks — §2); `Disable-WindowsUpdate`, `Disable-DiagnosticServices`, `Disable-WindowsAI` (registry
— §3).

---

## `-Core`

Everything in the default build above, **plus**:

| Item | Category | Phase | Mechanism | Source |
| --- | --- | --- | --- | --- |
| `Remove-SystemPackages` (CBS/FoD packages) | Packages | Offline pre-boot | DISM `/Remove-Package` | asl-win11-coremaker.ps1 lineage, folded into `-Core` — `CLAUDE.md` |
| `Enable-DotNet35` (if confirmed) | Files & Components | Offline pre-boot | DISM `/Enable-Feature` from source media | asl-win11-coremaker.ps1 lineage |
| `Remove-EdgeWebViewWinSxS` | Files & Components | Offline pre-boot | DISM WinSxS package removal | tiny11-automated (WinSxS Edge-WebView removal — `docs/script-comparison.md` §1 Edge row) |
| `Remove-WindowsRecoveryEnvironment` | Files & Components | Offline pre-boot | Raw file ops + BCD edits | asl-win11-coremaker.ps1 lineage — *see tiny11-automated's `8bde4bd` WinRE staging fix, `docs/script-comparison.md` §4 item 9, unevaluated against this function* |
| `Compress-WinSxS` | Files & Components | Offline pre-boot | DISM `/StartComponentCleanup` variant | asl-win11-coremaker.ps1 lineage |
| `Remove-Edge` | Files & Components | Offline pre-boot | Raw file ops + registry | ntdevlabs/tiny11-automated — `docs/script-comparison.md` §1 Edge row |
| `Disable-WindowsUpdate` | Registry & Policy | Offline pre-boot | Offline hive mount | Merged asl-win11-coremaker.ps1 + winutil — `docs/tweak-catalog.md` §3 |
| `Disable-WindowsDefender` | Registry & Policy | Offline pre-boot | Offline hive mount | asl-win11-coremaker.ps1 lineage |
| `Set-BootImageSetupCmdLine` | Registry & Policy (boot.wim) | Offline pre-boot | Offline hive mount on boot.wim | asl-win11-coremaker.ps1 lineage |
| Export to install.esd instead of install.wim | — (export format) | Offline pre-boot | DISM `/Export-Image` | asl-win11-coremaker.ps1 lineage |

Trade-off this option exists to document: **non-serviceable** — cannot take Windows Update, add
features/languages, or use Windows Recovery afterward. Disposable/testbed images only.

---

## `-BypassMode <None|Hive|Unattend|Both>`

Hardware-check bypass is the one axis implemented as **alternative mechanisms for the same 5 keys**, not
alternative tweaks:

| Mode | Phase | Mechanism | Source |
| --- | --- | --- | --- |
| `None` (default) | — | No-op. Setup enforces TPM/Secure Boot/RAM checks normally. | Deliberate behavior change from pre-combined-builder scripts — `CLAUDE.md` |
| `Hive` | Offline pre-boot | `Set-BypassHardwareChecks` edits install.wim + boot.wim offline hives directly | ntdevlabs/tiny11-automated (identical key set) |
| `Unattend` | Setup-time embedded script | `Add-AnswerFileBypassCommands` emits `reg add` as `RunSynchronousCommand` in `autounattend.xml` | Rufus `wue.c` `UNATTEND_SECUREBOOT_TPM_MINRAM` — `docs/rufus-feature-options.md` §1. **Note:** `unattend-generator`'s `BypassModifier` (`modifier/Bypass.cs`) does the same 3-key subset (`BypassTPMCheck`/`BypassSecureBootCheck`/`BypassRAMCheck`) in the windowsPE pass — confirms the technique independently, but doesn't cover this repo's extra 2 keys (`AllowUpgradesWithUnsupportedTPMOrCPU` + notification-cache suppression). |
| `Both` | Both of the above | Both | — |

The 5 keys themselves: `BypassTPMCheck`, `BypassSecureBootCheck`, `BypassRAMCheck`,
`BypassStorageCheck`, `BypassCPUCheck` (all `HKLM\SYSTEM\Setup\LabConfig`) plus
`AllowUpgradesWithUnsupportedTPMOrCPU` and notification-cache suppression — `docs/tweak-catalog.md` §3.

This is also the **hardware compatibility** axis referenced in the settings-strategy doc, together with
driver injection below.

---

## `-KeepCorporateApps`

| Item | Category | Phase | Mechanism | Source |
| --- | --- | --- | --- | --- |
| Carves `Microsoft.Copilot`/`Microsoft.Windows.Copilot`/`Microsoft.Windows.Teams`/`MSTeams`/`MicrosoftTeams`/`Microsoft.OutlookForWindows` out of the removal list | Packages | Offline pre-boot | Array filter before `Remove-ProvisionedAppPackages` runs | This repo, ad hoc |
| Skips `Remove-OneDriveSetup` | Files & Components | — (skipped) | — | This repo |
| Skips `Disable-ChatIcon`/`Disable-OneDriveSync`/`Disable-DevHomeOutlookInstall`/`Disable-Copilot`/`Disable-TeamsInstall`/`Disable-NewOutlook` | Registry & Policy | — (skipped) | — | This repo |
| Skips `Enable-LocalAccountOOBE` (even if `-LocalAccountName` given — warns, clears the var) | Answer-File & OOBE Behavior | — (skipped, so OOBE offers Entra/work-account sign-in) | — | This repo |

Every other debloat/telemetry tweak in the default build still applies. Intended for Entra ID /
Autopilot / Intune-enrolled images — this is the **account mode = Online** axis.

---

## `-LocalAccountName <name>`

| Item | Category | Phase | Mechanism | Source |
| --- | --- | --- | --- | --- |
| `Add-AnswerFileLocalAccount` | Answer-File & OOBE Behavior | Setup-time declarative (`<UserAccounts><LocalAccounts>`) | Answer-file XML | Rufus `UNATTEND_SET_USER` — `docs/rufus-feature-options.md` ("Different from Rufus" section documents this repo's plaintext-password choice vs. Rufus's blank-password + forced-change) |

This is the **account mode = Local** axis. Security footnote carried over from `CLAUDE.md`: the password
equals the account name in plaintext. Per `docs/answer-file-generators-options.md`'s sensitive-file finding,
that plaintext (plus `-ProductKey`, if given) used to be left readable in `C:\Windows\Panther\unattend.xml`
and `Windows\System32\Sysprep\autounattend.xml` on the installed system with no cleanup — **now fixed** via
`Remove-SensitiveAnswerFilesAtFirstLogon`, a RunOnce entry (staged whenever `Enable-LocalAccountOOBE` runs,
i.e. every build except `-KeepCorporateApps`) that deletes all three known copies at first logon. See
`docs/optimization-checklists.md`.

---

## `-InjectSystemDrivers` / `-DriverPath <folder>` / `-InjectVirtioDrivers [-VirtioIso <path>]`

| Item | Category | Phase | Mechanism | Source |
| --- | --- | --- | --- | --- |
| `Export-HostSystemDrivers` (host drivers only) | Drivers | Offline pre-boot (host export happens at build time) | `Export-WindowsDriver -Online` on the build machine | winutil `-InjectCurrentSystemDrivers` — `docs/script-comparison.md` §4 item 7 |
| `Add-DriversToImage` (install.wim, full driver set) | Drivers | Offline pre-boot | DISM `/Add-Driver /Recurse` | winutil, same item |
| `Add-WinPEStorageDrivers` (storage-class subset → `$WinpeDriver$` at ISO root) | Drivers | Offline pre-boot (ISO content staging; Setup loads it live during its own windowsPE pass) | Raw file copy, auto-loaded by Setup | Ported from winutil's `Add-WinUtilISOStagedDrivers`, confirmed via KB2686316 — `CLAUDE.md` |
| `Resolve-VirtioDriverSource` / `Add-VirtioDriversToImage` | Drivers | Offline pre-boot | DISM `/Add-Driver`, 7-Zip extraction instead of mount | This repo, went beyond winutil's scope per `docs/script-comparison.md` §4 item 7 |
| `Install-VirtioGuestToolsAtFirstLogon` | Drivers (guest tools) | **Post-OOBE first-logon** | Scheduled task / first-logon script | This repo |

**Remediated** (finding from the 2026-10-05 submodule refresh — see `docs/script-comparison.md`'s candidate
#10 for the original writeup): winutil's `abcbc23` fix ("inject Setup storage into boot.wim") found that its
filename-based storage-driver heuristic (`iaahci|iastor|vmd|irst|rst`) let non-storage "RST companion" INFs
slip into `$WinpeDriver$` as false positives, and that `$WinpeDriver$` staging alone wasn't a sufficient
delivery path — it now *also* mounts boot.wim index 2 and injects the SCSIAdapter/HDC driver packages
directly via DISM. Both halves of that fix are now ported here:
- `Test-StorageDriverInf` no longer has a filename fallback (this repo's version additionally covered
  `viostor|vioscsi|nvme` for virtio/NVMe) — it matches only the INF's own `Class=SCSIAdapter|HDC` directive,
  same as winutil's narrowed check.
- `Update-BootImage` now re-injects the already-staged `$WinpeDriver$` folder into boot.wim directly via
  `Add-DriversToImage` (DISM `/Add-Driver /Recurse`) right after mounting, reusing the exact
  already-storage-filtered package set rather than bloating boot.wim with a full driver-source rescan.

`$WinpeDriver$` staging (via KB2686316 auto-load) remains the primary mechanism; the boot.wim injection is
a second delivery path for the same packages. Still worth a real-hardware/VM boot test after relying on
`-InjectSystemDrivers`/`-DriverPath`/`-InjectVirtioDrivers` for an unusual storage controller — this closes
the known false-positive-matching gap, it doesn't guarantee every possible controller's INF is well-formed.

This is the other half of the **hardware compatibility** axis (alongside `-BypassMode`).

---

## `asl-win11-multibuild.ps1` profiles

Each profile is a different combination of the options above, run as a separate `asl-win11maker.ps1`
child process:

| Profile | `-BypassMode` | `-KeepCorporateApps` | Everything else |
| --- | --- | --- | --- |
| **Standard** | Forced `None` regardless of orchestrator input | No | Default build, as above |
| **Entra** | Whatever the orchestrator was given (default `None`) | Yes | Default build + `-KeepCorporateApps` effects above; ignores `-LocalAccountName` |
| **Optimized** | Whatever was given | No | Whatever `-LocalAccountName`/`-ProductKey`/driver switches were given, used as-is |

All three always run with `-UseSourceCache` under the hood so only the first profile touches the mounted
ISO. See `CLAUDE.md`'s "Multi-profile builds" section for the full parameter-forwarding details.

---

## See also

- `docs/tweak-catalog.md` — per-tweak four-way source comparison (packages/tasks/registry detail).
- `docs/script-comparison.md` — tool-level architecture comparison, plus the two new candidates from the
  2026-10-05 submodule refresh.
- `docs/answer-file-generators-options.md` — the phase taxonomy's "Setup-time embedded script" technique,
  sourced from `UnattendedWinstall`/`unattend-generator`.
- `docs/rufus-feature-options.md` — Rufus-sourced answer-file techniques.
- `docs/settings-config-strategy.md` — how this option-first view maps onto a proposed config-file/profile
  system (package aggressiveness, account mode, hardware compatibility as three independent axes).
- `docs/optimization-checklists.md` — decision checklists built from this document.
