# Host: methe-server

<!--
Per-host memory + instructions for the homeserver (ASUS ROG G15 2023 / RTX 3050
Ti, Windows 11 + Docker Desktop, methe profile). Windows hostname: methe-server.
Symlinked to ~/.claude/host-memory.md and injected by the global-memory-load.sh
hook, so it is loaded ONLY when the hostname matches. Tracked in git and synced to every
machine, but inert on the others. Put machine-specific facts here: installed
tooling, local paths, hardware quirks, per-host overrides. Do NOT put secrets
here (this file is tracked in git).
-->

## Environment

- **This box = `methe-server`** (Windows hostname `METHE-SERVER`): ASUS ROG **G15
  2023**, RTX 3050 Ti. Exact model **`ROG Strix G513IE`** (`Win32_ComputerSystem.Model`
  = `ROG Strix G513IE_G513IE`, verified live 2026-07-19) — the model code the
  fleet hostname convention keys on. **Windows 11 + Docker Desktop (WSL2 backend)**, `methe`
  profile. Shells: Git Bash (MINGW64) + PowerShell 7. Mesh IP `.2` (the AWG hub
  is the VPS `.1`). Role: the always-on **cyphy.kz homeserver** — always was;
  it has only ever run Windows.
- **No sibling / alternate identity — standalone box.** Do NOT confuse it with
  the ROG **G16 (2024)** laptop `g614jv`/`ME-G614JV`, which is a *different*
  physical machine. (Some older repo docs, e.g. `hosts/homeserver/README.md` and
  vps `CLAUDE.md`, mislabel this server as a "ROG G16 2023" — it's a G15.)
- Runs the cyphy.kz self-hosted service platform (Immich, Navidrome, Forgejo,
  …) — service definitions live in the **`vps` repo**; this machine's
  config/provisioning + data backup live in **`machines`**.

## Notes

- **Russian-locale Windows breaks English ACL group names.** `icacls` / PowerShell
  ACL grants that reference `Administrators` or `SYSTEM` by English name silently fail
  ("no mapping between account names and security IDs was done") without raising a
  script error unless the exit code is checked — grant by **well-known SID** instead
  (`*S-1-5-32-544` = Administrators, `*S-1-5-18` = SYSTEM).
- **Git "dubious ownership" from Administrators-group-owned dirs.** A repo dir owned by
  `BUILTIN\Администраторы` (Administrators) instead of the user trips git's safety
  check and blocks `git pull`/etc. Quick unblock: `git config --global --add
  safe.directory <path>`; the real fix is `icacls <path> /setowner "<user>" /T /C`
  (NOT `takeown` alone, which assigns ownership to the elevated admin identity, not
  the actual user).
- **Scheduled-task console flash / Docker Desktop coupling.** An `Interactive`-logon
  Windows Scheduled Task flashes a `conhost` window on every run — fix by wrapping the
  action in `conhost.exe --headless`, NOT by switching to S4U ("run whether logged on
  or not"). Docker Desktop's daemon here is reachable only from the interactively
  logged-in user's session (per-user pipe/context), so an S4U or SYSTEM task would
  lose `docker` access.