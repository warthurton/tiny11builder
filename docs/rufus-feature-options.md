# Rufus Unattend Feature Options

Inventory of every `UNATTEND_*` flag Rufus can set (`reference/rufus/src/rufus.h`, generated in
`reference/rufus/src/wue.c:CreateUnattendXml`), what this repo already does that overlaps, and which of the
rest are worth adding later. Written up after implementing `-LocalAccountName` (which ports Rufus's
`UNATTEND_SET_USER`, see below) so the rest of the comparison doesn't get lost.

## Already covered by this repo

| Rufus flag | What it does | This repo's equivalent |
| --- | --- | --- |
| `UNATTEND_SECUREBOOT_TPM_MINRAM` | `reg add` bypass for Secure Boot/TPM/RAM checks during Setup | `-BypassMode Unattend` (`Add-AnswerFileBypassCommands`) — also offers `Hive` and `Both`, which Rufus doesn't |
| `UNATTEND_NO_ONLINE_ACCOUNT` | Skip MSA/online-account requirement (`BypassNRO`) | `Enable-LocalAccountOOBE` |
| `UNATTEND_SET_USER` | Create a local account so OOBE doesn't require an MSA | `-LocalAccountName` (`Add-AnswerFileLocalAccount`) — see "Different from Rufus" below |
| `UNATTEND_DISABLE_BITLOCKER` (partial) | `PreventDeviceEncryption` | `Disable-BitLockerAutoEncryption` — Rufus also sets `TCGSecurityActivationDisabled`, which we don't yet (see below) |
| `UNATTEND_QOL_ENHANCEMENTS` (partial) | Remove OneDrive/Outlook/Teams, disable Copilot | `Remove-OneDriveSetup`, `Disable-OneDriveSync`, `Disable-TeamsInstall`, `Disable-DevHomeOutlookInstall`, `Disable-Copilot` — Rufus bundles a few more QoL tweaks we don't have (see below) |

### Different from Rufus: `-LocalAccountName` password handling

Rufus's `UNATTEND_SET_USER` sets a blank password (via the magic Base64-encoded UTF-16 string
`"Password"`, which Windows interprets as "no password"), then runs
`net user "<name>" /logonpasswordchg:yes` as a first-logon command to force a password change, plus
`net accounts /maxpwage:unlimited` to stop the forced change from also resetting the expiry policy.

`-LocalAccountName` instead sets the account's password to the same value as its name, in plain text
(`<PlainText>true</PlainText>`), by explicit choice — no password generation, storage, or first-logon
command handling needed. Trade-off: the password is exactly the (public) account name, which is fine for a
disposable/dev/VM image but should never be used for anything reachable by an untrusted network or user.

## Not implemented — candidates for later

Ranked roughly by effort-to-value.

### 1. `UNATTEND_DUPLICATE_LOCALE` — match the build PC's regional settings
Copies the *building* machine's timezone, keyboard layout (`InputLocale`), system locale, user locale, and
UI-language-fallback into the target image's `oobeSystem` pass, instead of shipping generic `en-US`
defaults. Straightforward: same namespace-aware-XML pattern as `Add-AnswerFileLocalAccount`, values read from
`Get-TimeZoneInformation`/`Get-Culture`/registry (`reference/rufus/src/wue.c:335-343,462-478`). Low effort,
likely useful if you build images for yourself rather than for redistribution.

### 2. More `UNATTEND_QOL_ENHANCEMENTS` first-logon tweaks
Rufus's QoL bundle does a few things we don't have equivalents for yet (`reference/rufus/src/wue.c:398-446`):
- Disable Fast Startup (`HiberbootEnabled=0`)
- Disable News and Interests widgets (`AllowNewsAndInterests=0`, `EnableFeeds=0`)
- Hide Edge's first-run dialog (`HideFirstRunExperience=1`)
- A few more Start-menu pins by default

Each is a one-line `Set-RegistryValue` call in the existing `Disable-*` style; could fold into existing
functions (e.g. `Disable-Copilot` already touches similar taskbar/search keys) or a new
`Enable-QualityOfLifeTweaks` grouping function. Low effort per item.

### 3. `UNATTEND_NO_DATA_COLLECTION` — skip OOBE privacy/EULA screens
`HideEULAPage`, `ProtectYourPC=3` (declines diagnostic data during OOBE), and (for fully silent/offline
installs) `HideWirelessSetupInOOBE` (`reference/rufus/src/wue.c:319-334`). Also namespace-aware-XML, same
shape as the local-account block. Medium value — mostly matters if you want OOBE to require zero clicks.

### 4. `TCGSecurityActivationDisabled` for `Disable-BitLockerAutoEncryption`
Rufus's BitLocker-disable also sets `Microsoft-Windows-EnhancedStorage-Adm`'s
`TCGSecurityActivationDisabled=1` (`reference/rufus/src/wue.c:487-491`) in addition to
`PreventDeviceEncryption`, which is all `Disable-BitLockerAutoEncryption` currently sets. Trivial one-line
registry addition (or a matching `oobeSystem` component if we want it via answer file instead of hive edit).

### 5. `UNATTEND_APPLY_SKUSIPOLICY` — reapply `SkuSiPolicy.p7b` post-install
Narrow fix for a specific Secure Boot certificate-revocation edge case
(`reference/rufus/src/wue.c:392-397`, see https://support.microsoft.com/kb/5042562). Low priority unless you
hit the specific `0xc0000428` boot signature error this addresses.

## Not applicable to this project

These are about Rufus's own USB-installer mechanics — partitioning a *target* disk during Setup, offlining
other drives, or building Windows-To-Go media — none of which apply here, since this project bakes changes
into `install.wim`/`boot.wim` for an ISO rather than driving Setup's disk-partitioning behavior:
- `UNATTEND_OFFLINE_INTERNAL_DRIVES` (`SanPolicy=4`)
- `UNATTEND_FORCE_S_MODE`
- `UNATTEND_SILENT_INSTALL` (disk creation/partitioning steps)
- `UNATTEND_USE_MS2023_BOOTLOADERS` / `UNATTEND_WINDOWS_TO_GO`
