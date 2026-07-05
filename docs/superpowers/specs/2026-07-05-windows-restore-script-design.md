# Windows restore script — design spec

Generated 2026-07-05. Companion to `hosts/g16/windows-reinstall/backup.ps1` and
`windows-reinstall-runbook.md`. Repo renamed `nix` → `machines`
(`github.com/metheoryt/machines`); the restore tooling targets the new name.

## Goal

A self-installing PowerShell restore flow, invoked from the internet (uv-style
`irm … | iex`) on a freshly reinstalled Windows, that: clones the `machines`
repo, discovers backups produced by `backup.ps1`, lets the user select one,
verifies destinations, and restores — **as a guided orchestrator, not a blind
mirror**. Restore is deliberately *not* the symmetric inverse of backup: several
items must be bootstrapped or installed-first, not copied verbatim.

## Non-goals

- Not a full unattended restore. Nuanced/ordering-dependent steps are *guided*
  (exact commands printed + pause), not automated.
- Does not re-create the qaz-law Postgres DB (intentionally not backed up — re-ingest).
- Does not manage the GitHub rename itself (a manual 30-sec web action, done first).

## Architecture — two stages

Small internet-facing surface; all real logic version-controlled.

- **Stage 1 — `hosts/g16/windows-reinstall/install.ps1`** (the `irm` target):
  ensure `git` (`winget install Git.Git --silent` if missing; refresh PATH) →
  `git clone` the `machines` repo to `$env:USERPROFILE\GitHub\machines` (pull if
  present) → invoke the cloned `restore.ps1`, passing args through. No backup
  logic, no destructive actions.
  ```powershell
  irm https://raw.githubusercontent.com/metheoryt/machines/main/hosts/g16/windows-reinstall/install.ps1 | iex
  ```
- **Stage 2 — `hosts/g16/windows-reinstall/restore.ps1`** (beside `backup.ps1`,
  consumes the layout `backup.ps1` writes): all discovery / verify / restore logic.

**Prerequisite:** the GitHub `nix → machines` rename (runbook Phase 4.0) is done
first, so the one-liner clones under the new name. This clone *is* Phase 4.0's
re-clone. (Done 2026-07-05.)

## Backup layout the restore consumes (contract with `backup.ps1`)

`<L>:\backup\` contains: `inventory\` (winget-packages.json, hkcu-environment.reg,
wsl-* lists), `wsl\<distro>.tar` (one per kept distro), `home\` (dotfiles minus
`.claude`/`.codex` trees, `AppData\…` app configs, `.ssh`), `repos\<name>\` (full
incl `.git`), `Downloads\`, `OneDrive\`, `GoogleDrive\`, `Obsidian\<vault>\`,
`secrets\` (wsl-secrets-<distro>.tar, Windows ssh keys, `wifi\*.xml`), `logs\`,
and a top-level `windows-reinstall-runbook.md`. Discovery marker = that runbook
file plus the expected subfolders/`logs`.

## Flow inside `restore.ps1`

1. **Discover** — scan every lettered volume for `<L>:\backup` carrying the
   marker. Candidate = { drive letter, label, total size, newest log timestamp,
   WSL tars found, repos found }.
2. **Select** — 0 candidates → stop with guidance; 1 → summary + confirm; >1 →
   numbered menu.
3. **Detect identity** — resolve the *current* user/home (`$env:USERPROFILE`);
   never hardcode `methe`. Print source→destination mapping table.
4. **Verify gate** — table `item | source | destination | action (create /
   overwrite / skip-exists / merge) | notes`, flagging overwrites of existing
   non-empty destinations (esp. `.ssh`, agent config). **`-WhatIf` by default**;
   explicit confirm (or `-Go`) required to write. Reuse `backup.ps1`'s
   `Step`/summary presentation.

## Automatic restores (safe, app-independent, idempotent, `robocopy /E` — never deletes)

- Windows repos → `$HOME\GitHub\*` (full incl `.git`; skip non-empty dest unless `-Force`)
- Downloads, Obsidian vault(s), OneDrive/GoogleDrive folders → local (cloud ones
  as plain folders + "reconcile against cloud later" note)
- `.ssh` → `$HOME\.ssh` **then fix ACLs** (icacls: disable inheritance, grant
  current user only) — inverse of what backup preserved
- Loose `secrets\` staged (WSL secret tars + Windows SSH keys)
- Plain dotfiles (`.gitconfig`, `.wslconfig`, `.kube`, `.gcm`, `.config`,
  `.claude.json`, shell histories) — **excluding `.claude`/`.codex`** (bootstrap-only)

## Guided restores (print exact ordered commands + pause — need app-first or judgment)

- **Agent config**: `just agent-bootstrap` (+ `-work`), *then* restore only
  machine-local `.credentials.json` / `settings.local.json` / `projects\` — never
  the symlinked trees.
- **WSL**: `wsl --install`, then one `wsl --import <name> C:\WSL\<name>
  …\wsl\<name>.tar` per tar found.
- **winget**: dropped-IDs prune list (Appendix B) + `winget import`.
- **App configs** (Terminal, PowerToys, NCALayer, AIMP, Telegram `tdata`→AyuGram,
  RustDesk): per-app "install → close → run this copy" command.
- **Env vars / Wi-Fi**: `reg import hkcu-environment.reg` (review, don't
  blind-merge) / `netsh wlan add profile` per XML.
- **Docker / qaz-law**: reminder to bring stack up empty + re-ingest.

## Safety invariants

Dry-run by default · confirm before any write · never deletes · additive
robocopy · refuses if no backup found · never clobbers non-empty `.ssh` /
agent-config without `-Force` + warning · current-user-aware · idempotent /
resumable.

## Open items / follow-ups

- After the scripts land, add a pointer to the one-liner in the runbook's
  Phase 4.0 (so the restore entry point is documented next to the rename step).
- The rest of the Phase 4.0 reference sweep (backup.ps1/runbook/memory/flake/
  gortex/autofetch still saying `nix`) remains a separate post-reinstall task.
