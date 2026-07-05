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

## Host

- ASUS ROG G16 2023, RTX 3050 Ti. Windows 11 + Docker Desktop (WSL2 backend).
- Runs the cyphy.kz self-hosted service platform (Immich, Navidrome, Forgejo,
  the service platform) — service definitions live in the **`vps` repo**; this
  machine's config/provisioning + data backup live in **`machines`**.

## Notes
