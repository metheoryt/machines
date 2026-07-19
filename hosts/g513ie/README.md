# g513ie (the cyphy.kz homeserver)

**ASUS ROG G15, RTX 3050 Ti**, running **Windows 11 + Docker Desktop
(WSL2)** under the `methe` profile. Windows hostname: `g513ie` (SSH alias
`server`). A distinct physical machine from the ROG G16 (2024) laptop `g614jv`
(whose retired NixOS identity was `g16`).

- **What it runs** (Immich, Navidrome, Forgejo, the cyphy.kz service platform)
  is defined in the **`vps` repo**, not here. This repo owns the *machine*, not
  its services.
- **Its data backups** (Immich Postgres/media) live at `../../backup/homeserver/`
  (fleet restic system).
- **OS reinstall runbook:** not yet written — deferred; adapt from
  `../g16/windows/windows-reinstall-runbook.md` when needed. Shared Win11 install
  media (answer file + Ventoy config) is already at `../../install-media/`.
