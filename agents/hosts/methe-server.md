# Host: methe-server

<!--
Per-host memory + instructions for the homeserver (ASUS ROG G16 2023 / RTX 3050
Ti, Windows 11 + Docker Desktop, methe profile). Windows hostname: methe-server.
Symlinked to ~/.claude/host-memory.md and injected by the global-memory-load.sh
hook, so it is loaded ONLY when the hostname matches. Tracked in git and synced to every
machine, but inert on the others. Put machine-specific facts here: installed
tooling, local paths, hardware quirks, per-host overrides. Do NOT put secrets
here (this file is tracked in git).
-->

## Environment

- **This box = `methe-server`** (Windows hostname `METHE-SERVER`): ASUS ROG **G15
  2023**, RTX 3050 Ti. **Windows 11 + Docker Desktop (WSL2 backend)**, `methe`
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
