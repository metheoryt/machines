# Project memory: machines

Repo-local, git-tracked Claude memory. Loaded every session (merged with
global + per-host memory). One bullet per fact under a topical heading.

## Fleet network

- Boundary: `machines` (this repo) owns NixOS/Windows machine provisioning;
  the sibling `~/my/vps` repo owns the cyphy.kz service platform (Immich,
  Navidrome, Forgejo, RustDesk server, Caddy, the VPS's AmneziaWG hub).
- AmneziaWG VPN hub lives on the VPS (`10.0.0.1/24`). Verified live peer map
  (2026-07-08, `awg show` + `peers/*.key`): `.2`=homeserver, `.6`=`me-g614jv`
  (the ROG G16's Windows/app side), `.8`=`nix-lat5520` (latitude5520's NixOS
  side, already handshaking). `.7` is a FRIEND's device (`ilya-romanyuk`) — the
  mesh also carries friends' peers, so never disturb existing ones. The live
  `wg0` has DRIFTED from on-disk `/etc/wireguard/wg0.conf` (the file lists peers
  not in the running interface — hand-edited live). `vps/vps/manage-peers.sh`
  adds roaming peers (keys gitignored in `vps/vps/peers/`, never committed).
- Fleet mesh + SSH-over-mesh is CODIFIED but only PARTIALLY activated. As of
  2026-07-08 the non-secret AmneziaWG params in `mesh-vpn-params.nix` are REAL
  (filled from the live VPS: vpsPublicKey, port 64531, obfuscation) and
  latitude5520's mesh IP is corrected to `.8` (commit `c33f391`, "Phase 0").
  PARTIALLY activated: a `switch` HAS now run on latitude5520 (2026-07-08) — the
  new generation activated (kernel 6.18.38 staged for next boot) but `awg0` did
  NOT come up because the box is still running the old 7.1.3 kernel (`modprobe:
  Module amneziawg not found in .../7.1.3`); it needs a REBOOT into 6.18.38. The
  private key at `/etc/amnezia-wg/awg0.key` is still not placed either, so `ssh
  <host>` over the mesh does not work yet. Live VPS `FORWARD` policy is already `ACCEPT`, so the old plan's
  hairpin rule is optional hardening, not a prerequisite. The mesh work is now
  reframed as "Phase 0" of the unified provisioner (see below); the old Runbook
  `docs/superpowers/plans/2026-07-07-fleet-mesh-vpn-ssh.md` is superseded. The
  Phase 0 param edit is now DRY-BUILT GREEN on latitude5520 (full toplevel
  builds with the LTS kernel pin below).
- Kernel is PINNED to LTS `pkgs.linuxPackages` (6.18.38) in
  `modules/system/base.nix` (commit `e2345ba`, 2026-07-08), off
  `linuxPackages_latest` (7.1.3): the out-of-tree AmneziaWG module does NOT
  compile on 7.x (`socket.c: 'ipv6_stub' undeclared`) but builds clean on the
  LTS — verified with NVIDIA 595.84 and the full latitude5520 toplevel. So the
  mesh REQUIRES the LTS kernel fleet-wide; don't bump back to `_latest` until
  amneziawg supports 7.x. And an out-of-tree module only loads under the kernel
  it was built for — after a kernel-changing `switch`, `wireguard-awg0` fails
  (`Module amneziawg not found in .../<old-kernel>`) until you REBOOT into the
  new kernel.
- Unified fleet provisioner: DESIGN APPROVED 2026-07-08, spec at
  `docs/superpowers/specs/2026-07-08-unified-fleet-provisioner-design.md`
  (commit `5cc7a94`). Convergence-first single front door over one role-based
  fleet (every owned machine is a member; "VPS" is just a public-IP role);
  machine layer only (services stay the vps repo's job). Composes existing
  engines — home-manager (NixOS dotfiles), chezmoi (non-Nix dotfiles, intentional
  divergence, retires the bare `~/.dotfiles`), restic (backup), age/agenix
  (secrets) — behind a thin dispatcher over a `fleet.json` manifest (JSON so a
  fresh Windows box reads it natively). NixOS role membership will be GENERATED
  from the manifest by the flake (single source of truth). NOT built yet; phased
  (Phase 0 = the mesh param fix above). Next: user reviews spec → writing-plans.
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
- latitude5520 (and g16's native NixOS side) have no dedicated backup today.
  Whatever home-manager declares in this repo is already "backed up" by being
  in git; anything outside home.nix's scope (browser profiles, ad hoc
  `~/.config` dirs, local documents) is not protected. User wants to back up
  latitude5520 into a private repo "someday" (stated 2026-07-07) — not urgent,
  no mechanism chosen yet (chezmoi/stow/plain git all unexplored as of this
  writing).
