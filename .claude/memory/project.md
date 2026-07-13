# Project memory: machines

Repo-local, git-tracked Claude memory. Loaded every session (merged with
global + per-host memory). One bullet per fact under a topical heading.

## Fleet network

- Boundary: `machines` (this repo) owns NixOS/Windows machine provisioning;
  the sibling `~/my/vps` repo owns the cyphy.kz service platform (Immich,
  Navidrome, Forgejo, RustDesk server, Caddy, the VPS's AmneziaWG hub).

### Fleet transport is migrating AmneziaWG → Headscale (2026-07-13)

- **DECISION:** the OWN fleet's mesh transport moves from AmneziaWG to
  **Headscale** (self-hosted Tailscale control server). AmneziaWG stays ONLY as
  the obfuscated VPN for Russia-based relatives + friends' peers on the VPS hub.
  The extensive AWG-mesh work below (Phases 0–5b, "whole fleet mesh up") is now
  **LEGACY for our own machines** — kept as history, still live until each box
  is cut over to the tailnet.
- Headscale is LIVE on the VPS: v0.29.2 + embedded DERP (region 999, STUN
  udp/3478), served at `https://cc.cyphy.kz` behind Caddy (LE cert). `derp.urls:
  []` → all relayed traffic rides our OWN DERP. SQLite DB, user `fleet` (id 1),
  reusable pre-auth key. Installer `~/my/vps/vps/setup-headscale.sh` +
  `vps/headscale/config.yaml` (sanitized, no secrets). Enroll a node:
  `tailscale up --login-server https://cc.cyphy.kz --authkey <KEY>`.
- Tailnet CGNAT range `100.64.0.0/10` (disjoint from AWG `10.0.0.0/24`; they
  coexist on the same boxes). Nodes: vps `100.64.0.1`, latitude `100.64.0.2`,
  homeserver `100.64.0.3`. base_domain `fleet.mesh` (MagicDNS).
- Probe PASSED 2026-07-13 (spec/plan/results under machines
  `docs/superpowers/`): LAN-direct 3ms; SSH + RustDesk over the tailnet work;
  DERP fallback through our own relay is reliable. **KEY FINDING:**
  latitude(hotspot) + homeserver share this ISP's CGNAT (public `37.99.47.9`),
  so cross-network hole-punch FAILS → traffic relays through the VPS's embedded
  DERP (no regression vs today's all-via-VPS shape; the "P2P saves bandwidth"
  upside won't appear on that carrier). Highest-value follow-up: enable UPnP/PCP
  on the home router so roaming machines reach the fixed homeserver DIRECTLY,
  not via DERP.
- Per-box state: latitude5520 = AWG spoke DISABLED (`fleet.meshVpn.enable=false`
  + `services.tailscale.enable=true` in its `configuration.nix`), tailnet only.
- **Rollout DONE 2026-07-13** (plan
  `docs/superpowers/plans/2026-07-13-headscale-fleet-rollout.md`): the VPS Caddy
  now proxies homeserver services over the tailnet — `vps/caddy/Caddyfile`
  upstreams repointed `10.0.0.2`→`100.64.0.3` (committed on the VPS's `origin/main`
  directly, since the user's local vps clone was mid-feature on
  `telegrind-poll-deploy`; that pull also reconciled the 2-commit drift + the
  live-vs-repo Caddyfile drift). Homeserver containers already bind `0.0.0.0`, so
  NO rebind was needed — services reachable on `100.64.0.3` as-is (git/speed/qb/tug
  = 200; immich/navidrome were `502` only because their containers were down,
  unrelated). **homeserver AWG REMOVED**: `AmneziaWGTunnel$awg0` stopped/disabled
  (interface + `10.0.0.2` gone) and `wg0-homeserver` peer removed from the VPS hub
  (`manage-peers.sh remove`). Remaining AWG peers on the hub = relatives + friends
  + `me-g614jv` + `nix-lat5520` (untouched).
- **Rollout PENDING:** (1) g614jv onto the tailnet — its sshd is unreachable over
  the mesh (couldn't drive it remotely), so the user runs `winget install
  Tailscale.Tailscale` + `tailscale up --login-server https://cc.cyphy.kz` on the
  box directly. (2) Repoint SSH-over-mesh for the homeserver + update the vps
  convention docs (`CLAUDE.md`/`README.md` still say "bind to 10.0.0.2 / reachable
  only through the WireGuard tunnel"). The SSH-alias repoint is entangled with the
  broader fleet-wide SSH-over-tailnet migration (latitude is already tailnet-only,
  so `ssh.nix`'s AWG-mesh matchBlocks want migrating wholesale) — treat as a
  scoped follow-up, don't hack `fleet.json` mesh IPs (that field is the AWG
  source-of-truth for `mesh-vpn-params.nix`).
- iOS: the official **Tailscale App-Store app connects to Headscale** — set the
  custom control server `https://cc.cyphy.kz` (tap the account/login-server
  field; on older builds tap the version 5×). Once joined, the phone reaches
  fleet devices by tailnet IP/MagicDNS (SSH, RustDesk, web services).

- AmneziaWG VPN hub lives on the VPS (`10.0.0.1/24`). Verified live peer map
  (2026-07-08, `awg show` + `peers/*.key`): `.2`=homeserver, `.6`=`g614jv`
  (peer name `me-g614jv`), the Windows-only ROG G16 — the NixOS `g16` install is
  retired and removed from the repo. `.8`=`nix-lat5520` (latitude5520's NixOS
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
- Phase 5 = mesh role. DESIGN APPROVED + committed 2026-07-08 (spec
  `docs/superpowers/specs/2026-07-08-fleet-provisioner-phase5-mesh-executor-design.md`,
  commit `c09a52a`). **5a EXECUTED 2026-07-08** (commits `f9843bc`..`73d8276`):
  the old "g16/g614jv `.6` collision" is resolved — the ROG G16 is now
  Windows-only, `g614jv` is the live ROG and owns mesh `.6`, and the NixOS
  `g16` install (the `fleet.json` entry, `flake.nix` wiring,
  `hosts/g16/nixos/`, and `scripts/quick-check.sh` paths) is GONE from the
  repo — `hosts/g16/windows/` is deliberately kept. `fleet.json` is now the
  single mesh-IP source of truth: `mesh-vpn-params.nix` derives its `hosts`
  map (and exposes the raw `machines` records) via `fromJSON`, and
  `modules/home/ssh.nix` GENERATES its matchBlocks keyed on `mesh.role` (the
  hub keeps its `cyphy.kz` public hostname, never `.1`). The new
  `ssh.user`/`mesh.peerName` fields are in place: `g614jv`.ssh.user=`methe`
  with peerName `me-g614jv`, `homeserver`.ssh.user=`methe`,
  `vps`.ssh.user=`debian`, `latitude5520` peerName `nix-lat5520`. Remaining
  follow-ups: **Phase 5b** (the `~/my/vps` `manage-peers.sh` non-interactive
  prereq + the mesh-member/mesh-hub role executors, real-box only), and
  `homeserver`'s `mesh.peerName` is still DEFAULTED (unset in `fleet.json`)
  pending a `manage-peers.sh list` confirmation of its real VPS peer name.
  Key design decisions: (1) the **VPS is the key authority** — its
  `manage-peers.sh` (`add`/`show`/`list`/`remove`) runs `awg genkey` VPS-side,
  assigns the IP, stores the key in `peers/<name>.key`, and emits the full
  client conf; server conf lives at `/etc/amnezia/amneziawg/wg0.conf`. So the
  mesh-member executor does NOT generate keys locally — it SSHes `debian@cyphy.kz`
  and FETCHES its conf (`show <peerName>` for existing peers = no rotation,
  else `add <name> <ip>`), then installs it (nixos: extract PrivateKey →
  `/etc/amnezia-wg/awg0.key`; windows: whole conf → `%ProgramData%\amnezia-wg\awg0.conf`
  for GUI import; no Windows binary needed). (2) `fleet.json` becomes the SINGLE
  name-keyed source of truth for mesh IPs — `mesh-vpn-params.nix` derives its
  `hosts` map via `fromJSON`, and `modules/home/ssh.nix` GENERATES its
  matchBlocks (hub keeps `endpoint`/cyphy.kz hostname, not `.1`). (3) VPS peer
  names DIFFER from fleet keys (`g614jv`→`me-g614jv`, `latitude5520`→
  `nix-lat5520`) — manifest carries `mesh.peerName`. Split: **5a** = the Nix
  single-source refactor + g16 removal — Nix acceptance gates VERIFIED GREEN on
  latitude5520 2026-07-09 (`nix eval` hosts map is g16-free + `.6`=g614jv/`.1`=vps;
  generated ssh matchBlocks correct incl. hub keeping `cyphy.kz`; `nix flake check`
  "all checks passed"; NixOS + standalone-home dry-builds clean). Fix needed to
  get `flake check`/standalone-home green: `codex.nix`+`claude.nix` keyed the
  host-memory link off `osConfig.networking.hostName`, which is `null` in the
  standalone `homeManagerConfiguration` context — repointed both at the `hostname`
  specialArg (already threaded via `extraSpecialArgs` in both paths). Also: the
  generated `ssh.nix` was migrated off the DEPRECATED home-manager
  `programs.ssh.matchBlocks`/`extraOptions` to the current `programs.ssh.settings`
  API (upstream OpenSSH directive names: `HostName`/`User`/`StrictHostKeyChecking`),
  with `enableDefaultConfig = false` and the old implicit `Host *` defaults
  re-declared verbatim under `settings."*"`. On this flake's home-manager (tracks
  master ≈ 26.11) `matchBlocks` fires deprecation warnings — future ssh.nix edits
  (5b Windows aliases, host-key pinning) MUST use `settings`, not reintroduce
  `matchBlocks`. **5b** = a
  `~/my/vps` `manage-peers.sh` non-interactive prereq
  (`add <name> <ip>` + `--conf-only`) + the mesh-member/mesh-hub executors
  (real-box only). Windows boxes' existing hand-made AmneziaVPN tunnel must be
  REPLACED by the fetched conf, not run alongside it.
- **Phase 5b EXECUTED (session-verified) 2026-07-09:** `~/my/vps`
  `manage-peers.sh` gained non-interactive `add <name> <ip>` + `--conf-only`
  (the fleet-provisioner contract); this repo has `provision/lib/mesh.sh` +
  `Mesh.psm1` (VPS conf-fetch: `show`-then-`add` over SSH to
  `debian@cyphy.kz`, add-only/self-only, private key never logged),
  `provision/roles/mesh-member.{sh,ps1}` (NixOS key-fetch+verifier / Windows
  conf-fetch+verifier) and `mesh-hub.{sh,ps1}` (no-op pointer), wired into
  `provision.ps1` (`provision.sh` unchanged — generic `role_<name>` dispatch).
  `fleet.json` gained `vps.ssh.host=cyphy.kz` + `vps.mesh.managePeers`.
  Session acceptance sweep GREEN: posix parse + `mesh.sh` unit test + dry-run
  dispatch (NixOS member plan, hub pointer), Windows dry-run plan + apply
  confirm-gate (rc=0 answering "n").
- Hardening added beyond the 5b plan during review: the NixOS key install
  uses `sudo install -m600 -o root -g root -D` (error-guarded, not a bare
  cp/mv) so `/etc/amnezia-wg/awg0.key` lands `root:600` even off a non-root
  fetch step; the Windows conf write locks
  `C:\ProgramData\amnezia-wg\awg0.conf` down via `icacls` (inheritance
  disabled, ACL limited to the current user + Administrators) so the private
  key isn't left world-readable under ProgramData's default ACL.
- **Real-box pending** (runbook — Task 7 Step 3 / plan
  `docs/superpowers/plans/2026-07-09-fleet-provisioner-phase5b-mesh-executors.md`):
  (0) confirm the VPS `manage-peers.sh` path
  (`ssh debian@cyphy.kz 'ls -l /home/debian/my/vps/vps/manage-peers.sh'`), fix
  `fleet.json` if it differs; (1) land+pull the vps change on the VPS,
  smoke-test `add smoke 10.0.0.99 --conf-only` + `remove smoke`; (2)
  latitude5520: `--apply` the mesh-member role (answer y), confirm
  `/etc/amnezia-wg/awg0.key` is `root:600`, then REBOOT into `6.18.38`,
  `awg show awg0` for a recent handshake; (3) Windows (g614jv, homeserver):
  `-Apply` (answer y), import `C:\ProgramData\amnezia-wg\awg0.conf` into
  AmneziaVPN REPLACING the existing tunnel, enable, verify over the mesh.
  `homeserver`'s `mesh.peerName` is still DEFAULTED — confirm via
  `manage-peers.sh list` first; if it has no stored key, use the printed
  manual fallback rather than blindly `add` (risks "IP in use").
- **Mesh activation status (per-box, live checklist — tick as you go on each
  machine).** Steps map to the runbook above. `☐`=todo, `✅`=done, `n/a`=not
  applicable to that box.

  | Box | pull vps change | apply mesh-member | key `root:600` | reboot 6.18.38 | verified over mesh |
  |---|---|---|---|---|---|
  | VPS (hub) | ✅ pulled → `46625e1` (conf-only present) | n/a (hub) | n/a | n/a | n/a |
  | latitude5520 | ✅ | ✅ (NixOS `switch`) | ✅ | ✅ (into 6.18.38) | ✅ hub sees handshake + can ping `.8` over mesh (2026-07-13) |
  | g614jv (win) | ✅ | ✅ (`-Apply`, y) | n/a | n/a | ✅ imported `awg0.conf`, tunnel replaced — hub shows `me-g614jv` handshake (2026-07-12) |
  | homeserver (win) | ✅ | ✅ (`-Apply`, y) | n/a | n/a | ✅ rotated `wg0-homeserver` to managed key at `.2`, imported, tunnel replaced — hub shows handshake (2026-07-13) |

  Prereq for the whole table: step (0) VPS `manage-peers.sh` path confirmed +
  `fleet.json` fixed if it differs. Update this table (not a separate plan) as
  boxes come online — it syncs to every machine via git.
  - **2026-07-11 (from g614jv/WSL):** step (0) DONE — verified over Windows
    `ssh.exe` that the live VPS clone is `/home/debian/vps` (NOT `~/my/vps`);
    fixed `fleet.json` `vps.mesh.managePeers` + both mesh-lib fallbacks
    (`/home/debian/vps/vps/manage-peers.sh`). Windows→VPS SSH key + passwordless
    sudo both confirmed working. FOUND: the live VPS still runs the OLD
    `manage-peers.sh` (`grep -c conf-only` = 0) — the Phase 5b change is pushed
    to the vps repo `origin/main` (commit `46625e1`) but NOT pulled onto the VPS.
    So VPS row step 1 (land+pull+smoke) is the true next action and gates every
    member apply.
  - **2026-07-12 (g614jv online):** VPS pulled `46625e1`. Hit a PS parse error
    running `provision.ps1` under `powershell` (5.1) — the `.ps1`/`.psm1` files
    were UTF-8 **without BOM** with em-dash comment chars; 5.1 decodes BOM-less
    files as cp1252, turning em-dash bytes into smart quotes that PS treats as
    string delimiters → spurious "missing terminator". Fixed by adding a UTF-8
    BOM to all provision PS files (commit `264075a`); no PS7-only syntax, so they
    now run under both 5.1 and 7. Then `mesh-member` `-Apply` (y) wrote
    `awg0.conf`, imported into AmneziaVPN replacing the hand-made tunnel; VPS hub
    (`manage-peers.sh list`, iface is `wg0` not `awg0`) shows `me-g614jv` handshake.
  - **2026-07-13 (homeserver online, rotated to managed key):** homeserver's
    `.2` peer (`wg0-homeserver`) was hand-made BEFORE VPS key-storage → no stored
    key, so the executor's `show` would miss and `add` refuse (safe no-op, but
    couldn't be managed). Chose to ROTATE: relaxed the VPS `manage-peers.sh` IP
    floor from 3→2 so `.2` is claimable by an explicit `add` (`.1`=VPS still
    reserved; auto-suggest still starts at `.3` — vps `47d6729`). Then on the VPS
    `remove wg0-homeserver` + `add wg0-homeserver 10.0.0.2` (stdout→/dev/null so
    the key never printed) minted a managed keypair (new pubkey `oNv0/qn92…`).
    Set `fleet.json` homeserver `mesh.peerName=wg0-homeserver` (`6cc3223`).
    homeserver `-Apply` (y) → `show` now succeeds → imported, replaced the old
    hand-made tunnel; hub shows handshake. GOTCHA for future hand-made peers: to
    make them provisioner-managed you must rotate (VPS can't hand back a key it
    never generated).
  - **2026-07-13 (latitude5520 already online — WHOLE FLEET MESH UP):** the
    2026-07-08 "needs reboot into 6.18.38" note was STALE — the reboot happened
    since; `awg0` is up. Hub sees `nix-lat5520` (`.8`) handshaking AND can ping
    `10.0.0.8` over the mesh (bidirectional). With VPS hub + g614jv + homeserver
    + latitude5520 all handshaking, the fleet mesh activation is COMPLETE.
    (Verify freshly with `manage-peers.sh list` before assuming a box is down —
    the checklist can lag the live state.)
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

## Pending follow-ups

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
