# Project memory: machines

<!-- KB refreshed against dd3d74b on 2026-07-24 (full fleet incl. g513ie) -->

Repo-local, git-tracked Claude memory. Loaded every session (merged with
global + per-host). One bullet per fact under a topical heading.

## Workflow

- **Git workflow — one framework, see `agents/docs/git-workflow.md`.** `main` is
  the fleet-sync truth. **main-checkout mode** (on `main` in `~/machines`): commit
  on `main`, push when ready; big/isolated work spawns a worktree. **worktree
  mode** (Orca worktrees): the `worktree-workflow` SessionStart hook injects the
  live rules — commit on the branch (never `main`), auto-sync `main`→branch, offer
  a fast-forward merge-back into `main` from the base checkout at checkpoints.
- `just quick` (`scripts/quick-check.sh`) treats `nix flake check` failures as
  non-fatal and only hard-gates on required-file presence + a one-host dry-build
  — can pass green while `nix flake check` is red. For reliable per-host
  validation prefer `nix build --dry-run '.#nixosConfigurations.<host>…'`.
- **The Windows fleet boxes have no Nix.** Any `nix eval` / `nix build --dry-run` /
  `nix flake check` step must be deferred to a NixOS member (currently only
  `latitude5520`) after a `git pull` — Windows-side work can reason about Nix diffs
  but never execute the gate.

## Fleet convergence & auto-sync

- **Convergence engine (`scripts/converge.sh` + gitignored `.machines/` state root).**
  Self-healing sync: after any pull, two OS-tier triggers fire a detached converge —
  non-nix boxes via a committed `post-merge` git hook; NixOS via a root
  `machines-converge.path` unit (`modules/system/machines-converge.nix`) watching
  `.git/logs/HEAD` (NOT `ORIG_HEAD` — ff-pulls don't rewrite it and inotify stales on
  atomic rename). Plus per-OS `fleet-selfpull` timers (NixOS systemd / Windows
  Scheduled Task / WSL), all `git pull --ff-only` on a jitter. NixOS rebuilds against
  the committed `flake.lock`, never a local update. Design under `docs/superpowers/`.
- **git-autofetch has three implementations** — NixOS (systemd timer), Windows
  (Scheduled Task), WSL/Ubuntu (systemd-user timer, cron fallback) — all sharing one
  root-scan model (`find` under `$HOME` depth 4, skipping node_modules/.cache/.direnv)
  doing refs-only `git fetch --all --prune`, never pulling (keeps the prompt's
  "behind by N" accurate).

## Fleet network

- Boundary: `machines` (this repo) owns NixOS/Windows machine provisioning;
  the sibling `~/my/vps` repo owns the cyphy.kz service platform (Immich,
  Navidrome, Forgejo, RustDesk server, Caddy, the VPS's AmneziaWG hub).
- The WSL fleet SSH key store (`ssh-wsl.sh`, `FLEET_KEY_DIR` default
  `/mnt/c/Users/<winuser>/.fleet/id_fleet`) is keyed by Windows user with no
  distro in the path, so every WSL distro on the same Windows box shares one
  key identity — the key is named after the fleet member matched via
  `fleet.json` `detect.hostname`, not the distro.
- SSH hub/jump-host detection is implemented twice — in `modules/home/ssh.nix`
  and independently (jq) in `provision/ssh-wsl.sh` for the WSL leaf's config —
  so any hub-rule change must be applied in both places or the WSL leaf drifts.
- Every fleet machine's OS hostname differs from its SSH alias by design
  (`latitude5520`↔`latitude`, `g614jv`↔`desktop`, `g513ie`↔`server`), so
  "is this host me?" can't be decided by comparing `hostname` to an alias
  string — use a runtime probe (`ssh $alias hostname` vs local `hostname`), as
  `kb-refresh` self-exclusion does.
- **Hostname-normalization convention — spec approved 2026-07-19, DONE
  2026-07-20**
  (`docs/superpowers/specs/2026-07-19-fleet-hostname-normalization-design.md`).
  Two layers, fleet-wide: **logical name** (stable, role-based) = fleet
  key = SSH alias = tailnet node = repo `hosts/<dir>`; **model name** = the box's
  OS hostname = `detect.hostname` = hardware model, lowercased
  (`latitude5520`, `g614jv`, `g513ie`, `27608`). Repo-dir renames DONE
  (Phase 1, 2026-07-20): `g16` → `hosts/desktop`, `homeserver` →
  `hosts/server`, committed. OS-hostname rename DONE (Phase 2, 2026-07-20):
  `server`'s OS hostname `methe-server` → **`g513ie`** (its real model) via a
  live Windows `Rename-Computer -NewName g513ie -Restart`, verified live
  post-reboot; `fleet.json`'s `detect.hostname` now matches reality. `hub`
  stays `27608` (a VPS, no laptop model). Headscale already enforces node-name
  uniqueness, so no SSH/tailnet change was needed; verified no `detect.hostname`
  drift vs reality.
- `modules/home/ssh.nix` materializes `~/.ssh/config` as a real `me`-owned
  `0600` file (not an HM store symlink) via two `home.activation` phases
  (`sshConfigUnmaterialize` before `checkLinkTargets`, `sshConfigMaterialize`
  after `linkGeneration`, `install -m600`) — OpenSSH strict-checks config
  ownership and a root-owned store symlink reads as `nobody` inside Orca's
  namespace, breaking all ssh. (Verified still present.)
- Firewall rules in `provision/windows.ps1` must be written to converge
  (remove-then-recreate), not create-if-absent — re-running against a host
  with a stale-scoped rule would otherwise leave the old scope in place.
- **Fleet dispatch is platform-aware, via
  `agents/plugin/skills/lib/fleet-dispatch.sh`** (`fd_probe`/`fd_run`/
  `fd_wsl_hosts`, sourced by `/ship`'s `fleet-pull.sh` and kb-refresh's
  `fleet-gather.sh`). `/ship` + kb-refresh reach every fleet host's
  `$HOME/machines` clone: Windows-native members (`desktop`, `server`) via Git
  Bash dispatched through PowerShell's call operator (live-verified
  2026-07-22), and self-declared WSL hosts — never in `fleet.json` — via
  `wsl -l -q` + each distro's gitignored `fleet.local.json`, reached at
  `<nickname>.gg.ez` (implemented; WSL-discovery not yet live-verified
  end-to-end). The old `/mnt/c` cross-filesystem root was REMOVED — `machines`
  is now located canonical-path-first (`$HOME/machines`), root-scan fallback
  second. Half-provision a WSL host with `just provision-wsl <nickname>`.

### Fleet transport migrated AmneziaWG → Headscale (2026-07-13; retired 07-17)

- **DECISION:** the OWN fleet's mesh transport moved from AmneziaWG to
  **Headscale** (self-hosted Tailscale control server). AmneziaWG stays ONLY as
  the obfuscated VPN for Russia-based relatives + friends' peers on the VPS hub.
  AWG-mesh blow-by-blow (Phases 0–5b) archived → `docs/fleet-mesh-history.md`.
- Headscale is LIVE on the VPS: v0.29.2 + embedded DERP (region 999, STUN
  udp/3478), served at `https://cc.cyphy.kz` behind Caddy (LE cert). `derp.urls:
  []` → all relayed traffic rides our OWN DERP. SQLite DB, user `fleet` (id 1),
  reusable pre-auth key. Installer `~/my/vps/vps/setup-headscale.sh` +
  `vps/headscale/config.yaml` (sanitized, no secrets). Enroll a node:
  `tailscale up --login-server https://cc.cyphy.kz --authkey <KEY>`.
- **Orca's per-project worktree setup-script is stored in plain JSON** (probed
  2026-07-19). The field you paste `bash "$HOME/machines/scripts/orca-worktree-setup.sh"`
  into lives in `~/.config/orca/profiles/local-default/orca-data.json` at
  `.repos[].hookSettings.scripts.setup` (mirrored under `.projectHostSetups[]`),
  keyed by repo path — machine-local, Orca-owned (it rewrites the file and keeps
  `.bak.N` backups). So the string is greppable, and a repo only gets it after
  it's been opened in Orca once.
- **Orca `serve` on WSL was REMOVED (2026-07-21).** Orca now runs on the Windows
  host and opens the WSL project directly; the per-distro `orca serve` runtime,
  its systemd unit, the `~/.local/bin/orca` CLI shim, and `provision/orca-serve.sh`
  are all gone. `provision/tailscale-wsl.sh` (tailnet identity) + `ssh-wsl.sh`
  (fleet SSH) stay — the WSL box is still a first-class tailnet/SSH node.
- **The `desktop` WSL distro is its own tailnet node.** Node `100.64.0.6`;
  Headscale given-name (MagicDNS) `desktop-ubuntu26` (`desktop-ubuntu26.gg.ez`),
  renamed from `desktop-wsl-ubuntu-26-04` on 2026-07-19 via `sudo headscale nodes
  rename desktop-ubuntu26 -i 6`. Reported hostname on the box is still the long
  form (cosmetic; given-name is durable unless the node fully re-registers on a
  `wsl --unregister` rebuild). Enrolled by `provision/tailscale-wsl.sh`.
- **SSH into the WSL box (2026-07-19).** `ssh-wsl.sh` now installs
  `fleet-authorized-keys` into the box's own `~/.ssh/authorized_keys` (inbound
  trust; was a leaf that only trusted OUTward before). This ROG box's key
  (`methe@me-g614jv`) is now in `fleet-authorized-keys` too. `me` on the WSL box
  needs a sudo PASSWORD, but the box's `id_fleet` IS trusted on the VPS — so
  Headscale admin is reachable by hopping `ssh me@100.64.0.6 → ssh hub → sudo
  headscale …` (VPS `debian` = passwordless sudo).
- **`headscale` admin commands on the VPS need `sudo` (probed 2026-07-17).**
  The control socket `/var/run/headscale/headscale.sock` is `headscale:headscale`
  mode `0770` and `debian` is NOT in the `headscale` group, so socket-touching
  subcommands (`preauthkeys create/list/expire`, `users list`, `nodes …`) fail
  `permission denied` as a bare command. `debian` has **passwordless sudo**, so
  run `sudo headscale …` (works non-interactively over SSH). `--help` and other
  non-socket subcommands work without sudo. This is why `tailscale-wsl.sh
  --enroll` mints via `sudo headscale preauthkeys create`.
- Tailnet CGNAT range `100.64.0.0/10` (disjoint from AWG `10.0.0.0/24`; they
  coexist on the same boxes). Nodes: vps `100.64.0.1`, latitude `100.64.0.2`,
  homeserver `100.64.0.3`. base_domain `gg.ez` (MagicDNS; renamed from
  `fleet.mesh`).
- Probe PASSED 2026-07-13 (spec/plan/results under machines
  `docs/superpowers/`): LAN-direct 3ms; SSH + RustDesk over the tailnet work;
  DERP fallback through our own relay is reliable. **KEY FINDING:**
  latitude(hotspot) + homeserver share this ISP's CGNAT (public `37.99.47.9`),
  so cross-network hole-punch FAILS → traffic relays through the VPS's embedded
  DERP (no regression vs today's all-via-VPS shape; the "P2P saves bandwidth"
  upside won't appear here). The fleet spans **two separate LANs**; same-LAN
  pairs get direct P2P (~3ms), cross-LAN pairs relay via our own DERP — EXPECTED
  and ACCEPTED by the user, so UPnP/router port-mapping is explicitly NOT a
  follow-up. Backlog/roadmap lives at `docs/fleet-roadmap.md`.
- **Windows sshd gotchas** (for the future `ssh-server` role executor): (a)
  `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0` throws "Class not
  registered" under PowerShell 7 (DISM COM only registers under WinPS 5.1) — use
  `dism.exe /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0`
  instead (version-agnostic). (b) Enable the firewall rule for ALL profiles
  (`Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -Profile Any`) — Tailscale's
  adapter is often a "Public" network. (c) For an ADMIN user, OpenSSH ignores
  `~/.ssh/authorized_keys` and reads `C:\ProgramData\ssh\administrators_authorized_keys`
  (ACL: Administrators+SYSTEM only). (d) Default shell is `cmd.exe`; set
  `HKLM:\SOFTWARE\OpenSSH\DefaultShell` for PowerShell.
- **MagicDNS is LIVE tailnet-wide** (Headscale `magic_dns: true` +
  `override_local_dns: true`; `accept-dns` ON). MagicDNS uses the Headscale
  GIVEN-NAMES, not fleet.json keys.
- **Fleet rename + MagicDNS adoption COMPLETE (2026-07-15; blow-by-blow archived →
  `docs/fleet-mesh-history.md`).** Durable outcome: given-names + SSH aliases + repo
  dirs are `hub`/`latitude`/`server`/`desktop`; MagicDNS suffix `gg.ez` live tailnet-
  wide; the hosts-file machinery (`fleet-hosts.nix` + `hosts` role) was DELETED
  (no longer exists); `ssh.nix` slimmed (hub→`cyphy.kz`/`debian`,
  server/desktop→`methe`, latitude→bare MagicDNS); latitude pins `--accept-dns` via
  a `tailscale-accept-dns` oneshot. Flake attr is decoupled from the OS hostname
  (`nixos_attr` justfile var).
- **AWG mesh retired from the machines repo (2026-07-17).** SSH-server role moved
  to `modules/system/ssh-server.nix` (`fleet.sshServer`, keys-only sshd on
  `tailscale0` + LAN). Deleted `mesh-vpn.nix`, slimmed params → `fleet.nix`
  (machine records only), dropped `mesh` blocks + `mesh-member`/`mesh-hub` roles
  from `fleet.json`, removed provisioner mesh roles/libs, renamed the trust file
  → `provision/fleet-authorized-keys`, converged `windows.ps1` firewall onto
  `100.64.0.0/10`. Kept: AmneziaVPN client (latitude + Windows winget) and the
  VPS AWG VPN server for RU relatives.
- **Desktop WSL leaf SSH — LIVE + VERIFIED 2026-07-18.** The `Ubuntu-26.04`
  distro on `desktop` (tailnet node `desktop-wsl-ubuntu-26-04` = `100.64.0.6`,
  user `me`) is fully provisioned as a fleet SSH leaf: its `id_fleet` (comment
  `me@wsl-desktop`) is trusted on **latitude, server, AND the Debian hub**, and
  its `~/.ssh/config` resolves `ssh latitude`/`ssh server`/`ssh hub` correctly
  (hub → `cyphy.kz`/`debian`). Verified end-to-end from inside the distro (auth
  OK to all three; `ssh server whoami` → `methe-server\methe`). GOTCHAs:
  (a) the wsl `me` user has NO passwordless sudo, so `ssh-wsl.sh` can't be driven
  non-interactively — its first `sudo apt-get install` `die`s without a TTY; if a
  `wsl --unregister` rebuild needs it, re-run from inside the distro. (b) `ssh
  <host> true` is a FALSE-negative reachability test against the Windows peers
  (server/desktop): their default shell is PowerShell, where `true` is not a
  command (exit 1) — use `whoami` / `exit 0` instead. (c) reach the distro from
  latitude via `ssh desktop "wsl bash -lc '…'"`; base64-pipe the script to dodge
  the local→PowerShell→bash quote nesting.
- iOS: the official **Tailscale App-Store app connects to Headscale** — set the
  custom control server `https://cc.cyphy.kz` (tap the account/login-server
  field; on older builds tap the version 5×). Once joined, the phone reaches
  fleet devices by tailnet IP/MagicDNS (SSH, RustDesk, web services).

- Kernel is back on `pkgs.linuxPackages_latest` (linux-7.1.3) in
  `modules/system/base.nix` (branch `update-nix-linux-kernel`, 2026-07-19). HISTORY:
  pinned to the LTS `pkgs.linuxPackages` (6.18.38) on 2026-07-08 (commit
  `e2345ba`) solely because the out-of-tree AmneziaWG module wouldn't compile on
  7.x (`socket.c: 'ipv6_stub' undeclared`). That blocker is gone — the AWG mesh
  was retired (2026-07-17, commit `8952af9`; fleet moved to Headscale/Tailscale,
  userspace, no out-of-tree kernel module), so the bump back was safe. NVIDIA-
  safety (CLAUDE.md's steadier-track preference) does NOT bind here: this flake
  builds ONLY latitude5520, Intel-only, doesn't import `nvidia.nix`.
  Verified: full `latitude5520` toplevel builds green on 7.1.3. If an NVIDIA host
  (g16) is ever re-added as a NixOS target, reconsider pinning IT back to
  `linuxPackages` — `base.nix` is shared. (Historical gotcha, still true of any
  out-of-tree module: it only loads under the kernel it was built for — after a
  kernel-changing `switch`, the module fails `Module <x> not found in
  .../<old-kernel>` until you REBOOT into the new kernel.)
- AmneziaVPN CLIENT fully retired from our own machines (2026-07-19, same branch):
  removed `amnezia-vpn-wrapped` from `modules/home/me.nix`, the `AmneziaVPN`
  systemd service from `hosts/latitude/nixos/configuration.nix`, and the
  `Amnezia.AmneziaWG` + `AmneziaVPN.AmneziaVPN` winget entries from both
  `hosts/{g16,homeserver}/windows/winget-packages.json`. The obfuscated AWG VPN
  HUB (for RU relatives/friends) is untouched — it lives in the `vps` repo, not
  here. Only historical "why the mesh was retired" comments still mention AWG.
- **Unified fleet provisioner** (design
  `docs/superpowers/specs/2026-07-08-unified-fleet-provisioner-design.md`; the Phase
  0–5b blow-by-blow is archived → `docs/fleet-mesh-history.md`). Convergence-first,
  machine-layer only (services stay the `vps` repo), driven by the `fleet.json`
  manifest; front door `just provision` (`provision.{sh,ps1}`, per-role
  `Apply <role>? [y/N]` gate). REAL role executors under `provision/roles/`: `agents`
  + `dotfiles` + `repos` (dotfiles = chezmoi over in-repo `dotfiles/`, machine-
  specifics deferred to untracked `~/.gitconfig.local` via `[include]`; on NixOS
  `agents`/`dotfiles` are home-manager no-ops but `repos` still runs `repos.sh`).
  `base`/`ssh-server`/`backup-client` remain UNIMPLEMENTED stubs (see Pending).
  Secrets (age/agenix) designed, not built.
- RustDesk is self-hosted on the VPS (hbbs/hbbr, `cyphy.kz`), seeded via
  `modules/home/rustdesk-config.nix` (server key + known-peer IDs, no
  passwords committed).
- Secrets convention is CHANGING. Historically: no framework, keep secrets out
  of git entirely (out-of-store paths / gitignored). The approved unified-
  provisioner design (2026-07-08) REVERSES this — plans age-encrypted secrets
  in-repo via chezmoi (non-Nix boxes) + agenix (NixOS), one age identity for the
  fleet. Designed, NOT yet implemented — agenix would be the repo's first
  secrets framework.
- User keeps a separate bare-repo dotfiles tracker at `~/.dotfiles`
  (`git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME`, alias `dotfiles`,
  github.com/metheoryt/dotfiles, private), one branch per machine. Plain
  files, no encryption. Secret files (SSH keys, VPN keys, etc.) are never
  committed but ARE listed in that machine's branch `.gitignore` — the
  ignore entry itself is the "you need to restore/regenerate this on a fresh
  box" checklist, without ever storing the secret content. When adding a new
  per-machine secret (e.g. an AmneziaWG private key), add its path to that
  machine's `.dotfiles` branch `.gitignore` too, not just to this repo.
- SSH keys are per-host, not shared (e.g. latitude5520's is
  `ssh-ed25519 ...  me-nixos-latitude5520`) — each fleet machine has its own
  keypair; cross-machine SSH trust needs each host's *public* key collected
  centrally (see fleet-mesh-vpn-ssh-design.md), not one key copied around.

## Backups

- Fleet restic hub-and-spoke: every client (homeserver's own immich profiles,
  g16's wsl profile) backs up through resticprofile to/on the homeserver
  (REST server on port 8001, or local drives). g16's old `laptop/music`
  profile was retired 2026-07-07 (music no longer lives on g16); see
  `vps` commit `backup: retire g16 laptop music restic profile` and
  `docs/superpowers/plans/2026-07-05-machines-fleet-layout-B-backup.md`.
- Homeserver's immich backup targets `G:`/`H:` are 2.5" HDDs in USB docking
  stations plugged into the homeserver — physically removable, but currently
  left permanently attached. Since every backup in the fleet ultimately lands
  on the homeserver (its own immich backups + g16-wsl's REST target), a
  homeserver-location disaster (theft/fire) currently takes out primary data
  and all backups together — not truly offsite yet.
  Why: reviewed 2026-07-07; the fix is cheap because the drives are already
  removable — periodic manual rotation of one dock's drive to an off-site
  location, no new infra needed. Prefer that over recommending cloud/object
  storage additions unless the user wants to skip manual rotation.
- **RustDesk restore is not a plain file-copy.** RustDesk runs as a LocalSystem
  Windows service that owns a master config and overwrites `%APPDATA%\RustDesk\config`
  (`RustDesk2.toml`) seconds after service start — so `restore.ps1` can never durably
  restore the custom ID/Relay ("retranslator") server by copying the file back. The
  restore script instead extracts those values from the backup and prints them for
  manual GUI entry (Settings → Network → ID/Relay Server).
- **`restore.ps1`'s `Find-Backups` auto-discovers the backup drive** by scanning every
  Windows volume for a `<letter>:\backup` folder, so it survives the backup SSD
  mounting on a random drive letter; sibling scripts (`backup.ps1`,
  `bootstrap-agents.ps1`) historically hardcoded a letter and needed the same
  auto-discovery.
- latitude5520 (and g16's native NixOS side) have no dedicated backup today.
  Whatever home-manager declares in this repo is already "backed up" by being
  in git; anything outside home.nix's scope (browser profiles, ad hoc
  `~/.config` dirs, local documents) is not protected. User wants to back up
  latitude5520 into a private repo "someday" (stated 2026-07-07) — not urgent,
  no mechanism chosen yet (chezmoi/stow/plain git all unexplored as of this
  writing).

## Repo tooling & scripts

- Orca IDE is `modules/home/orca-bin.nix`, wrapping the upstream Linux
  AppImage with `appimageTools.wrapType2`; `just update-orca`
  (`scripts/update-orca.sh`, wired into `just update`/`just upgrade`) bumps its
  `version`+hash. (`zed-bin.nix`/`pycharm-bin.nix` were removed 2026-07-21 — see
  the editors bullet below.)
- `/cyphy:kb-refresh` (`agents/plugin/skills/kb-refresh/`) mines per-machine
  Claude Code transcripts into this repo's memory tiers: `distill.py` reduces
  JSONL to `[USER]/[ASSISTANT]/[BASH]/[EDIT]` digests, a git-tracked watermark
  (line-offset + identity-hash, seeded fleet-wide) guarantees read-once, and
  `fleet-gather.sh` distills in-place on other fleet boxes and copies back
  only digests (via `cat`/`tar`, never raw transcripts).
  - `fleet-gather.sh` harvests the **Windows** fleet members (desktop=g614jv,
    server=methe-server): it dispatches on `fleet.json` `platform`, bash-wraps
    every remote command (Windows ssh lands in PowerShell), pushes `distill.py`
    and transports state/digests over `cat`/`tar` (no rsync), distills both the
    Windows-profile and WSL projects roots, and stamps digests with the fleet
    `detect.hostname`. Design: `docs/superpowers/specs/2026-07-19-fleet-gather-windows-design.md`.
- `scripts/orca-worktree-setup.sh` is the generic dispatcher Orca runs on each
  new worktree: it symlinks gitignored config (`.env`,
  `.claude/settings.local.json`) from the main checkout, then delegates to
  `$repo/.orca/worktree-setup.sh` or `scripts/orca-worktree.d/<main-basename>.sh`;
  it is always non-fatal (exits 0) so it can't block worktree creation.
- Per-host agent-memory filenames use the raw OS hostname
  (`agents/hosts/latitude5520.md`, `g614jv.md`, `ME-G614JV.md`,
  `methe-server.md` — not fleet aliases), threaded via a single
  `MACHINES_HOST_ID` env var (nix passes `networking.hostName`; bootstrap
  computes it off-nix). A curated short name drifts from what nix/bootstrap
  resolve and misdirects the host-memory link.
- `justfile`'s `switch`/`test`/`boot` recipes depend on a `_check-machines-link`
  guard that fails loud if the repo's expected symlink location is dangling —
  added after repo-rename events silently broke agent-config linking.
- `update-{rustdesk,orca,gortex}.sh` resolve their target `.nix` path relative
  to their own dir under `scripts/` (the `zed`/`pycharm` updaters were deleted
  2026-07-21); a new updater needs the correct extra `../` to reach repo root,
  or it breaks `just update`/`just upgrade` silently (`sed: no such file`).
- `hosts/desktop/windows/winget-packages.json` is a full `winget export` snapshot
  of that laptop's installed state; `hosts/server/windows/winget-packages.json`
  is a hand-curated minimal server set — maintained differently, don't
  conflate them when adding packages.
- **`CLAUDE.md` and `agents/CLAUDE.md` are symlinks** to `AGENTS.md` /
  `agents/AGENTS.md` (the global-memory hook works for Codex too). A tool with a
  symlink guard (won't write through a symlink) edits nowhere useful if pointed at
  the `CLAUDE.md` path — edit the real `AGENTS.md` target.
- **Windows `just` needs `set windows-shell := ['C:/Program
  Files/Git/bin/bash.exe','-cu']`** (in the justfile) — native PowerShell has no
  POSIX `sh`, so without it `just` fails on Windows even on `just --list`. Recipes
  must use **relative** script paths, not `{{justfile_directory()}}` — Git Bash
  mangles the absolute backslash path (`C:\Users\methe\machines` →
  `C:Usersmethemachines`); `just` runs recipes with cwd = justfile dir, so relative
  works.
- **`scripts/quick-check.sh` (the `just quick` gate) hardcodes the host label** —
  `hosts/latitude/…` paths and `.#nixosConfigurations.latitude…` as literal strings,
  NOT via the justfile's decoupled `nixos_attr` var. A future host-label rename
  silently breaks `just quick` even though `nixos-rebuild`/`nix build` keep working;
  update quick-check.sh in the same rename.
- **`agents/statusline-command.sh` probes `python3 → python → py` in that order** —
  on fresh Windows boxes `python3`/`python` on PATH are usually Microsoft Store stubs
  that fail silently (blank statusline); the `py` launcher resolves real installs via
  the registry regardless of PATH.
- **`.gortex/` (per-repo daemon SQLite index state) is gitignored** with a trailing
  slash so it doesn't also match the committable `.gortex.yaml` wiring; `gortex init`
  re-sprays `.claude/skills/generated/gortex-*` even with `--no-skills`, so that path
  stays gitignored too. Never commit either — machine-local index state.
- **`agents/bootstrap.sh` installs + wires gortex** (ce67699): Windows gets the
  binary via the upstream PowerShell installer if missing (NixOS via
  `pkgs/gortex.nix` + `me.nix` daemon); then `gortex install --no-claude-md` (re)wires
  the profile. **`--no-claude-md` is load-bearing** — the shared `AGENTS.md` is
  reached via the `~/.claude/CLAUDE.md` symlink, so without it bootstrap would gut the
  fleet-synced instruction file on every run (that flag is the ONLY thing keeping the
  wiring off a committed file). **Verified empirically:** `gortex install` otherwise
  writes ONLY machine-local targets — `~/.claude.json` (MCP), gitignored
  `settings.local.json` (hooks), and generated `skills/commands/agents/` — it does
  **not** touch the shared, symlinked `agents/settings.json` (there is no
  `--no-settings` flag, but none is needed). So the wiring step is safe to re-run.
  Idempotency guard: skips when the profile is already wired (`gortex` present in
  `settings.local.json`); `GORTEX_REWIRE=1` forces it. Skipped under nix activation
  (`[ -e /etc/NIXOS ]`) — run it on latitude via `just gortex-setup`.
- **Note:** the settings-normalizer (Claude Code itself, on `/config`/model changes)
  rewrites `~/.claude/settings.json` **through the symlink** into the committed
  `agents/settings.json`, reordering keys — a recurring source of a spurious
  `M agents/settings.json`. It's cosmetic (no semantic change); not caused by gortex.
- **`just update-gortex`** (`scripts/update-gortex.sh`, wired into `just update`) bumps
  `pkgs/gortex.nix` version+hash — the NixOS half of the "float" story (Windows floats
  via the installer). Resolves its target as `<scripts>/../pkgs/gortex.nix`.
- **Editors: PyCharm + Zed removed entirely 2026-07-21** (unused; PyCharm 2026.2 also
  broke on nixpkgs auto-patchelf for `libjawt.so`/`libudev.so.1`). `zed-bin.nix`,
  `pycharm-bin.nix`, `update-zed.sh`, `update-pycharm.sh` all deleted; the built-in
  GNOME Text Editor is the fallback. Orca is the one wrapped editor left.
- **caveman is enabled repo-wide via `agents/settings.json`** (`"caveman@caveman": true`
  + marketplace `"caveman": {"repo": "JuliusBrussee/caveman"}`), fired by the plugin's
  SessionStart hook — so it travels to every profile bootstrapped from this repo.
  `/caveman-init` (writing the always-on rule into `CLAUDE.md`/`AGENTS.md`) is only
  needed for non-Claude agents (Codex/Cursor) that load no plugin.
- **Orca auto-injects hook wiring into `agents/settings.json` + `agents/codex/hooks.json`
  on launch** (SHARED tier — committing them pushes fleet-wide) and re-injects on the
  next launch. Prefer NOT to commit these: the Codex side has no existence guard and
  fires a nonexistent Windows path on other hosts.

## Pending follow-ups

- **Retire the WSL distro as a separate fleet host (in-flight, stated 2026-07-19).**
  Direction: the ROG G16 laptop's WSL distro should stop being provisioned as its own
  tailnet node + SSH leaf (`provision/ssh-wsl.sh`, `provision/tailscale-wsl.sh`, node
  `desktop-ubuntu26`/`100.64.0.6`); going forward WSL is used purely as a **dev
  environment opened/run through Orca**, not a standalone fleet member. Not yet torn
  down — the WSL-leaf facts in `agents/hosts/g614jv.md` and the mesh/SSH-over-tailnet
  notes above stay live until the provisioning is actually removed. Consequence
  already applied: the laptop's two host-memory files were merged into one
  (`agents/hosts/g614jv.md`; `ME-G614JV.md` is now a symlink to it) since native
  Windows + WSL are the same tightly-coupled box.

- **Per-box stale git-hook cleanup after the pre-commit removal (2026-07-18).**
  Commit `2af7c5b` removed the git-hooks.nix pre-commit mechanism from `flake.nix`
  + the committed `.envrc` (whose sole job was the persistent nix-direnv `.direnv/`
  GC root keeping the hook's `/nix/store` closure alive against the weekly GC). The
  installed `.git/hooks/pre-commit` AND `.git/hooks/pre-push` are UNTRACKED, so
  their removal can't ride the commit. On any box that ran `nix develop`/direnv
  against a machines clone, run once: `rm -f .git/hooks/pre-commit
  .git/hooks/pre-push`. Otherwise once `.envrc` is gone the `.direnv/` root drops
  on next `cd` → the next weekly `nix-collect-garbage` reaps the pinned tooling →
  the stale hook fails to exec and **aborts every commit/push** on that box.
  SCOPE CORRECTION: the hook only ever exists where `nix develop` ran — i.e. a
  NixOS/nix dev box. In this fleet that is **only latitude5520** (Windows
  desktop/server + the now-Windows-only g16 + the Debian hub + WSL leaves have no
  nix, so never had the hook). Latitude5520 is DONE (cleaned this session); nothing
  else is pending. Trade-off accepted:
  lint/format (alejandra/deadnix/statix/shellcheck) is now a MANUAL gate
  (`just fmt` / `just check`), no longer enforced on commit; and `cd` no longer
  auto-loads the dev shell (`.envrc` gone) — use `just shell` / `nix develop`.

- **VPS base-machine reproducibility (idea, NOT started — 2026-07-11).** Goal:
  bring a fresh cloud VM back to the VPS baseline reproducibly. Blocked because
  the provisioner's `base`, `ssh-server`, `backup-client` roles are UNIMPLEMENTED
  — no executor files exist (only agents/dotfiles/mesh-hub/mesh-member/repos do).
  So running `provision.sh --apply` on the VPS today does NOT provision the base:
  base/ssh-server/backup-client print "not yet implemented (skipped)"; only
  agents/dotfiles would actually run (mutating the live debian user's config —
  don't). Scope when built: base machine only — services stay the `vps` repo's
  `setup-*.sh` (awg server, caddy, rustdesk), secrets/data via restic + (unbuilt)
  age/agenix. Open: distro (Debian vs Ubuntu 24.04 LTS — both apt-family, so the
  `base` role can be written family-generic; low-stakes, deferrable).

- **Drop `pylspFixOverlay` from `flake.nix` once python-lsp/python-lsp-server
  PR #715 merges and ships in a nixpkgs release.** The overlay builds
  python-lsp-server from our fork commit (`metheoryt/python-lsp-server @
  e4ee218`, version `1.14.1.dev0+pr715`) to carry the fix for the
  `pylsp_definitions` crash on positionless definitions (`d.line is None` →
  `TypeError`), which gortex hit constantly. Added 2026-07-09. When nixpkgs
  ships pylsp with the fix, delete the overlay block + its entry in the
  `overlays` list and revert to stock. Track: https://github.com/python-lsp/python-lsp-server/pull/715
