# Optimization Checklists

Practical, literal checklists for picking a build configuration and verifying the result. These are the
human-facing version of the three settings-group axes from `docs/settings-config-strategy.md`
(package aggressiveness, account mode, hardware compatibility) plus the other parameters you actually have
to decide on every build. Print this one (see `docs/pdf/`) and tick through it while running a build.

## 1. Package-aggressiveness profile

- [ ] Is this image for yourself/personal use, where you'd rather uninstall something later than be
      missing it? → **Normal** (`config/examples/profiles/packages.normal.ps1` — removes only unambiguous
      OEM/Xbox/gaming bloat, keeps Mail/Calendar/Maps/Camera/Sticky Notes/To Do/Copilot/Teams/Outlook)
- [ ] Is this today's actual default behavior what you want (a solid debloat, nothing experimental)? →
      **Reduced** (`packages.reduced.ps1` — matches `asl-win11maker.ps1`'s out-of-the-box
      `$appPackagePrefixes`, 49 prefixes)
- [ ] Do you want the most stripped-down consumer image possible, including today's commented-out AI/
      Recall-era/Photos/Widgets removals? → **Minimal** (`packages.minimal.ps1`)
- [ ] Will this image join Entra ID / be enrolled via Autopilot or Intune, and does it need Teams/Outlook/
      OneDrive/Copilot kept for that workflow? → **Corporate** (`packages.corporate.ps1`, equivalent to
      today's `-KeepCorporateApps`) — remember this also means **Online** account mode below, not Local
- [ ] If none of the four quite fit: pick the closest profile, then hand-add/remove individual prefixes —
      every item is a single array entry, see `docs/tweak-catalog.md` §1 for what each one is

## 2. Account mode

- [ ] Is this a disposable/dev/VM/test image that only you (or people you trust with shell access) will
      ever log into? → **Local** (`-LocalAccountName <name>`) — but first:
  - [ ] Confirmed this image will **never** be reachable by an untrusted network or user — the account
        password equals the account name in plaintext (`CLAUDE.md`'s documented trade-off)
  - [ ] Aware that `C:\Windows\Panther\unattend.xml` on the installed system will contain that plaintext
        password (and your product key, if `-ProductKey` was given) with no automatic cleanup today — see
        `docs/answer-file-generators-options.md`'s sensitive-file finding. Until a cleanup step is added,
        manually wipe `C:\Windows\Panther\` after first boot if this matters for your use case.
- [ ] Is this image meant for Microsoft/Entra account sign-in, Autopilot, or Intune enrollment? → **Online**
      (default behavior, or `-KeepCorporateApps` if you also want corporate apps kept)
- [ ] Don't pass `-LocalAccountName` to a `-KeepCorporateApps` build — it's silently ignored with a warning
      (`CLAUDE.md`), so set your expectations before the build, not after

## 3. Hardware-compatibility strategy

- [ ] Is the target hardware fully TPM 2.0 / Secure Boot / RAM compliant (or you don't know the target and
      want to keep Setup's own checks as a safety net)? → **StrictCompliant** (`-BypassMode None`, the
      default — and the only option `asl-win11-multibuild.ps1`'s **Standard** profile allows)
- [ ] Is the target hardware/VM known to fail one of Setup's checks, but has an ordinary storage
      controller Setup already sees fine? → **BypassOffline** (`-BypassMode Hive` or `Both`, no driver
      injection)
- [ ] Does the target have an unusual storage controller (RAID/RST, NVMe RAID, a VM's virtio disk) that
      Setup can't see without help? → **BypassAndDrivers** (`-BypassMode Both` + `-InjectSystemDrivers`/
      `-DriverPath`/`-InjectVirtioDrivers` as appropriate) — but first:
  - [ ] Read `docs/build-options-reference.md`'s "Known risk, not yet remediated" note on the storage-driver
        INF heuristic (winutil `abcbc23`) before trusting this for an uncommon controller — test boot on
        real/representative hardware, don't assume success from a clean build log alone
- [ ] Building for a fleet with mixed/unknown hardware? Consider `asl-win11-multibuild.ps1` to produce
      Standard + your bypass variant in one pass instead of guessing once

## 4. Pre-build checklist (today's actual parameters)

- [ ] `-Edition <name>` or `-INDEX <n>` decided? (omitting both prompts interactively — fine for a one-off,
      inconvenient for a repeatable/scripted build)
- [ ] `-CompressionMode` decided — `Fast` (default) for iteration, `Max` for a final distributable image,
      `None` for the fastest possible local rebuild while testing other changes
- [ ] `-UseSourceCache` passed if you expect to rerun this build multiple times while tuning tweaks/drivers
      — avoids re-extracting the ISO and re-converting install.esd every run
- [ ] Driver source decided and reachable: host export (`-InjectSystemDrivers`), a specific folder
      (`-DriverPath`), and/or virtio (`-InjectVirtioDrivers`, with `-VirtioIso` if you don't want the
      auto-download/auto-detect-cache behavior)
- [ ] Product key decided: a real `-ProductKey` for silent activation, or accept the GVLK/placeholder
      fallback (`CLAUDE.md`'s precedence chain) — remember Home/`Core`/`CoreSingleLanguage` has no GVLK and
      always falls through to the placeholder-key-with-one-click-through path
- [ ] `-ProfileName` set if this output will share an `output\` folder with other build variants

## 5. Post-build verification checklist

- [ ] Boot the ISO (VM or real hardware matching your hardware-compatibility choice above) all the way
      through OOBE without manual intervention beyond what you expected (account creation, product key
      screen if using the placeholder-key fallback)
- [ ] Confirm the account-mode outcome matches what you picked: local admin account created vs. Microsoft/
      Entra sign-in offered
- [ ] Confirm expected apps are actually gone / actually present, spot-checking a few from your chosen
      package profile (Start menu search is enough for a quick check)
- [ ] For a **serviceable** (non-`-Core`) build: check Windows Update at least once (`Settings > Windows
      Update > Check for updates`) to confirm the image can still take updates — this is the whole point of
      not using `-Core`
- [ ] For a `-Core` build: confirm you're treating it as disposable/non-serviceable per its own warning —
      don't try to add features/languages or rely on Windows Recovery afterward
- [ ] If drivers were injected for an unusual storage controller: confirm the disk was actually visible to
      Setup during install (not just that the build completed without error) — see the known-risk note in
      checklist §3 above

## See also

- `docs/settings-config-strategy.md` — the config-file system these checklists are the human-readable
  front end for.
- `docs/build-options-reference.md` — full detail behind every checklist item above.
