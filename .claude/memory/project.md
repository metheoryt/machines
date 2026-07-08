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
  from the manifest by the flake (single source of truth). Decisions resolved: VPS
  stays Debian (imperative role executors, a 4th platform), secrets use PER-HOST
  age keys. Phase 1 plan (fleet.json manifest + per-platform dispatcher skeleton,
  applies nothing yet) written:
  `docs/superpowers/plans/2026-07-08-fleet-provisioner-phase1-manifest-dispatcher.md`.
  Phase 1 EXECUTED 2026-07-08 (commits `f1d0b90`..`7e5052d`): `fleet.json`
  manifest (5 machines), shared libs (`provision/lib/fleet.sh` via jq,
  `provision/lib/Fleet.psm1` via ConvertFrom-Json), launchers
  (`provision/provision.sh`, `provision/provision.ps1`), and a `just provision`
  recipe — all detect the host, resolve roles, and print a dry-run plan; `--apply`
  is a safe stub (exits 1). Applies nothing yet. Verified on g614jv (native pwsh
  no-arg auto-detect) + WSL Ubuntu-26.04 (bash+jq smoke). Also added root
  `.gitattributes *.sh text eol=lf` (box is `core.autocrlf=true`). The plan's
  `{{justfile_directory()}}` was CHANGED to a relative path — the absolute
  backslash path breaks under Git Bash on Windows (same reason `agent-bootstrap`
  is relative). NOT session-verifiable, deferred to real boxes (Runbook): literal
  `just provision` on a jq+just box, and per-box no-arg auto-detect on
  latitude5520/g16/homeserver/vps — needs a `git pull` there first, so PUSH is the
  gating next step. VALIDATED on latitude5520 2026-07-08: `just provision` (no
  args) ran the full just→bash→jq chain, live-auto-detected `latitude5520`, and
  printed all 10 nixos-role dry-run plans — mechanism now proven on BOTH platforms
  (windows/g614jv + nixos/latitude5520); only per-box no-arg detect on
  g16/homeserver/vps remains as trivial confirmation. Follow-ups: `provision/README.md` still documents only the
  non-Nix `linux.sh` flow (update when the front door does real work, Phase 2+);
  LATENT — manifest gives g16 (nixos) and g614jv (windows) the SAME mesh IP
  `10.0.0.6` but the verified peer map only confirms `.6`=g614jv; inert in Phase 1
  (applies nothing), resolve when writing the mesh-applying phase. Phase 0 SSH stopgap ~done: params real,
  latitude5520=.8, reciprocal trust wired (homeserver pubkey in
  mesh-authorized-keys) — awaiting the on-box switch/reboot.
- Phase 2 EXECUTED + PUSHED 2026-07-08 (commits `cb78503`..`5e4cab1`, on
  `origin/main`): the `agents` role is the first REAL executor that mutates a
  box. Added a `DRY_RUN` mode to `agents/bootstrap.sh` (detection runs, all
  `ln`/`mv`/`rm`/`mkdir`/host-stub/git-config mutation suppressed; default unset
  behavior byte-unchanged; converged re-run clean) + per-platform executors
  `provision/roles/agents.{sh,ps1}` (nixos = home-manager-owned no-op; wsl/debian
  → `bootstrap.sh`; windows → `bootstrap.sh` under Git Bash, throws on non-zero) +
  dispatch wiring in both launchers (per-role `Apply <role>? [y/N]` confirm gate,
  exits with worst executor status). Established the role→executor pattern later
  phases reuse. Verified session-side on WSL Ubuntu-26.04 (bash+jq) + g614jv
  (native pwsh): syntax/parse, dry-run mutates nothing (incl. a DIRTY-dir test
  proving `rm`/`mv` suppression on wrong-symlink + real-file targets), apply
  confirm skips on "n" with rc=0. GOTCHA: the PowerShell tool runs
  `-NonInteractive`, so `Read-Host` throws — drive the ps1 confirm-gate smoke via
  Git Bash `echo n | pwsh -File …` (a real, non-NonInteractive pwsh reading piped
  stdin), NOT the PowerShell tool. Runbook (real-box, needs `git pull` first):
  real `--apply`/`-Apply` answering `y` on g614jv/homeserver (Windows symlinks
  need Developer Mode) + vps (Debian); the personal-profile/Codex (`~/.codex`)
  link path is still unexercised (all session tests force a temp = secondary
  profile). NEXT: Phase 3 (next role executor, e.g. dotfiles/repos or the
  mesh-applying phase that resolves the g16/g614jv `.6` collision).
- Phase 3 EXECUTED + PUSHED 2026-07-08 (commits `b9fa0e6`..`b4b11ef`, on
  `origin/main`): `dotfiles` = second real role executor, chezmoi in stateless
  `--source` mode over an in-repo source `dotfiles/dot_gitconfig.tmpl` (universal
  tooling-independent git core; OS-templated `autocrlf` = windows→true /
  else→input; machine-/tooling-specifics — delta pager, `credentialStore=dpapi`,
  git-lfs filter, work email — deferred to UNtracked `~/.gitconfig.local`,
  `[include]`d last so it overrides; NEVER commit those to the template).
  Executors `provision/roles/dotfiles.{sh,ps1}`: nixos = home-manager no-op;
  wsl/debian → `_dotfiles_ensure_chezmoi` (apply installs via
  `get.chezmoi.io`→`~/.local/bin`, dry-run prints `~ would install chezmoi` and
  mutates NOTHING) then `chezmoi diff`/`apply --source`; windows → winget
  `twpayne.chezmoi` (id verified, v2.70.5), throws on apply non-zero. `chezmoi`
  runs fully stateless — every call passes `--source "$repo/dotfiles"`, no
  `chezmoi init`, no `~/.config/chezmoi`, updates come via `git pull`.
  `provision.sh` UNCHANGED (Phase 2 generic `role_<name>` dispatch picks up
  `role_dotfiles`); `provision.ps1` got one `$RoleExecutors` map entry. Verified
  session-side: WSL Ubuntu-26.04 (chezmoi v2.71.0 via the same installer) —
  render (`autocrlf=input` on linux), dry-run mutates nothing, apply writes
  `~/.gitconfig`, converged re-run diff EMPTY; a CRLF-line-ending source template
  (Windows working tree read over `/mnt/c`) still converges — no `.gitattributes`
  pin needed. g614jv pwsh — dry-run `would install`, apply-confirm gate skips on
  `n` rc=0. GOTCHA: the plan's no-leak grep (`delta|dpapi|filter "lfs"`)
  FALSE-matches the word "delta" in the template's HEADER COMMENT — scope any
  leak check to non-comment lines (`grep -v '^[[:space:]]*#'`). age secrets still
  deferred (secrets phase). Runbook (real-box, needs `git pull` first): seed each
  box's `~/.gitconfig.local` BEFORE first real apply or `chezmoi apply` drops the
  machine-specifics; then `-Apply`/`--apply` answering `y`. NEXT: Phase 4 — the
  `repos` executor, or the mesh-applying phase (g16/g614jv `.6` collision), or
  the secrets phase (agenix + age, the repo's first secrets framework).
- Phase 4 EXECUTED + PUSHED 2026-07-08 (commits `201e6d3`..`78da327`, on
  `origin/main`): `repos` = third real role executor, a PURE WRAP of the existing
  `provision/repos.sh` (host-agnostic, DRY_RUN-capable, interactive fzf select on
  apply) behind the Phase 2 dispatcher — zero edits to `repos.sh`. Executors
  `provision/roles/repos.{sh,ps1}` invoke it with NO group args (defaults to all
  three groups `my pure cyphy671`; interactive select is the per-box filter);
  `provision.ps1` got one `$RoleExecutors` map entry; `provision.sh` UNCHANGED
  (generic `role_<name>` dispatch picks up `role_repos`). Unlike agents/dotfiles,
  `repos` is NOT a nixos no-op — cloning working repos is imperative, so
  `role_repos` runs `repos.sh` on nixos|wsl|debian (unknown platform skips);
  `fleet.json` carries `repos` on latitude5520/g16 (nixos) + g614jv (windows),
  NOT vps/methe-server. GOTCHA: `repos.sh` dry-run is NOT inert — even
  `DRY_RUN=1` queries `gh` (network) and transiently switches gh's active account
  (restored to `metheoryt` at end); it clones nothing. No gh/fzf auto-install
  (repos.sh degrades gracefully). Built via subagent-driven-development (haiku
  implementers for the transcription tasks, sonnet for the integration task +
  reviews, opus final review = "ready to merge, no Critical/Important"). GOTCHA:
  in the ps1 dry-run smoke, `provision.ps1 ... 2>&1 | Select-String` does NOT
  filter — role-plan lines go via `Write-Host` (Information stream 6), which
  `2>&1` (stderr-only) doesn't merge; use `*>&1` (plan Step 4 corrected). Runbook
  (real-box): needs `gh` authed for `metheoryt`+`cyphy671`, `fzf`, and SSH aliases
  `github.com`/`github-cyphy`; real interactive apply (`y` at the gate → fzf
  multi-select) from a REAL terminal, not the PowerShell tool. NEXT: Phase 5 — the
  mesh-applying phase (g16/g614jv `.6` collision) or the secrets phase (agenix +
  age). Remaining stub roles: base, mesh-member/mesh-hub, ssh-server, backup-*.
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
