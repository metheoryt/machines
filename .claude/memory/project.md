# Project memory: machines

<!-- KB refreshed against dd3d74b on 2026-07-24 (full fleet incl. g513ie);
     hand-edited through 2026-08-01 — entries carry their own dates -->

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
- **THE NIX GATE IS GONE — there is no Nix host left in the fleet (verified live
  2026-08-01).** latitude was reinstalled as **Debian 13 trixie**
  (`PRETTY_NAME="Debian GNU/Linux 13 (trixie)"`); `nix` is not on the box at any
  path. So `just quick`, `just test`, `nix flake check` and every
  `nix build --dry-run` are unrunnable fleet-wide, while `flake.nix` still builds
  `latitude5520` — a machine that no longer exists. The flake's fate is still
  undecided; decide it before the next change that touches `modules/`.
- **Do NOT reason about latitude as a NixOS box.** `hosts/latitude/nixos/`,
  `modules/`, and `modules/home/ssh.nix` all describe a machine that was wiped.
  This single stale fact produced two confidently-wrong turns in one session, so
  the concrete consequences, all observed live:
  - `/etc/fstab` is hand-managed and edits stick (nothing regenerates it).
  - Packages come from `apt` (`sudo apt-get install -y exfatprogs`), not the flake.
  - `~/.ssh/config` is a real file that DOES carry `metheoryt.github.com` and
    `cyphy671.github.com` aliases — the opposite of what `ssh.nix` would render.
  - `sqlite3`, `lsof`, `fuser` are absent from the base install; use
    `python3 -c "import sqlite3…"` and `umount`-fails-if-busy instead.
  - **`/usr/sbin` and `/sbin` are not on the non-interactive ssh PATH.** Scripts
    run over `ssh latitude '…'` must `export PATH=/usr/sbin:/sbin:/usr/bin:/bin`
    or `mkfs.*`, `blkid`, `findmnt` and `wipefs` all come back "command not found".
- **The test suite is plain bash and no recipe runs it.** `provision/tests/*.test.sh`
  (17 files), `provision/*.test.sh`, `agents/tests/*.test.sh`,
  `scripts/converge.test.sh`. Run one with `bash provision/tests/roles.test.sh` —
  it prints `ALL PASS` and exits nonzero on failure. **`just test` is
  `nixos-rebuild test`, not this** — an easy and costly misread.

## Fleet convergence & auto-sync

- **Convergence engine (`scripts/converge.sh` + gitignored `.machines/` state root).**
  Self-healing sync: after any pull, two OS-tier triggers fire a detached converge —
  non-nix boxes via a committed `post-merge` git hook; NixOS via a root
  `machines-converge.path` unit (`modules/system/machines-converge.nix`) watching
  `.git/logs/HEAD` (NOT `ORIG_HEAD` — ff-pulls don't rewrite it and inotify stales on
  atomic rename). Plus per-OS `fleet-selfpull` timers (NixOS systemd / Windows
  Scheduled Task / WSL), all `git pull --ff-only` on a jitter. NixOS rebuilds against
  the committed `flake.lock`, never a local update. Design under `docs/superpowers/`.
- **`provision/linux.sh` is a DRIVER, not a script.** Tier bodies live in
  `provision/lib/tiers.sh` as `tier_<name>` functions; the driver resolves a profile
  (`MACHINES_PROFILE` env > `fleet.json` `"profile"` by OS hostname > `workstation`)
  and runs that profile's ordered tier list. `MACHINES_TIERS_DRY_RUN=1 bash
  provision/linux.sh` prints the plan and exits — do that before touching a tier.
  Adding a new provisioning path under `provision/lib/` REQUIRES adding it to
  `touches_linux()` in `scripts/converge.sh`, or a pull touching only that file
  makes converge write `ok` AND advance `converged-rev` — a permanent silent skip,
  not a delayed apply.
- **hub is enrolled (2026-07-25).** `~/machines` clone, profile `hub` (lean tier
  list: `apt_min agents_config git_base agent_clis(claude) shell_init(--no-fish)
  autofetch selfpull ssh_trust`), `FLEET_ROOTS` pinned to `~/machines` so `~/vps`
  stays a deliberate manual pull. Three hazards a future change must not
  reintroduce: (1) `tier_ssh_accounts` must NEVER run on hub — it writes
  `IdentitiesOnly` on a fresh unregistered key into hub's empty `~/.ssh/config` and
  kills its only GitHub auth (`id_rsa`), i.e. the ff-pull itself, on a remote box;
  ~~(2) every `fleet.json` hostname needs a COMMITTED `agents/hosts/<host>.md`~~
  — **void since 2026-07-28**: `agents/hosts/` is gone and `bootstrap.sh` seeds
  nothing into the repo, so this shape of permanently-dirty tree can no longer
  occur (the dirty-tree stranding hazard itself is still real — see the
  `fleet-selfpull` bullets); (3) the `touches_linux` gap above. (1) and (3) are
  guarded by `provision/tests/tiers.test.sh`.
- **A systemd-user `fleet-selfpull` unit MUST carry `KillMode=process`** (fixed
  2026-07-25, found live on hub). The pull fires `post-merge`, which backgrounds
  `converge.sh` with `setsid` — that leaves the session but NOT the unit's cgroup, so
  the default `KillMode=control-group` SIGKILLs the converge ~3s later when the
  oneshot finishes. Symptom is nasty: Trigger B pulls forever (HEAD advances, timers
  look healthy) and `.machines/last-converge` never appears. Boxes provisioned before
  the fix can't self-heal through Trigger B — the reaped converge is what would
  rewrite the unit — so each needs ONE manual `git pull` (whose converge is not in a
  unit cgroup) or a manual `bash provision/linux.sh`. Done on `hub` and on
  `desktop-ubuntu26` (desktop's WSL Ubuntu-26.04) 2026-07-25. Desktop's OTHER WSL
  distro, Ubuntu-24.04, has a stale `~/machines` (on `main`, clean, at `2815efb`)
  with `fleet-selfpull.timer` **inactive** — it was never enrolled in Trigger B, so
  it needs a `provision/linux.sh` run, not just a pull.
- **git-autofetch has FOUR implementations** — NixOS (systemd timer), Windows
  (Scheduled Task), WSL/Ubuntu (systemd-user timer, cron fallback), macOS (launchd
  LaunchAgent) — all sharing one root-scan model (`find` under `$HOME` depth 4,
  skipping node_modules/.cache/.direnv) doing refs-only `git fetch --all --prune`,
  never pulling (keeps the prompt's "behind by N" accurate).
- **`timeout(1)` DOES NOT EXIST on macOS** — it is GNU coreutils, not BSD, and
  coreutils is not installed by default. This silently disabled git-autofetch on
  `air` from provisioning until 2026-07-29 (`ed65e7c`): every fetch died "command
  not found", `2>/dev/null` ate the message, and the script still exited 0, so
  launchd reported a healthy job that had never fetched. `tier_autofetch` now emits
  an `af_timeout` shim (timeout → gtimeout → POSIX sh watchdog). That shim is a
  SANCTIONED divergence from `modules/system/git-autofetch/default.nix`, which
  resolves `timeout` from `pkgs.coreutils` on its PATH — the rest of the two must
  stay in sync.
- **A best-effort loop that swallows errors must exit non-zero when EVERYTHING
  failed.** The timeout bug above hid for a day purely because "all 7 repos failed"
  and "all 7 succeeded" produced the same exit 0. One unreachable remote is a
  warning; nothing working is a broken install. Applies to every scan-and-retry
  script here (`git-autofetch`, `fleet-selfpull`, `dotfiles-sync`).
- **GNU-only tooling is the recurring macOS trap in this repo**, and it always fails
  quietly: `timeout` absent, `wc -l` padding its output, `grep -P` unsupported, `/proc`
  absent (bit `orca-repair`, `a34b2c7`). When touching a script that runs on `air`,
  check the BSD behaviour rather than assuming GNU.
- **Don't infer a leak from killed-fetch debris.** A TERM'd `git fetch` leaves
  `.git/objects/pack/tmp_pack_*` behind, so probing with a short budget manufactures
  exactly the evidence of a recurring leak. Measure at the real budget before
  changing the scan.
- **NEVER `git fetch` a shallow clone from a scan.** A `clone --depth 1` client can
  offer only its one commit during negotiation and its shallow boundary stops it
  claiming any ancestor, so the server resends the whole history. `~/.hermes/hermes-agent`
  (upstream's install.sh does `clone --depth 1 --branch main`) went 60M/1-commit to
  350M with `refs/remotes/origin/main` legitimately reaching 18914 commits — and
  `git gc` reclaims NOTHING, because nothing is garbage. One-way damage, repeating
  every tick. git-autofetch skips shallow repos since 2026-07-29; they are vendored
  installs with their own updater, not checkouts whose ahead/behind you track.
  Restoring one needs `main` advanced to `origin/main` (i.e. let install.sh update
  it) or a fresh clone — dropping tags and gc'ing does nothing.
- **Upstream hermes-agent's installer is already correct** — `install.sh` uses
  `git clone --depth 1 --branch "$BRANCH"` and its updater fetches only that branch,
  with a comment saying why. Bloat in `~/.hermes/hermes-agent` came from OUR scan,
  not from upstream. No PR is warranted there.

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
  `wsl -l -q` + each distro's gitignored `fleet.local.json`. Only the
  `dispatch:direct` distro (at most one per Windows host) is reached at
  `<nickname>.gg.ez`; every other distro is `dispatch:parent`, reached as
  `wsl.exe -d <distro>` through its Windows parent (implemented; WSL-discovery
  not yet live-verified end-to-end). The old `/mnt/c` cross-filesystem root was REMOVED — `machines`
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
  2026-07-19). The field you paste `bash "$HOME/machines/agents/worktree-setup.sh"`
  into lives in `~/.config/orca/profiles/local-default/orca-data.json` at
  `.repos[].hookSettings.scripts.setup` (mirrored under `.projectHostSetups[]`),
  keyed by repo path — machine-local, Orca-owned (it rewrites the file and keeps
  `.bak.N` backups). So the string is greppable, and a repo only gets it after
  it's been opened in Orca once.
- **In Orca, the registered PATH *is* the environment — there is no environment /
  runtime / distro field** (probed 2026-07-26). A `projectHostSetup` carries only
  `projectId / hostId / path / kind / hookSettings`, and `hostId` is `local` for
  Windows and WSL alike. Orca derives the hook runner from that path:
  `\\wsl.localhost\…` → `.git/worktrees/<wt>/orca/setup-runner.sh` (bash), `C:/…` →
  `setup-runner.cmd` (cmd.exe). Entries are stored **per `(projectId, path)`**, so a
  repo registered in both worlds appears twice under one `projectId` — `orca-status.sh`
  reports only the first, which is why g614jv read `WIRED` off its unused `C:/`
  entry while the WSL entry Orca actually uses was empty. Drill down with
  `jq -r '.projectHostSetups[]|[.projectId,.path,(.hookSettings.scripts.setup//"-")]|@tsv'`.
  **Fleet convention: register every project at its WSL path.** On a `C:/…`
  registration the standard one-liner fails *silently* two ways — cmd.exe resolves
  `bash` to the WSL launcher `C:\Windows\System32\bash.exe`
  (`Bash/Service/E_UNEXPECTED`, the same trap `agents/plugin/skills/lib/fleet-dispatch.sh`
  documents for `ssh <windows-member> bash …`) and never expands `$HOME`, so the
  hook looks configured and does nothing (symptom: fresh worktree missing its
  `.claude/settings.local.json` link). If a Windows registration is unavoidable, the
  value that works is
  `"%ProgramW6432%\Git\bin\bash.exe" -c "bash $HOME/machines/agents/worktree-setup.sh"`
  — verified on g513ie; non-login `bash -c` already has the full MSYS PATH and Orca's
  cwd, so no `-l` / `CHERE_INVOKING`. Orca's data file is at
  `%APPDATA%\orca\profiles\local-default\orca-data.json` on Windows (`/mnt/c/Users/<winuser>/…`
  from WSL — the Windows profile name differs from `$USER`), and one box can host two
  installs: g614jv has both a Windows Orca and a WSL-native one.
- **The Windows-native `machines` clones are converge-only — never Orca projects**
  (decided 2026-07-26). Development happens in **g614jv's WSL `~/machines`**, the
  active copy. `C:\Users\methe\machines` exists on g614jv for fleet/desktop-only work
  and on g513ie for server-only work; neither does development, so neither needs Orca
  worktrees, and both were unregistered from Orca. **Unregistering costs nothing** —
  Orca plays no part in fleet sync: `fleet-pull.sh` reaches those clones directly over
  SSH (members `desktop` and `server` both resolve to `C:\Users\methe\machines`) and
  convergence fires from `core.hooksPath` → `agents/git-hooks/post-merge`, verified
  present on g513ie. Keep the clones on disk regardless: on g614jv it is the link
  target for the Windows-native Claude profile. Net effect — with every Orca project
  registered at a WSL path, the `C:/`-registration hook breakage above is unreachable
  in practice.
- **Hand-testing an Orca `setup-runner.cmd` from MINGW64 needs `cmd //c`, not
  `cmd /c`** — MSYS path conversion rewrites the lone `/c` into a path, cmd never
  sees the switch and drops to an interactive prompt, emitting bogus
  `'…' is not recognized` errors unrelated to the real failure.
- **Orca `serve` on WSL was REMOVED (2026-07-21).** Orca now runs on the Windows
  host and opens the WSL project directly; the per-distro `orca serve` runtime,
  its systemd unit, the `~/.local/bin/orca` CLI shim, and `provision/orca-serve.sh`
  are all gone. `provision/tailscale-wsl.sh` (tailnet identity) + `ssh-wsl.sh`
  (fleet SSH) stay — the WSL box is still a first-class tailnet/SSH node.
- **RENAMED 2026-08-01: everything called `desktop-ubuntu26` or `Ubuntu-26.04` is
  now `desktop-wsl`.** The WSL distro (registry `DistributionName`), the tailnet
  node/MagicDNS name, and the dotfiles branch were all renamed together. Entries
  **anywhere in this file** that predate 2026-08-01 keep the old names because
  they are dated records of what was true then — read them as history, not as
  addresses.
  Live names now: distro `desktop-wsl`, `desktop-wsl.gg.ez` → `100.64.0.6`,
  dotfiles branch `desktop-wsl`, UNC `\\wsl.localhost\desktop-wsl\…`.
  `desktop-ubuntu26.gg.ez` is NXDOMAIN and the remote branch is deleted.
- **The `desktop` WSL distro is its own tailnet node.** Node `100.64.0.6`;
  Headscale given-name (MagicDNS) **`desktop-wsl`** (`desktop-wsl.gg.ez`), set
  2026-08-01 with `sudo tailscale set --hostname desktop-wsl` from inside the
  distro — which renames the Headscale node in place, leaving no duplicate and
  keeping `100.64.0.6`. (It was `desktop-ubuntu26` from 2026-07-19, itself renamed
  from `desktop-wsl-ubuntu-26-04`.) `tailscale set` needs root and there is no TTY
  under the agent's Bash tool; drive it as
  `ssh desktop 'wsl.exe -d desktop-wsl -u root -- tailscale set …'`. Enrolled by
  `provision/tailscale-wsl.sh`.
- **A distro rename does NOT re-publish `\\wsl.localhost\<name>` until the distro
  restarts.** The 9p share name is registered at distro boot, so straight after
  the registry edit Explorer can reach neither the old name nor the new one.
  `wsl --terminate <distro>` fixes it and is preferable to `wsl --shutdown` — it
  leaves `docker-desktop` up, and an abrupt terminate does not unregister
  `WSLInterop` VM-wide the way a graceful systemd shutdown does.
- **`fleet-authorized-keys` IS AUTHORITATIVE NOW, and comments are LOGICAL fleet
  names (2026-08-01, commit `3fcd6ae`).** POSIX used to merge it append-only
  keyed on the key BODY, so a deleted line was revoked on Windows (which
  regenerates wholesale) and stayed trusted forever everywhere else — the file
  read like a revocation list and was not one. Same body-keying meant a renamed
  comment never propagated. `ssh_wsl_merge_authorized_keys` now rewrites a
  managed span `# >>> fleet-trust (managed by machines) >>> … # <<< fleet-trust
  <<<`; `tier_ssh_trust` calls that one implementation instead of its own awk
  copy, **sourcing ssh-wsl.sh in a SUBSHELL** because the script runs `set -u`
  and defines its own `info/ok/warn/die/have` that would otherwise replace the
  tier runner's for every later tier. Three rules that matter: lines OUTSIDE the
  span are never touched (hand-added keys survive); a fleet key found unmanaged
  outside it is ABSORBED rather than duplicated (the migration path — a stray
  copy would keep granting access after the span revoked it); an empty/unreadable
  key list makes the merge REFUSE rather than write an empty span and lock the
  fleet out. Comments unified to `<login>@<logical fleet name>`:
  `methe@g513ie`→`methe@server`, `methe@me-g614jv`→`methe@desktop`,
  `me@wsl-desktop`→`me@desktop-wsl`. Reason: OS hostnames churn and the labels
  rot — desktop had been `DESKTOP-4PQ6V6B`→`ME-G614JV`→`g614jv` (stale by two
  renames), server's own key still said `methe@methe-server`, latitude answers
  `uname -n` with `latitude5520`, a machine that no longer exists. **Propagation
  after a push is AUTOMATIC and fast on hub/desktop/server** — measured
  2026-08-01: desktop fetched the commit at 14:13:25 and rewrote
  `administrators_authorized_keys` at 14:13:37. air/latitude/desktop-wsl were
  applied by hand (their `tier_ssh_trust` only runs on a provision).
- **Two residues the span deliberately will NOT clean, on hub only.** Keys
  installed before the span exists sit outside it and are never auto-pruned —
  by design, since auto-deleting unrecognised keys would nuke legitimate
  hand-added ones. hub's `~/.ssh/authorized_keys` still carries
  `methe@lat5520` (…cSCvBc — matches NO key on any reachable box, dead) and
  `me@desktop-wsl-ubuntu-26-04` (…DXi623 — **LIVE**: it is desktop-wsl's
  `id_ed25519`, redundant only because its ssh config pins `id_fleet`). Check
  before pruning either; the dead-looking one is dead, the other is not.
- **hub is SSH TARGET-ONLY, and always was.** It has no ed25519 fleet key (only
  `debian@27608` RSA, absent from `fleet-authorized-keys`) and no fleet block in
  `~/.ssh/config` — `tier_fleet_ssh` is darwin-only and hub deliberately skips
  `tier_ssh_accounts`. So `hub → any member` fails (`debian@latitude: Permission
  denied`, host-key failures elsewhere) while everything reaches hub fine. Not a
  regression; don't "fix" it without deciding hub should initiate at all.
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
  coexist on the same boxes). Nodes (live 2026-08-01): hub `100.64.0.1`,
  latitude `.2`, server `.3`, desktop `.4`, ipheoryt `.5`, desktop-wsl `.6`,
  air `.7` — read Headscale (`sudo headscale nodes list`), never infer the next
  address from `fleet.json`. base_domain `gg.ez` (MagicDNS; renamed from
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
  distro on `desktop` (**now named `desktop-wsl`**; tailnet node then
  `desktop-wsl-ubuntu-26-04`, now `desktop-wsl`, = `100.64.0.6`,
  user `me`) is fully provisioned as a fleet SSH leaf: its `id_fleet` (comment
  `me@desktop-wsl` since 2026-08-01) is trusted on **latitude, server, AND the
  Debian hub**, and
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
  + `dotfiles` + `repos` (dotfiles = the private bare repo, see the dotfiles
  bullets below; on NixOS `agents` is a home-manager no-op but `dotfiles` and
  `repos` both run).
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
- **`$HOME` config is the private `metheoryt/dotfiles` bare repo, not chezmoi**
  (spec `docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md`).
  `~/.dotfiles` is a bare repo whose work-tree is `$HOME`; each box checks out a
  branch named by its **logical** fleet name (`latitude`, `air`, `desktop`,
  `server`, `hub`). `provision/dotfiles-sync.sh` commits + pushes tracked changes
  every 10 min and merges `origin/main` in behind a `merge-tree --write-tree`
  preflight. `machines/dotfiles/` and the chezmoi role were deleted 2026-07-28.
- **A path is shared XOR host-local.** On `main` ⇒ shared and byte-identical
  everywhere; absent from `main` ⇒ host-local. Never both. That is why
  home-manager-owned paths (`~/.ssh/config`, `~/.gitconfig`) are not on `main`:
  no exclusion mechanism is needed, they simply live on non-Nix host branches.
  Moving a path branch → `main` is the manual `/dotfiles-promote` skill.
- **Never `add -A` in the dotfiles repo**, and never `dotfiles checkout main` on
  a live box — the first can leak an unlisted file, the second deletes every
  host-local file from `$HOME` for the duration.
- **Enrolled 2026-07-28** — `air`, `hub`, `desktop`, `latitude`, and the WSL host
  `desktop-ubuntu26` — **renamed to `desktop-wsl` 2026-08-01, local and remote**
  (branch auto-created from `main` by the role). **`server` is
  NOT enrolled** — it was offline; enroll it by hand when it is back, since
  converge on a Windows box runs `windows.ps1` only and never the role.
  `.ssh/config` was dropped from every branch during migration (home-manager
  deletes it on latitude); it is untracked everywhere and stays that way.
  Enrolling `latitude` first required merging its `~/pure/backend-api` project
  memory into `main`'s — the two boxes had accumulated 11 and 3 disjoint bullets
  for the same repo. Whenever a collision file has real content, merge it onto
  `main` BEFORE the checkout: the checkout overwrites, and the local content was
  never tracked anywhere, so it is simply gone.
- **`$HOME/CLAUDE.md` (tracked on the dotfiles repo's `main`) is a real
  auto-loading agent-memory slot on every enrolled box** — verified with a live
  `claude -p` probe, which reports it as project instructions for any cwd under
  `$HOME`. That is where the "offer to track this file" nudge lives. **Cost: every
  line is ambient in every session under `$HOME`**, including work repos, so keep
  it to decision rules. Anything phrased around "a file you edited" misfires on
  ordinary source files there — gate on "has no other home" instead.
- **Agent config content lives in dotfiles, not `machines` (2026-07-28, executed
  end-to-end across all six boxes).** The criterion is a property of the bare
  repo: its work-tree IS `$HOME`, so a tracked path must be a path that
  legitimately exists in a home directory.
  `~/.claude/{CLAUDE.md,memory/global.md,memory/personality/,host-memory.md,
  statusline-command.sh,balance-refresh.py}` and the three untested skills
  (`gortex-align`, `update-balance`, `worktree-agent`) are dotfiles-tracked at
  those paths; `machines` keeps `bootstrap.sh`, the tests, and the fleet-coupled
  plugin. **This REVERSES `d9b1be4`**, which had recorded `$HOME/CLAUDE.md` as the
  only available agent-memory slot on the premise that bootstrap's `link()` would
  fight dotfiles for `~/.claude/…`. bootstrap no longer touches those paths — it
  only `retire_link()`s stale links and fans `~/.claude-<postfix>` and Orca's
  account profiles out AT the primary profile (`$PRIMARY_DIR`, always `~/.claude`). `$HOME/CLAUDE.md`
  keeps its own distinct job, above.
- **A skill with `tests/` stays in `machines`; a skill without moves to dotfiles.**
  The line coincides exactly with fleet coupling — every `fleet.json` reader is
  tested — so no skill is separated from its tests or its manifest. Post-move the
  rule holds with no exceptions: every remaining plugin skill has a `tests/` dir.
  Invocation for the moved three is `/<name>`, not `/cyphy:<name>`.
- **`agents/hosts/` and `agents/memory/` are gone.** Per-host memory is
  `~/.claude/host-memory.md`, host-local on each dotfiles branch; the shared store
  is `~/.claude/memory/`, on `main`. The old `$HOST_ID.md` scheme keyed on
  OS-hostname identity and had drifted to 7 files for 5 machines — and it only
  resolved on `desktop` because Windows is case-insensitive (`COMPUTERNAME` is
  `G614JV`, the file is `g614jv.md`).
- **HAZARD — a `machines` worktree hijacks `~/.claude` via the post-checkout
  hook.** `git worktree add` fires the hook, which runs THAT worktree's
  `agents/bootstrap.sh` with `SRC_DIR=<worktree>/agents`, repointing
  `~/.claude/skills/cyphy` (and, from a pre-2026-07-28 commit, the memory /
  instruction / statusline paths) into the worktree. When the worktree is removed
  the links dangle, and `retire_link` will NOT clean them because its guard matches
  only the live `$SRC_DIR`. Recovery: `rm` the dangling links, `dotfiles checkout
  -- .claude`, then re-run `bash ~/machines/agents/bootstrap.sh`. Hit for real
  2026-07-28 while checking out an old commit to date a test failure.
- **`bootstrap.sh` now REFUSES to run from a copy of the repo** (2026-07-28) —
  the guard for the hazard above, plus the second shape it took the same day: an
  agent session snapshotted `agents/` into its own scratchpad, ran bootstrap
  there, and left five `~/.claude` paths *and* the `memory/personality`
  DIRECTORY dangling at `/private/tmp/…/scratchpad/pre/agents/`. Symptom is
  nothing like the cause — Claude Code fails a statusline command **silently**,
  so the statusline just vanishes, and the memory files read as deleted. It
  refuses two shapes: a linked git worktree (`--git-dir` != `--git-common-dir`,
  probed first because it is the more actionable reason) and a path under a temp
  root. Escape hatch: `MACHINES_BOOTSTRAP_ALLOW_COPY=1`. What saved the memory
  files that day was the commit debounce from `902c783` — `pending.since` was
  stamped 23:30, so four personality-facet deletions were still inside the
  window when `dotfiles-sync`'s `add -u` would otherwise have committed and
  pushed them.
- **`~/.gitconfig` and `~/.ssh/config` are tracked on `air`'s branch only**
  (2026-07-28) — host-local, never on `main`: they carry absolute `/Users/me`
  paths, air's two-account `includeIf` wiring, and this box's tailnet aliases.
  Both generators (`tier_git_base`, `tier_ssh_accounts`) were verified
  byte-stable, so the 10-min timer does not churn. git records mode `100644`,
  so `.ssh/config` restores as 644, not its live 600.
- **Anchor host-local allow-lines with a leading slash** (`!/.gitconfig`), unlike
  the shared allow-lines, which have none. Unanchored patterns match at ANY
  depth, so `!.gitconfig` would make a stray `.gitconfig` or `.ssh/config` inside
  any project checkout under `$HOME` eligible for tracking.
- **`git check-ignore -v` exits 0 on a NEGATED match too**, so `check-ignore -v
  path && echo ignored` reports the opposite of the truth for allow-listed
  paths. Use `check-ignore -q`, or `dotfiles add --dry-run` (refusal = ignored).
- **`gh` recreates `~/.config/gh/config.yml` within seconds** (as a `version: "1"`
  stub), so "move it aside, then enroll" is racy — it re-collided on two of four
  boxes and refused the checkout both times. Move it aside for the diff, then
  `rm` the regenerated stub immediately before running the role.
- **On Windows, a headless converge registers no user-owned scheduled task.**
  `windows.ps1` resolves the console user via `Win32_ComputerSystem.UserName`;
  with nobody logged on it is null and both `fleet-selfpull` and `dotfiles-sync`
  are skipped. Run `provision\windows.ps1` from a normal login to register them.
- **`git --git-dir=~/.dotfiles --work-tree=$HOME ls-files` run from inside a
  subdirectory of `$HOME`** (e.g. `~/machines`) lists nothing — git derives a
  pathspec prefix from the cwd. `status` too. It looks exactly like an empty
  checkout; `cd ~` first. `add -u` / `diff --cached` are NOT prefix-limited, so
  the sync path is unaffected.
- **`git clone --bare` sets no `remote.origin.fetch`**, so a bare dotfiles clone
  has no `refs/remotes/origin/*` and every `origin/main` reference fails to
  resolve. The role configures the refspec and the sync script fetches with an
  explicit one; a repo cloned by hand needs
  `git --git-dir=$HOME/.dotfiles config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'`.
- **The dotfiles engine is verified live end-to-end on `air`** (2026-07-28):
  `~/.dotfiles` on branch `air`, upstream `metheoryt/dotfiles`, tree clean and
  0/0 vs `origin/air`, and `launchctl list` shows `kz.cyphy.dotfiles-sync`
  loaded with last exit 0 alongside `git-autofetch` / `fleet-selfpull` /
  `hermes-serve`. All seven branches exist on the remote (`main` + one per
  machine incl. `desktop-ubuntu26`). Branch `air` has **no upstream configured**,
  which is normal — `dotfiles-sync.sh` pushes `origin <branch>` explicitly and
  never consults `@{u}`, so `rev-list …HEAD...@{u}` fails while sync works fine;
  compare against `origin/<branch>` instead.
- **`dotfiles` reaches macOS by a different route than Linux.** `linux.sh`'s
  workstation `TIERS` includes `dotfiles`; `macos.sh`'s does **not** (pinned by
  `provision/tests/tiers.test.sh:82`). macOS gets it from the role front door
  (`provision/provision.sh --machine air --apply` → `provision/roles/dotfiles.sh`),
  which is what wired air. `tier_dotfiles_sync` is in neither array — it is called
  by `role_dotfiles` itself (`provision/roles/dotfiles.sh:144`), so the sync timer
  always follows the role, never the tier. Corollary: running only the driver
  (`just provision-mac air`) leaves a Mac with no dotfiles and no sync timer.
- Secret files (SSH keys, VPN keys) are never committed but ARE listed in that
  machine's branch `.gitignore` — the ignore entry itself is the "you need to
  restore/regenerate this on a fresh box" checklist, without storing the secret.
  Rotatable credentials (`.netrc`, `.npmrc`, `.pypirc`, `.aws/credentials`,
  `.config/gh/hosts.yml`) ARE tracked: the repo is private and the recovery
  story is "rotate the token", not "re-key the fleet".
- SSH keys are per-host, not shared (e.g. latitude5520's is
  `ssh-ed25519 ...  me-nixos-latitude5520`) — each fleet machine has its own
  keypair; cross-machine SSH trust needs each host's *public* key collected
  centrally (see fleet-mesh-vpn-ssh-design.md), not one key copied around.

## Backups

> **The per-drive operational record of the 2026-07 storage migration — UUIDs,
> byte counts, per-copy verification, SMART hours, the `/mnt/public` →
> `/mnt/spare320` and `/mnt/immich-backup` → `/mnt/immich-mirror` reformats —
> lives in `docs/2026-07-drive-migration-log.md` (archived 2026-08-01, verbatim).
> Read it before touching any drive on latitude. What stays here is the durable
> rules that outlive the migration.**

- ~~Fleet restic hub-and-spoke: every client backs up through resticprofile to/on
  the homeserver (REST server on port 8001, or local drives).~~ — **superseded
  2026-07-31**: the strategy is now mirror-the-bulk and **no restic repo is
  planned at all** (see the strategy bullet below). Kept as the pre-migration
  shape; g16's `laptop/music` profile was already retired 2026-07-07.
- ~~Homeserver's immich backup targets `G:`/`H:`~~ — **superseded 2026-07-31**:
  g513ie has only `C:`; those drives now live in latitude's docks. **The offsite
  gap itself still stands** — every copy is in one apartment, and the fix remains
  cheap (rotate one dock's drive off-site) rather than adding cloud/object
  storage. Task 19 of the migration plan owns it.
- latitude5520 has no dedicated backup today (the g16 NixOS side this bullet used
  to name was retired 2026-07-08). Whatever home-manager declares in this repo is
  already "backed up" by being in git; anything outside that scope (browser
  profiles, ad hoc `~/.config`, local documents) is not protected.

### Backup strategy (decided 2026-07-31)

- **Mirror the bulk, restic almost nothing.** The axis is *can this be
  re-derived, and does a wrong write propagate?* — a mirror covers drive death,
  only versions cover your own `rm`, a bad app write, or bitrot. Mirror
  (`rsync -aHAX`): the 2024 archive, `Media/movies|torrents|tv|xxx`,
  `ImmichMedia/library`, `music-from-g513ie`, the GoPro video, `qb`. Versions are
  genuinely needed for only ~1.5 GB — `Media/config` (jellyfin `encoding.xml`,
  the *arr SQLite DBs) and `secrets` — and at that size a dated `tar.gz` + rsync
  beats restic, so **no restic repo is planned** and the destroyed
  `immich-media` / `immich-postgres` repos are not being recreated.
- **`-H` is mandatory.** Media is 523059206143 B unique against 788634637218 B
  summed per-directory — 265 GB of hardlink overlap. Without `-H` the target
  needs 734 GiB instead of 487.
- **Never `rsync --delete` the immich library bare** — it is mutable and a photo
  deleted in the UI propagates. Use `--backup-dir=…/deleted-$(date +%F)`.
- **Never rsync live PGDATA.** The copy looks like a backup and is unrestorable;
  the `/var/backups/immich-db` dumps are the DB backup. Same torn-copy class:
  `Media/config` while jellyfin and the *arr apps run — best-effort, not
  restorable, and **chasing byte-exactness there is futile while they run**
  (verify by *which* files differ, not by the byte total).
- **A verification run against a live immich prints benign DIFFs.** Benign =
  confined to `library`/`thumbs`/`encoded-video` with src > dst and every
  `Media/*` OK; real = dst > src, any `Media/*` mismatch, or a large byte gap. On
  benign, re-run the same `rsync -aHAX` as a delta and re-verify.
- **Both job logs are root-owned** (the scripts run under `sudo`), so appending a
  hand-adjudicated verdict needs `sudo tee -a` — a plain `>>` fails *Permission
  denied* and the relaunched job silently re-reads the stale verdict.
- **Inspect a tree for credentials BEFORE rsyncing it to another drive.** The
  overnight `/mnt/xs/backup` → archive copy propagated desktop's private keys onto
  the archive drive. See the SSH key hygiene section.

### Disks and docks on latitude

- **Never send `hdparm -Y` (SLEEP) to a drive in a USB-SATA dock.** SLEEP clears
  only on a bus/power reset, so the drive stops answering the bridge entirely — a
  `/sys/class/scsi_host/hostN/scan` rescan cannot wake it, and on these two-bay
  docks the sibling bay goes with it. Use `-y` (STANDBY, wakes on access), and
  accept that recovery otherwise needs the user to power-cycle the dock.
- **The docks also reset unprompted — check the journal before blaming your own
  command.** Marginal cabling and physical knocks are a chronic fault mode here;
  dock B (`usb 4-1`) is the worst offender. Check with
  `sudo journalctl -k --since today | grep -aE "usb [0-9.-]+: (reset|USB disconnect)"`.
  Layout consequence: archive *primary* on dock A, *copy* on flakier dock B, and
  give any long write into dock B `--partial --append-verify` so a drop resumes.
- **`nofail` in fstab applies at boot only.** After any dock power-cycle or bus
  drop, every affected mount needs an explicit `sudo mount <target>`.
- **Every `/dev/sdX` letter reshuffles across a reboot — treat any letter written
  down anywhere as point-in-time only.** Five bus-powered USB spinners plus a card
  reader race to enumerate, and **USB port paths are not stable either**. Identify
  a drive by **UUID** (mounts), **bridge serial** in `/dev/disk/by-id/usb-*`
  (`6702002103E1` = dock A, `670200210032` = dock B; suffix `-0:0` is bay 1,
  `-0:1` bay 2), or drive model — never a letter. One enclosure passes a **fake
  serial** (`…_0123456789ABCDE-0:0`), so guard on the UUID too.
- **A SCSI rescan force-spins-up every sleeping drive on that host and re-adds
  bays you already detached**, so `echo 1 > /sys/block/<dev>/device/delete` is
  one-way only if you don't rescan afterwards; and reading SMART wakes a parked
  drive. To assert a device's identity *without* waking it, read
  `/sys/block/<dev>/device/{model,vendor}` plus `lsblk -dn -o SERIAL,WWN` — never
  `smartctl`. sysfs `model` is space-padded, so `grep -q` it rather than `[ = ]`.
- **`/mnt/xs` cannot be remounted read-write in place** — `ntfs3: Couldn't remount
  rw because journal is not replayed`, a dirty `$LogFile` from an unclean Windows
  shutdown. Needs a full `umount` + `mount -o rw`. That Ventoy stick is
  load-bearing, not scratch: with `~/staging/music` it holds the only two copies
  of the music collection until the planned mirror exists.

### Immich and restic

- **Immich makes its own `pg_dumpall` backups — do not build a second
  mechanism.** Defaults: enabled, `0 02 * * *`, keep last 14, ~218 MB each
  (~2.9 GB total); filenames carry both versions. **Two separate mechanisms must
  point at the same place** — the UI backup writes to `/data/backups` *inside*
  `immich_server` (i.e. `UPLOAD_LOCATION/backups`), while `DB_BACKUPS_LOCATION`
  only mounts `immich_postgres:/backups`; changing the env var alone moves nothing
  the UI writes (`bebf134` mounts both). On latitude the path is
  `/var/backups/immich-db` on the root NVMe — a different physical disk from the
  database, and never `nofail`. **Immich writes the dumps `root:root` 644**, so a
  non-root copy job can read but not prune them. `.env` is gitignored, so the path
  is machine-local; the tracked `.env.dist` still carries g513ie's `D:\` paths.
- **Immich's hardware-accel setting lives in the DATABASE, not compose** —
  `system_metadata` key `system-config`, `jsonb`, path `{ffmpeg,accel}`. A compose
  commit cannot carry it (same trap class as jellyfin's `encoding.xml`). Only
  *overrides* live in that row, so an absent key means "default", not "unset" —
  and **immich rewrites the row on startup**, dropping keys equal to the default
  and adding migrated-in ones. A hand-set value vanishing from the row does not
  imply the effective value changed; confirm in the UI. **Verify accel with a real
  encode, not a codec list:**
  `docker exec immich_server ffmpeg -f lavfi -i testsrc=size=1280x720:rate=30:duration=2 -c:v hevc_qsv -f null -`
- **Immich's realtime (on-the-fly HLS) transcoding 404s for every asset ingested
  before the `CreateAudioVideoTables` migration, and enabling it does not
  backfill.** `GET /api/assets/<id>/video/stream/main.m3u8` returns *"Asset
  metadata is not yet ready for streaming"* because
  `VideoStreamRepository.getForMainPlaylist` inner-joins `asset_video` /
  `asset_keyframe`, written only by the **Extract Metadata** job (on latitude:
  4 rows against 8729 video assets). `ffmpeg.realtime.enabled` defaults to
  **false**, so it only bites once someone turns it on. Diagnosing needs
  `logging.level: debug` in `system-config` — immich logs no successful requests
  at the default level, so an empty log proves nothing. Backfilling means
  **Extract Metadata → All**, which re-reads every original including the 712 GB
  2024 archive across the flaky dock-A bridge — do it deliberately. Falling back
  is one flag; pre-encoded `encoded_video` files exist for 8715 of 8729.
- **The restic password for the homeserver repos is tracked** — dotfiles allow-line
  `!/g513ie-prod-config/vps/backup/homeserver/pass.txt`; `~/my/vps/backup/homeserver/pass.txt`
  on latitude is a **symlink** at it, so the live path and the version-controlled
  copy are one byte-source. Don't create a second copy.
- **On a read-only restic repo, always pass `--no-lock`.** Without it `restic
  snapshots` against a `ro` mount hangs indefinitely with no output and no error.

### The backup topology, rebuilt 2026-08-01

- **The old homeserver restic repos are GONE, not merely unscheduled.** No
  `backup-homeserver` directory and no repo markers survive on any mount on any
  box: `G:\` and `H:\` were reformatted into `/mnt/servarr`, `/mnt/immich-2024`
  and friends during the migration, so **the migration consumed the backup
  drives**. There is no history to continue — anything built now starts at zero.
  g513ie has only `C:` left. Do not go looking for those repos again.
- **What the three `immich-*` scheduled tasks on `server` teach:** they sat at
  `State: Ready` with a live `NextRunTime` while every run since 2026-07-19
  returned `0x8007010B` ("the directory name is invalid") — they pointed at the
  moved `G:\`/`H:\`. A schedule that reports healthy while failing is worse than
  no schedule. Disabled 2026-08-01. **`Disable-ScheduledTask -TaskName x` without
  `-TaskPath` silently no-ops** — resticprofile registers under
  `\resticprofile backup\`; read `TaskPath` first, verify `State` after.
- **latitude is now the `backup-hub`** (moved off `server` in `fleet.json`,
  `69614ea`). Layers, deliberately different tools for different problems:
  - **rsync mirrors for the photo libraries**, because no drive in the fleet has
    815 G free for a restic repo and a config that cannot fit its sources just
    fails nightly. `mirror-refresh.sh` (daily 03:30) and `archive-mirror.sh`
    (monthly) — system timers, one shared `flock`, installed by
    `hosts/latitude/debian/install-timers.sh`.
  - **restic for the small irreplaceable set** — `/mnt/spare320/restic/latitude`,
    repo `14f4eab544`, covering the nightly pg_dumpall, ServarrConfig,
    xs-keepers and `~/my/vps` (for its seven gitignored `.env` files). 6.5 GiB →
    2.3 G. Backup 04:30 daily, `check --read-data-subset 5%` Sundays 06:00.
    Config `vps/backup/latitude/profiles.yaml`, `schedule-permission: system`
    because pg_dumpall output is root-owned.
  - **`restic-server` REST hub** for other boxes — `vps/homeserver/restic-server`,
    now bound to **`100.64.0.8:8001`, not `0.0.0.0`**. It runs `--no-auth`, so
    reachability IS authorisation; publishing on all interfaces exposed the
    fleet's backups to every device on the home wifi. Verified: tailnet answers
    405, LAN address refused. Costs a boot race (docker cannot bind before
    tailscaled is up) which `restart: unless-stopped` absorbs — check that first
    if the container is ever dead after a reboot.
  - `--append-only` is deliberately NOT set: it would break `forget --prune` and
    turn retention into a manual chore, and an unwatched manual step is exactly
    what caused this outage. Revisit if anything irreplaceable ever routes
    through the REST hub; today the photo libraries do not.
- **`desktop-wsl` backs up to the hub at `rest:http://100.64.0.8:8001/g614jv`**
  (repo `8ca511f48c`). Two traps found wiring it:
  - **resticprofile's `schedule-permission: user` needs root.** It installs a
    *root-owned* unit that merely runs as the user. `user_logged_on` is the one
    that makes a genuine `systemctl --user` unit — and despite the name it does
    **not** need a login session, because `Linger=yes` on that distro keeps the
    user systemd instance alive. If linger is ever disabled the backup stops
    firing silently. `show` reports the configured value, not the one it will
    demand, so it is not a useful check.
  - **desktop-wsl has no passwordless sudo and no TTY over ssh** (`sudo: timed
    out`). Not needed: restic and resticprofile are static binaries — install to
    `~/.local/bin`, and a `$HOME` backup under a user timer never wants root.
  - `{{ .Hostname }}` in the wsl profile expands to **`g614jv`**, the *Windows*
    hostname, not the distro nickname or tailnet node name — a WSL distro
    inherits its host's name. Both of desktop's distros therefore share one repo.
    Safe (restic keys snapshots by host+paths, so it dedupes) but it is not
    isolation. `$WSL_DISTRO_NAME` is absent from systemd units, so it is not a fix.
- **`ssh desktop-wsl` fails from air; `ssh desktop-wsl.gg.ez` works.**
  `tier_fleet_ssh` emits one `Host` block per **`fleet.json` member** plus a
  catch-all `Host *.gg.ez → id_fleet`. Self-declared WSL hosts are deliberately
  absent from `fleet.json`, so the bare name matches no block and falls through
  to the default `~/.ssh/id_ed25519`, which is not the authorized fleet key.
  Inbound trust is fine — the managed span on desktop-wsl carries all five keys
  including `me@air`. Use the FQDN, or reach it via `wsl -d desktop-wsl` on its
  Windows parent.
- **The gap that remains: none of this alerts.** Every job's failure mode is
  silence, which is the same shape as the `server` tasks that failed unnoticed
  for 13 days. `provision/statusboard/statusboard.sh` already has an alert strip
  on every page with a fixture-testable severity policy (`sb_fleet_alerts`,
  `sb_docker_alerts`) — a `sb_backup_alerts` keyed on newest-snapshot age is the
  right home for this, and is not built yet.

## SSH key hygiene (audited 2026-07-31)

- **desktop's live SSH identity is `SHA256:fFZUwTp9Ye4HukFntyjVplkAJxczc7GWz6ssWlcyg40`
  (`methe@me-g614jv`, ED25519).** Its `~/.ssh/config` pins `id_ed25519` for *every*
  host block — `githubcyphy`, `cyphy-hub`, `homeserver`, `latitude`, `air`,
  `desktop`, `server`, `hub`, `*.gg.ez` — and `Host *` sets no `IdentityFile`. That
  key is authorized on **latitude and hub**. Never revoke it while desktop is in
  service.
- **`SHA256:gA8eWbg6MwUFjg6IX135LEFKJ9nYHzM52nBDfojDI/o` (`methe@DESKTOP-4PQ6V6B`,
  RSA 3072) was retired from hub 2026-07-31** — 9 keys → 8, backup at
  `hub:~/.ssh/authorized_keys.bak-retire-rsa-20260731`. It was authorized only on
  hub and referenced by no ssh-config block. `desktop → hub` and `desktop →
  latitude` verified working after removal. Its private half still sits in
  `desktop:~/.ssh/id_rsa`, deliberately left alone: inert now that nothing
  authorizes it, and an unknown non-fleet host might still.
- **`/mnt/public/secrets` was never "a Windows-reinstall leftover" — it is a backup
  of desktop's LIVE private keys**, and the same pair also sits at
  `/mnt/xs/backup/secrets/` and `/mnt/xs/backup/home/.ssh/`. Group copies by
  `md5sum` of the private file (`aa9d26646442` = the live ED25519, `006d1b05cef6` =
  the retired RSA) — `ssh-keygen -lf -` does **not** read stdin, so pipe-to-
  fingerprint silently returns nothing and every key looks "ENCRYPTED_OR_UNREADABLE".
- **`backup.ps1` copies desktop's SSH private keys on purpose, and that rationale is
  now obsolete.** It was written by Claude for the July clean reinstall, *before the
  fleet key exchange existed* — restoring the old private key was how outbound access
  survived a wipe. It no longer needs to: `provision/fleet-authorized-keys` is a
  **tracked repo file that already carries desktop's pubkey** `fFZUwTp9…`, so a fresh
  install can `ssh-keygen`, replace that one line, push, and every fleet box picks the
  new key up through its own provisioning (`windows.ps1:252-268` writes it into
  `administrators_authorized_keys`). The capture points: **`backup.ps1:119`**
  (`Copy-Item "C:\Users\methe\.ssh\*"` → `secrets\`), the **generic dotfile sweep at
  `backup.ps1:144`** (`.ssh` is a `.*` dir and is not in the `$blocklist`, so it
  lands in `home\.ssh`), the **WSL tar at `backup.ps1:105`** (`.ssh .gnupg
  .gitconfig` per distro), and **`backup.ps1:228`** (`netsh wlan export profile
  key=clear` → cleartext PSKs). `restore.ps1:139` restores `.ssh` from **`home\.ssh`,
  not from `secrets\`** — so line 119's loose copy is redundant even for restore.
  The script's stated reason is "GPG keys are unrecoverable", which is legitimate in
  principle but did not apply: the captured `.gnupg` had a **32-byte empty
  `pubring.kbx`**. `backup.ps1:278` also advises making the second copy of `secrets`
  "off this SSD (server / **email**)" — emailing private keys.
- **Do not back up SSH private keys at all.** Correct recovery is regenerate +
  re-authorize (one minute); every copy is pure added exposure. Decision 2026-07-31:
  **not rotating** `fFZU…` despite four plaintext copies — the drives never left the
  apartment and were never handed to anyone. Delete the copies instead.
- **Lesson, learned the hard way: inspect a tree for credentials BEFORE rsyncing it
  to another drive.** The overnight `/mnt/xs/backup` → `/mnt/immich-2024-backup`
  copy propagated desktop's private keys onto the archive drive. Deleted
  2026-07-31 (`from-xs/backup/secrets`, `from-xs/backup/home/.ssh`).
- **`/mnt/xs/backup` holds 48 credential-shaped files** and is a Windows user-profile
  backup, so assume more. Notable: `OneDrive/Documents/PycharmProjects/card-
  processing/instance/keys/` has **Apple Pay merchant private keys**
  (`applePayProcessing.key.pem`, `applePayMerchantID.key.pem`, `merchant_id.pem.key`,
  `kolesa.private.pem`, `connectum.pem`); `Downloads/Telegram Desktop/` holds a
  **third party's** SSH keypair (`kalistudy@sb-a901301`, plus a 1675-byte
  `BEGIN RSA PRIVATE KEY`) received over Telegram, authorized nowhere on this fleet.
  Not this fleet's exposure, but it is someone's. Those all still sit on `/mnt/xs`
  itself (ntfs3 `ro`); only the propagated duplicates were removed.
- **`/mnt/immich-2024-backup/from-xs/backup` is deliberately NOT a faithful copy of
  `/mnt/xs/backup` any more.** Removed 2026-07-31: `secrets/` + `home/.ssh/` (live
  private keys) and `OneDrive/` 3.7 G — the latter because OneDrive is cloud-backed
  (verified live: `C:\Users\methe\OneDrive` on desktop, 3.8 GB / 13711 files, sync
  process running), and it carried the Apple Pay keys with it. Then `GoogleDrive/`
  5.8 G (desktop has `C:\Users\methe\GoogleDrive` and the tree is full of `.gsheet`
  pointer files, so the real content is cloud-side — though **no Drive sync process
  was running on desktop** at the time of checking) and `wsl/` 20 G (a single
  `Ubuntu-24.04.tar`, 20853483520 B, while desktop still has **Ubuntu-24.04
  installed** alongside the running Ubuntu-26.04 — the live distro outlives the
  export). **63 G → 34 G**; archive drive free went 122 G → 151 G. All of it still
  present on `/mnt/xs/backup`, which was never touched. Remainder: `Downloads` 30 G
  (received files, not re-derivable — still holds the third party's SSH key),
  `home` 2.7 G, `repos` 843 M, plus `inventory`, `logs`, `Obsidian`,
  `windows-reinstall-runbook.md`.
- **`repos/airdrome`'s unpushed work was rescued to GitHub 2026-07-31 — it existed
  nowhere else.** The branch `playlist-editing-tools` (6 commits: PlaylistMerge
  tombstone model, `merge_playlists` fold/tombstone/delete, `dedup_members`,
  `--same-name` sweep) was contained in no remote ref, and the repo was **missing
  from desktop entirely**. Remote `main` had only the design commit `ef148b8`, two
  commits behind the fork point. Pushed as `playlist-editing-tools` plus two
  orphaned stashes (whose branches no longer existed) as `wip/stash-go-cmd` and
  `wip/stash-refactor` — `git push origin "stash@{N}:refs/heads/<name>"` preserves a
  stash, which is otherwise unpushable and invisible to every "is it on the remote?"
  check. Verified after: every local branch and both stashes report 0 unique.
- **`repos/qaz-law` is superseded, not unpushed work.** Its remote moved to
  `github.com:metheoryt/qaz-code` (was `githubcyphy:cyphy671/qaz-code`), so the
  backup's stale `refs/remotes/origin/*` made it *look* like 19 unpushed commits.
  Against the live remote, `main` is a plain ancestor (28 commits behind, remote
  active today) and `feature/sync-dashboard`'s 19 commits are all `+` — but remote
  main carries `ff846ea feat: sync command rich terminal dashboard`, i.e. the
  feature landed reimplemented. Superseded earlier attempt, safe to drop.
- **Two git-forensics traps that produced wrong answers here.** (1) `git log
  --branches --not --remotes` measures against whatever stale `refs/remotes/*` the
  copy carries — worthless on a backup that has not fetched since. Always
  `git fetch <real-url> "+refs/heads/*:refs/remotes/probe/*"` first and compare
  against `probe/*`. (2) **The first `git status` on a freshly rsynced repo reports
  spurious modifications** — `rsync -rlt` preserves mtimes but not permissions, so
  the index stat-cache mismatches until that first run refreshes it. It reported 85 /
  19 / 47 dirty files across these repos; the true count was 0 in every one. Run
  `git status` twice, or `git diff --stat` to confirm content actually differs.
  From latitude all three of `id_metheoryt`, `id_cyphy671` and `id_ed25519`
  authenticate to GitHub as **`metheoryt`**, so a plain `git@github.com` remote works
  without any alias — the `githubcyphy` alias is genuinely absent here.
- **A stash is the thing most likely to be silently lost when a repo backup is
  deleted, and it disguises itself as commits.** `git rev-list --all --not --remotes`
  counts **3** objects per stash (the stash commit plus its index and
  untracked-files parents), so one stash reads as "3 unpushed commits" —
  that is exactly what `repos/vasya` showed. Stashes are also **per-clone**: the
  live checkout on another machine has its own (empty) stash list, so "the repo
  exists on desktop" never covers them. `repos/vasya`'s single stash
  (`.mcp.json` +12/−1, `pyrightconfig.json` +10/−3, "sdd-pre-reminders … restore
  after feature", on a branch not even checked out locally) existed nowhere else and
  was pushed 2026-07-31 as `wip/stash-sdd-pre-reminders` (`112c9cf`). Check
  `git stash list` explicitly before deleting any repo copy — `qaz-law` and `nix`
  had none.
- **When globbing paths with spaces, quote or use `-print0`.** An unquoted
  `$(find …)` split `Downloads/Telegram Desktop/id_rsa.pub` into two words and
  silently produced empty fingerprints for exactly the files that mattered most.

## Repo tooling & scripts

- **The status board's power + drive-temperature feature is in `96a3c69`, whose
  message describes only the macOS Docker cask tier.** Two sessions had
  overlapping working trees on 2026-07-30 and that commit swept up the other's
  staged changes. Matters because one part is a **security decision that the
  commit message does not mention**: `tier_rapl_read` widens
  `/sys/class/powercap/intel-rapl:*/energy_uj` from `0400 root:root` to `0440
  root:<group>` so the board can read the CPU energy counter as a non-root user.
  The kernel restricted that file after PLATYPUS (CVE-2020-8694) recovered AES
  and RSA keys through it. On latitude it grants no new capability — the board's
  user is already `NOPASSWD ALL` — and it is group-scoped rather than `0444` to
  keep that true; RAPL subdomains (`:0:0` core, `:0:1` uncore) stay `0400`.
  `6f3cccf` carries the full reasoning. Grep for `tier_rapl_read`, not the commit
  message, when auditing.
- **`-n standby` does not protect the USB spinners on latitude** — of five, only
  `sdf`'s bridge implements CHECK POWER MODE, and `sdf` is the one drive with no
  SMART temperature at all. The four that report a temperature all answer `CHECK
  POWER MODE not implemented, ignoring -n option`. The board gates on **APM
  level** instead (ATA: 1-127 permit standby, 128-254 forbid it): the two drives at
  128 are polled freely, and the two low-APM ones (96, and the HGST at 1 — already
  past 639k load cycles) only while they are doing IO. Don't "simplify" that back
  to `-n standby`. Letters in the original note were reboot-unstable, so the board
  must re-derive APM per device at runtime, never from a hardcoded letter.
- **The board is PAGED, and its binding constraint is rows, not CPU.** `SB_PAGES`
  (`system fleet docker`) rotates every `STATUSBOARD_PAGE_SECS` (**5**); a page is a
  `sb_page_<name>` function plus a word in that list, and `--page <name>` renders
  one (unknown name exits 2, which is what lets the tests loop over the set). The
  **system page is 26 lines into a 27-row pane** with today's 8 mounts and both
  conditional rows — one spare. A 9th mount overflows, and a wrapped row makes the
  whole repainting frame walk up the screen. Every page carries the one-line alert
  strip because a hidden page cannot report a fault; do NOT "improve" that to
  holding on the failing page, since a flapping box would then never show anything
  else. Two traps the code comments name: `read -t` for keypresses must be guarded
  on `[ -t 0 ]` (stdin closed makes it a 100%-CPU spin on the kiosk), and sampling
  stays unconditional in the loop — sampling only the visible page would put holes
  in every chart, or cells that lie about their duration.
- **Keyboard paging DWELLS, it does not hold** (2026-07-31). Arrow keys / `n` `p` /
  `1..9` set a `STATUSBOARD_PAGE_MANUAL_SECS` (60) deadline and the rotation resumes
  by itself; only **space** holds indefinitely. Manual selection used to set
  `SB_PAGE_HOLD=1`, which killed the rotation for the rest of the session. And an
  arrow key is THREE bytes (`ESC [ C`): read one byte per loop iteration, its second
  byte is a bare `[` — the old "previous page" binding — so both arrows paged
  BACKWARDS and each press stopped the board. The ESC tail is drained in the same
  `sb_wait_key` call (`read -t 0.05 -n 2`), and `O`-form sequences are handled for
  tmux/ssh. The read needs **`IFS= read`**: without it the SPACE key is word-split
  away and arrives empty, so the hold had never worked at all — invisible because
  every other binding is a non-whitespace character. Verified live by driving the
  board through a pty (`script -q -c … /dev/null` with a `( sleep 3; printf " " )`
  pipeline) and counting page markers per frame — the only way to test the key path,
  since it needs `[ -t 0 ]`.
- **The disk block names BAYS, not `sdX`** (2026-08-01). Kernel letters are handed
  out in discovery order and name nothing physical, which is useless in front of five
  identical 2.5" spinners in three docks. Two layers: `sb_bay_tag_parse` derives a tag
  from `readlink -f /sys/block/<d>/device` — `u<bus>-<port>:<lun>` for USB, the
  controller name for NVMe — and a per-host map (`provision/statusboard/disks.<hostname>.conf`,
  `STATUSBOARD_DISKMAP` overrides) renames tags to what the docks are called in the
  room. Derived from `/sys/block/*/device`, never `/dev/disk/by-path`: that tree has
  TWO symlinks per USB device here (`-usb-` and `-usbv3-`), so scanning it only looks
  deterministic. The port path and LUN are physical; the BUS index is xHCI enumeration
  order, which is why the map renames a derived tag instead of hand-writing paths.
  latitude's storage, as mapped 2026-08-01: **two identical UGREEN CM198 docks** —
  dual-bay 2.5"/3.5" SATA-to-USB3, externally powered, each ONE bridge with two LUNs —
  are `dockA0`/`dockA1` (`u4-1:0`, sdb; bay 1 empty) and `dockB0`/`dockB1` (`u4-2:0`
  sdc, `u4-2:1` sdd). `usbcXS` (`u2-2:0`, the portable XS2000) is a USB-C port with no
  adapter; `hubSATA` (`u2-1.4:0`, sdg) is the other USB-C port into a PD hub into a
  SATA-USB3 adapter, so the hub is 2-1 and the adapter sits on its port 4. A dock bridge
  reports only POPULATED LUNs — nothing appears at `u4-1:1` until a disk goes in — which
  is the opposite of the card reader (`u2-1.3:0/1`, on the same hub), whose two slots
  exist as 0B nodes with no card in them.
- **A 0B disk is an empty card slot, not a disk** (2026-08-01). latitude carries a
  two-slot reader (`SD/MMC` + `Micro SD/M2`, one serial, `sde`/`sdf`) whose block nodes
  exist with no card in them, so the board permanently warned `disks unmounted` about
  two empty slots. `sb_unmounted_parse` drops zero-size disks — filtering on SIZE, not
  on the model name, so a card that IS inserted acquires a size and counts again. Do
  not switch that `lsblk` call to `-b`: the same field is what the row prints, and
  `298.1G` would become raw bytes.
- **`transient <mount>` in the disk map: a disk that is SUPPOSED to leave** (2026-08-01).
  df keeps reporting an unplugged filesystem forever, so the portable XS2000 sat on the
  board as a permanent `!! gone !!` row plus a `bad:1 mount gone` alert describing its
  normal state. A transient mount's gone row is dropped in BOTH places (the disk block
  and `sb_alerts`, which would otherwise shout about a row nobody can see). Keyed by
  MOUNT POINT because it is the only key left — a vanished device resolves to no drive,
  so neither bay nor tag exists to match on. Only the gone row: plugged-in-but-unmounted
  still lists, with its eject verdict.
- **The unmounted row carries a verdict, and temps below warn are GREEN** (2026-08-01).
  `safe` = nothing mounted off the drive and `/sys/block/<d>/inflight` all zero; `busy`
  = a request still outstanding, so pulling the cable loses data. The row stays ONE
  line (capped at four drives, then `+N more`) because six unmounted disks once squeezed
  the chart column for every other row. And `sb_temp_cell` now paints a reading below
  the warn threshold `C_OK`: `sb_hi_colour` answers `C_DIM` there, the same non-colour
  as `-` and `zzz`, so a drive at 38C looked identical to one that could not be read.
  Thresholds unchanged (50/55 spinner, 70/80 flash) — only the below-warn band gained a
  colour, and `zzz`/`-` deliberately did not.
- **The paint OVERWRITES; it must never erase first** (2026-07-31). `printf
  '\033[H\033[2J'` as its own write(2) before the frame left the pane genuinely
  blank for an instant, tmux flushed that blank downstream on its own event-loop
  wake, and foot presented it whenever a refresh landed in the gap — read as a blink
  every 2-5s on a 1s loop, irregular and NOT aligned to a page rotation (every paint
  carried the same gap). It was not a size problem: the frame is one read, 3708 bytes
  for the system page at 146 columns. Now one write: `\033[H`, the frame with a
  `\033[K` (EL) before every newline, and a trailing `\033[J` (ED) — no blank state
  exists to present, a torn read shows the PREVIOUS frame, and ED is also what lets
  the 26-row system page hand over to an 11-row one without leftovers. The trailing
  newline went too, so the cursor parks on the last row and cannot scroll the frame.
  A test asserts `[2J` appears on no code line, since reintroducing it breaks nothing
  else.
- **A bash signal handler RESUMES the script when it returns.** `trap cleanup EXIT
  INT TERM` therefore never stopped the board: it restored the cursor and went back
  to painting, so every `systemctl stop/restart statusboard` sat out the 90s stop
  timeout and ended in a SIGKILL (measured on latitude 2026-07-31, fixed with
  `trap 'cleanup; exit 0' INT TERM HUP`). Any long-running loop script in this repo
  needs the `exit` in the handler, not just the tidy-up.
- **The disk block is grouped by physical drive, and the bay leads each row.**
  `sb_mounts` emits its lines ORDERED (root's drive first, then by drive, then by
  mount), which is what lets the block group by ADJACENCY — the second filesystem of
  a bay prints `╰` instead of repeating the name. The sort key strips the partition
  suffix textually (`sub(/p?[0-9]+$/…)`), deliberately NOT `sb_disk_of`: that is a
  readlink per mount and this is only ordering; the DISPLAYED bay still comes from
  sysfs via `SB_DISKOF`. The bay column REPLACED the trailing device column rather
  than joining it — every text column comes out of the chart width — and a `gone`
  row shows its partition node there, since a vanished device has no drive to name.
- **`psys` is not wall power.** The board's `power` row is the RAPL platform rail
  — CPU, GPU, memory, board logic — reading ~16-19W on latitude. The five
  bus-powered USB spinners sit outside it, so real draw is well above what the row
  says. The row prints the domain name (`psys`, or `package-0` where psys is
  absent and the figure is ~3x smaller) precisely so it cannot be misread.
- **Never capture `btop` to a file — it never stops writing.** Measuring btop's
  minimum row count during statusboard-gui work left `bash -c 'btop
  >/tmp/btop-N.log 2>&1'` orphaned on latitude: with no terminal it exits
  nothing, redraws forever, and each frame is a full-screen ANSI dump. One such
  process reached **1.68 GB in 30 hours** (found 2026-07-31, killed), on `/tmp`
  which is a 12G tmpfs here — so it consumes RAM, not the root disk, and no
  logrotate or tmpfiles rule touches it. Nothing in the repo does this; it is an
  interactive-probing trap. To measure btop's layout use a sized pty
  (`tmux new-session -d -x <cols> -y <rows>` then `capture-pane -p`), which ends
  when the session does.
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
- The Orca worktree dispatchers are `agents/worktree-setup.sh` (Setup hook) and
  `agents/worktree-teardown.sh` (Archive/delete hook). Setup gortex-tracks the
  worktree (only when the daemon is already up), links the generic gitignored
  config set (`.env`, `.claude/settings.local.json`), then delegates to the
  first repo-local script found (`.orca/worktree-setup.sh` →
  `docker/worktree-setup.sh` → `.worktree/setup.sh` → `scripts/worktree-setup.sh`).
  Teardown runs a repo-local teardown (if present) then gortex-untracks +
  reconciles. Both are always non-fatal (exit 0) so they can't block worktree
  creation/deletion. The paste-into-Orca one-liners are
  `bash "$HOME/machines/agents/worktree-setup.sh"` (Setup) and
  `bash "$HOME/machines/agents/worktree-teardown.sh"` (Archive).
- **`settings.json` is a bootstrap COPY, not a symlink**
  (`copy_managed` in `agents/bootstrap.sh`, added 2026-07-25). Orca injects its
  `agent-hooks` block into the live files (`/home/me/.orca/agent-hooks/*.sh`); as
  symlinks those writes dirtied the tracked baseline and jammed convergence's
  clean-tree gate. `copy_managed` seeds a real file + a sibling `.<name>.srchash`
  stamp, re-seeding ONLY when the committed baseline hash changes (a pull/switch),
  so tool injection stays machine-local and the working tree never dirties. Re-seed
  fires from provisioning (post-merge / linux.sh / windows.ps1 / nixos switch),
  never from worktree-setup (the copy is machine-global). Every OTHER agent file
  stays a `link`. On NixOS a copy is durable only after commit+switch (the store
  bootstrap must carry the new `copy_managed`).
- **Claude merges `~/.claude/settings.json` + `settings.local.json` by
  WHOLE-KEY REPLACE for object maps** (`enabledPlugins`, `extraKnownMarketplaces`)
  — a partial split is silently ignored or wipes the other file's entries (Claude
  bugs #17942/#25086). Only ARRAYS union (`permissions.allow`). So: keep
  `enabledPlugins`/`extraKnownMarketplaces` whole in the committed `settings.json`
  baseline; only array-valued opt-in config (e.g. `mcp__gortex__*` allow) may live
  in machine-local `settings.local.json`. gortex permission was moved there
  2026-07-25 so the baseline carries only manually-configured, portable settings.
- ~~Per-host agent-memory filenames use the raw OS hostname~~ **superseded
  2026-07-28**: there are no per-host memory *files in this repo* any more.
  Per-host memory is `~/.claude/host-memory.md`, one per box on its own dotfiles
  branch, so no host id is involved. `MACHINES_HOST_ID` is still passed by
  `modules/home/claude.nix` but is now inert; `host_id()` survives in
  `bootstrap.sh` only as the canonical hostname-sanitization spec that
  `provision/lib/fleet.sh` and friends cite by name.
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
- **The repo-root `CLAUDE.md` is a symlink to `AGENTS.md`** (this repo's own
  instructions). A tool with a symlink guard (won't write through a symlink) edits
  nowhere useful if pointed at the `CLAUDE.md` path — edit the real `AGENTS.md`
  target. `agents/AGENTS.md` and `agents/CLAUDE.md` no longer exist: that content
  is `~/.claude/CLAUDE.md` on dotfiles `main` since 2026-07-28.
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
  needed for non-Claude agents (Cursor et al.) that load no plugin.
- **Orca auto-injects hook wiring into `agents/settings.json` on launch** (SHARED
  tier — committing it pushes fleet-wide) and re-injects on the next launch.
  Prefer NOT to commit it.
- **Orca profiles are harvested OUT to $HOME by default (2026-08-01).** The live
  account dir works — Orca picks up the account and its sessions from it — so the
  default is to leave it alone and rsync it out:
  `agents/orca-profile-harvest.sh` copies each account to `~/.claude-profiles/<name>`
  with ARCHIVE semantics (no `--delete`; a vanished transcript survives in the
  copy), excluding the regenerable trees (`plugins/` alone is 18MB of the live
  26MB; the payload is ~5MB of transcripts). The copy keeps the curated set as
  symlinks, so it is a usable profile —
  `CLAUDE_CONFIG_DIR=~/.claude-profiles/pure claude` reads old sessions outside
  Orca. Pairing is recorded in `.orca-source` and keyed on the account's own
  `accountUuid`, falling back to the Orca dir id — deleting an account and
  signing back in mints a NEW `<orca-profile-id>`, so id-only pairing would
  refuse the re-login as a stranger and `--restore` would write into the dead
  dir and still print ✓. A hand-rename sticks either way. Runs at the end of
  every personal bootstrap; `--restore <name>` copies back, follows the account
  if its dir moved (`--to` overrides), and refuses into a live profile.
  Read-only w.r.t. Orca — no symlink in its tree, nothing to migrate, no
  coupling to its layout. Trade: the copy is a snapshot. The snapshot itself
  cannot be lost to a re-auth: with no `--delete`, a blank or missing source
  copies nothing and removes nothing — only `--mirror` propagates deletions.
- **Relocating the profile is the stronger alternative (2026-08-01).** Orca
  runs Claude Code against `~/.local/share/orca/claude-accounts/<orca-id>/auth` — a
  dir it owns, keyed by an Orca-internal id, holding all transcripts/sessions
  (26MB here — 18MB of it regenerable `plugins/`; ~5MB is transcripts, and the
  525MB figure quoted earlier was `~/.claude`'s own history, not this dir) and
  reachable by no `.claude-<postfix>` convention (basename is
  `auth`). `agents/orca-profile-link.sh` moves it to `~/.claude-profiles/<name>`
  and leaves a symlink, so the profile outlives the account dir: Orca re-creating
  it now costs THE LINK, not the data, and `--relink` folds the fresh auth state
  in and restores it (also run automatically before each sync). It refuses to
  relocate a profile with a live session (`CLAUDE_CONFIG_DIR` + a `/proc` sweep);
  `--relink` skips rather than aborts, since it runs unattended after every pull.
  `~/.claude-profiles/` is its own namespace so `bootstrap.sh`'s secondary-profile
  registry cannot claim it. Population is separate: `agents/orca-profile-sync.sh`
  symlinks the **live** `~/.claude` content into each account dir — not the repo
  baseline, because an Orca profile also needs the machine-local parts the repo
  never carries (`gortex install` output, plugin state). It **fills gaps only**: a
  real file in the destination is never overwritten, since gortex regenerates
  `commands/`/`agents/`/`gortex-*` skills per profile and the account copy is often
  NEWER than the primary's. `settings.json` is a jq deep-merge (primary wins,
  target extras survive, permission arrays unioned), never a symlink. Runs at the
  end of every personal `bootstrap.sh`; `just agent-sync-orca` on demand. The
  mirror set is an allowlist and reports any unrecognised top-level path in the
  primary so layout drift is visible rather than silent. `PROFILE_FILES` +
  `PROFILE_DIRS` ARE the curated "what belongs in every profile" list — edit those
  two to change it. The sync follows the link to the real profile and finds a
  migrated profile by its `.orca-account` marker even when the link is broken.
- **Never bootstrap an Orca account dir as a secondary profile (2026-08-01).** Its
  POSTFIX resolves to `auth`, so the fallback deployed the tracked baseline over
  the mirror. `git-hooks/_refresh-claude-config` did exactly that after every
  pull/checkout by passing the shell's inherited `CLAUDE_CONFIG_DIR` through —
  one `git stash` round-trip re-seeded a live account's `settings.json` and moved
  the merged file to `.bootstrap-bak`. Fixed at both ends: the hook runs bootstrap
  under `env -u CLAUDE_CONFIG_DIR`, and bootstrap redirects an Orca dir to the mirror.
- **Codex was retired fleet-wide 2026-08-01.** `agents/codex/`, bootstrap's
  `IS_PERSONAL` Codex block, the `agent_clis codex` installer arm and
  `pkgs`-level `codex` are all gone; `~/.codex` (627MB, almost entirely vendored
  release binaries) is deleted on `desktop`. Unused in practice. The plugin's
  `hooks/hooks.json` still passes the config dir as an argument rather than
  deriving it — that is what made a second agent deployable, so keep the shape if
  another one ever arrives. Driving extra profiles through `$CLAUDE_CONFIG_DIR` is
  deprecated generally; Orca's own account dirs are the one surviving user.

## Pending follow-ups

- **Profile-aware `touches_linux` (deferred by decision 2026-07-25).** The regex is
  profile-blind, so a routine `pkgs/gortex.nix` bump re-runs hub's whole tier list on
  a box that never runs gortex. Cheap now that the list is lean (8 tiers, all
  idempotent), so it was left as-is rather than teaching `converge.sh` about
  profiles. Fix only if the churn starts costing something.

- ~~**Retire the WSL distro as a separate fleet host** (stated 2026-07-19)~~ —
  **ABANDONED 2026-08-01.** The opposite shipped: self-declared WSL hosts carrying
  a gitignored `fleet.local.json`, `dispatch:direct|parent` routing through the
  Windows parent, `just provision-wsl <nickname>`, and `desktop-wsl` living as a
  real tailnet node at `100.64.0.6`. The WSL-leaf facts above are current, not
  pending removal. (The `agents/hosts/g614jv.md` this item referenced no longer
  exists either — per-host memory moved to `~/.claude/host-memory.md` 2026-07-28.)

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

## Fleet migration 2026-07 (MacBook primary, latitude → server, retire G15)

Plan: `docs/superpowers/plans/2026-07-27-fleet-migration-mac-primary-latitude-server.md`.
Work branch: `worktree-fleet-migration-mac-primary`.

- **Kingston NVMe attach method: THUNDERBOLT ENCLOSURE** — decided 2026-07-27
  from `dmidecode -t slot` + `lspci -t` on latitude. No free M.2 2280 socket.
- **`dmidecode -t slot` is NOT a reliable M.2 inventory on the Latitude 5520.**
  It reports three PCIe slots and none of them is the NVMe: the live KIOXIA sits
  at `00:1d.0` (bus 72) and appears in NO slot entry at all. What the three
  entries really are: "PCI-Express 0 / x16 / In Use" = `00:1c.0` → bus 71 →
  Realtek **card reader** (not x16, not the SSD); "PCI-Express 2 / x1 / In Use" =
  `00:14.3` → **Wi-Fi AX201**; "PCI-Express 1 / x1 / Available" = `00:1c.5`, an
  **empty x1 root port** = the WWAN slot. Always cross-check with
  `lspci -t -v` — a slot's `Bus Address` maps it to the real device.
  Corollary: absence from the slot table proves nothing, since the occupied SSD
  socket is absent too. The decisive evidence is lane width — a second NVMe
  needs its own root port and the only free one is x1, which Dell never wires
  for an SSD.
- **latitude has Thunderbolt 4** (`00:0d.0` USB controller + `00:0d.2` NHI,
  Tiger Lake) and `bolt` is already enabled — so TB3/TB4 enclosure (~2.5-3 GB/s)
  over USB 3.2 Gen2 (~1 GB/s) for the live Immich upload tier the DB reads
  against. `00:07.0`/`00:07.1` with their large empty bus ranges are the TB PCIe
  tunnels, not M.2 sockets.
- **`dmidecode` is not installed on NixOS.** Run it as
  `nix build --no-link --print-out-paths nixpkgs#dmidecode` then
  `sudo <path>/bin/dmidecode …` — `sudo nix shell …` fails because sudo resets
  PATH.
- **2 TB staging drive:** *deferred* — decided 2026-07-27 not to decide yet. If
  ultimately skipped, Task 12 uses the G→H shuffle fallback and there is no
  off-site copy of the live upload tier until Task 19. Recorded so the residual
  gap does not quietly become permanent.
- **`air` tailnet address is `100.64.0.7`, not `.5`.** Live `headscale nodes
  list` (2026-07-27): hub .1, latitude .2, server .3, desktop .4, **ipheoryt12
  .5**, **desktop-ubuntu26 .6** (that node is `desktop-wsl` since 2026-08-01). The iPhone and the WSL host are real tailnet
  nodes that never appear in `fleet.json` — always read Headscale, never infer
  the next free address from the manifest.
- ~~**Per-host memory path is `agents/hosts/<detect.hostname>.md`**~~ —
  **removed 2026-07-28** along with the `tiers.test.sh` stub guard. bootstrap no
  longer seeds anything into the repo, so a new host cannot dirty the tree and
  cannot disable `fleet-selfpull`'s clean-tree gate this way. Historical note: it
  was NOT top-level `hosts/` (that holds NixOS/Windows machine configs). Add
  the stub in the SAME commit as the manifest entry.
- **`provision.sh` and `linux.sh` are unrelated entry points.** `linux.sh` is a
  standalone tier driver (`bash provision/linux.sh`); `provision.sh` is the role
  front door (`bash provision/provision.sh --machine <m> --dry-run|--apply` —
  flag syntax, a bare positional exits 2). `provision.sh` never invokes a tier
  driver. `provision/macos.sh` is therefore a sibling of `linux.sh`.
- **Platform dispatch lives in `provision/roles/*.sh`, not in `lib/fleet.sh`.**
  `lib/fleet.sh` and `lib/Fleet.psm1` are pure manifest readers with no `case` at
  all. Each role executor ends in a `*)` arm that prints "no posix executor" and
  **returns 0** — an unlisted platform provisions nothing and reports success.
  `provision/tests/roles.test.sh` guards that. `fleet-dispatch.sh` already routes
  everything non-`windows` to plain ssh, so new POSIX platforms work there free.
- **No `role_services` exists** (only `agents`, `dotfiles`, `repos`). Declaring an
  unimplemented role in `fleet.json` is safe — `provision.sh:72-78` prints
  "not yet implemented (skipped)" and continues.
- **[HISTORY — the unit is DELETED, see `9b8d63c`; kept for the passphrase-key
  lesson, which still binds]** latitude's `nix-repo-auto-pull` had been failing
  silently (found 2026-07-28
  while enrolling `air`). Every 5 min it logged `git@github.com: Permission denied
  (publickey)` and the unit still **exits 0** — `systemctl` reports "Finished
  successfully", so nothing surfaces outside `journalctl -u nix-repo-auto-pull`.
  Cause: `/home/me/.ssh/id_ed25519` is **passphrase-encrypted** (`aes256-ctr` /
  `bcrypt` in the private-key header). The key is correctly registered on GitHub
  ("me@NixOS Latitude 5520", `…IBnl…`) and *interactive* pulls work because the
  login shell has an ssh-agent — but a systemd service has no agent and no TTY.
  Consequence: **latitude cannot self-heal.** It sat at `369bbf4` while the rest
  of the fleet moved on, and no converge can fire because converge is triggered
  by the pull. Unblock it with a manual `git -C ~/machines pull --ff-only` from a
  shell that has the agent.
- **`provision/fleet-authorized-keys` was in neither converge predicate** (fixed
  `de07b77`). It is a real provisioning input on both tiers — `keyFiles` in
  `modules/system/ssh-server.nix:50` (nixos, baked at build time → needs a
  rebuild) and `tier_fleet_ssh`'s merge into `~/.ssh/authorized_keys` (linux) —
  yet matched neither `touches_nix` nor `touches_linux`. Enrolling a new member's
  key therefore wrote ok, advanced converged-rev, and was **never applied** on
  latitude or hub. Windows was unaffected (it reprovisions unconditionally).
  Same silent-skip class the `fleet.json` arm of `touches_nix` already guards.
- **A fleet box you cannot SSH into is still reachable by hopping** through one
  whose key is already trusted: `ssh desktop 'ssh me@latitude "…"'`. Note the
  explicit **`me@`** — desktop is Windows, so its default remote user is `methe`
  and a bare `ssh latitude` authenticates as the wrong account.
- **`~/.gitconfig` had two owners; the second one is gone.** `tier_git_base`
  (`provision/lib/tiers.sh`, via `git config --global`) writes it at tier time.
  The chezmoi template that used to overwrite it wholesale at role time
  (`dotfiles/dot_gitconfig.tmpl`) was **deleted 2026-07-28** — it had drifted far
  enough to drop the delta pager, the gh credential helper, all aliases,
  `pull.rebase`, `push.autoSetupRemote`, and the cyphy671 identity `includeIf`
  (→ silent commit misattribution).
- **`~/.gitconfig` and `~/.ssh/config` are host-local, and promoting them to
  `main` would break sync — settled 2026-07-28.** Both are tracked on dotfiles
  branch `air` only (`b8c4f56`); every other branch, `main` included, carries
  neither. Three independent reasons they must never reach `main`: (1) air's copy
  holds absolute `/Users/me/…` paths (the cyphy671 identity `includeIf`,
  `safe.directory`) that read `/home/me/…` on the Linux boxes — the rule is
  *anything carrying an absolute path is host-local no matter how generic it
  looks*; (2) `tier_git_base` still writes `~/.gitconfig` via `git config
  --global` on **every** tier box, so a shared copy has a writer outside the
  dotfiles engine; (3) mechanically, `dotfiles-sync.sh` stages with `add -u`, so
  a shared `.gitconfig` would have each box commit its own variant to its machine
  branch every 10 min and then re-conflict against `origin/main` on the merge
  step — forever. That is the failure D5 (shared XOR host-local) exists to
  forbid.
- **Fleet trust is not symmetric, and `fleet-authorized-keys` is the map.** As of
  2026-07-28 it holds latitude, g513ie(server), wsl-desktop, me-g614jv(desktop)
  and air — **no `hub` key**. So hub is reachable *from* the fleet but cannot
  reach *into* it (consistent with its `backup-client` role, but undocumented
  until now). That is why diagnosing an unreachable latitude has to hop through
  `desktop`/`server`, never through `hub`.
- **A dirty tree silently strands a box indefinitely.** `fleet-selfpull` gates on
  a clean working tree, so ANY uncommitted change stops every pull with no alarm.
  Found 2026-07-28: `desktop-ubuntu26` sat **23 commits behind** because an agent
  had left 10 uncommitted hermes-skill items there. Nothing surfaces this — the
  box looks healthy, `fleet-selfpull.timer` is `active`, and cron is installed.
  When a fleet member is mysteriously stale, check `git status` FIRST, before the
  timers or the converge predicates.
- **`git rebase` does not fire `post-merge`, so it does not converge.** The
  convergence trigger on non-Nix boxes is the `post-merge` hook, which only runs
  for *merge*-shaped pulls. After bringing a diverged box up to date with
  `fetch` + `rebase`, run `bash scripts/converge.sh` explicitly or the pulled
  change is never applied.
- **The `~/gh/` layout is gone on `desktop-ubuntu26`.** Repos live in the
  `repos.sh` per-account layout: `~/my`, `~/cyphy671`, `~/machines`. So
  `qaz-code` is at **`~/cyphy671/qaz-code`**, not `~/gh/qaz-code`.
- **`gh` 404s on another account's private repo, which is NOT evidence it is
  gone.** Checking whether a transfer completed, `gh api repos/cyphy671/<x>` as
  metheoryt returns 404 for a *private* repo of that other account. Test for the
  **destination** (`gh repo view metheoryt/<x>`) instead — that one is
  authoritative because the token owns it.
- **latitude's `id_ed25519` is deliberately passphrase-less AND keeps push
  access** (decided 2026-07-28). Stripping the passphrase was the chosen fix for
  the auto-pull failure; a read-only deploy key was offered and **declined** on
  purpose, because latitude stays read/write for pushing directly from the box.
  So the tradeoff is accepted, not outstanding: that one plaintext file is both
  the GitHub push key and the fleet-inbound identity, i.e. anything that can read
  it has full push access to every repo. Do **not** "fix" this by narrowing it
  without asking — revisit only if latitude stops being a box you commit from.
- **Committing directly on latitude will stall its auto-pull — visibly or
  silently, depending on how.** (Written against `nix-repo-auto-pull`, deleted in
  `9b8d63c`; the same two failure modes hold for its replacement
  `fleet-selfpull`.) The old unit skipped on a **dirty tree**
  (`exit 0`, one log line, easy to miss — the same failure mode that stranded
  `desktop-ubuntu26` 23 commits behind), and fails loudly on a **non-ff
  divergence** (`exit 1`, shows in `systemctl --failed`). So after committing on
  latitude: push promptly and leave the tree clean, or the box quietly stops
  syncing with the rest of the fleet.
- **One auto-pull mechanism fleet-wide now** (`9b8d63c`). `nix-repo-auto-pull` /
  `modules/system/self-update.nix` is **deleted**; NixOS runs the same
  `provision/fleet-selfpull.sh` as every other member, via
  `modules/system/fleet-selfpull.nix` (`services.fleetSelfpull`). latitude
  therefore keeps `~/my/vps` fresh too, which the old single-repo puller never
  did. Converge is unaffected — `machines-converge.path` watches
  `.git/logs/HEAD`, so it fires for whoever moved HEAD.
- **`fleet-selfpull.sh` had the same silent-failure bug** that
  `nix-repo-auto-pull` did, and it had to be fixed before NixOS could adopt it:
  it **always exited 0**, and reported *every* pull failure as `SKIP diverged`,
  filing an auth failure as a branch-topology fact. Now fetch and merge are
  split so the two are distinguishable, a real error exits non-zero, the
  deliberate skips (`not-main` / `dirty` / `diverged`) stay clean, and the fetch
  retries once. Guard: `provision/fleet-selfpull.test.sh`, 18 assertions.
- **Two timers fetch the same repos — keep their `OnCalendar` off a shared
  boundary.** `fleet-selfpull` is `*:03/10` (:03/:13/:23) precisely so it never
  lands on `git-autofetch`'s `*:0/10` (:00/:10/:20). Sharing that boundary made
  concurrent fetches collide on `refs/remotes/origin/main` and the loser fail.
  If you ever retune either interval, re-check the offset.
- **NixOS's auto-pull script is no longer immutable, and that is a real
  tradeoff.** The old inline script was baked into `/nix/store`, frozen in the
  running generation until a rebuild, so a bad commit could not brick it. The
  shared script is read from the **working tree**, so a bad commit to
  `fleet-selfpull.sh` breaks self-updating on **every box at once**. Accepted
  deliberately as the cost of running one implementation; treat that test file
  as load-bearing, not decorative.

## Hermes retired from the fleet (2026-08-01)

- **Hermes Agent was removed entirely — from provisioning and from every box —
  because it was not worth its price.** Gone from the repo: the whole `hermes/`
  tree (config, SOUL.md, 550 skill files, `bootstrap.sh`,
  `hermes-serve.service`), `tier_hermes_config`, `tier_hermes_dashboard`, the
  `hermes)` arm of `tier_agent_clis`, `just hermes-bootstrap`, and the
  workstation tier-list entries in both `linux.sh` and `macos.sh`. If you find a
  reference that survived, delete it — this is not a pause, it is a removal.
- **The weekly memory-reflection cron lost its runner and now runs on Claude
  Code.** It was deliberately on Hermes as a *cost split*: daily per-repo
  harvesting is flat-rate MAX work, rare whole-corpus reflection was worth
  paying per token for. That rationale is dead; `kb-reflection-prompt.md` and
  `kb-cron-prompt.md` were updated. Step 4 of the harvest prompt (the
  "self-learning agent with cross-session memory" branch) now matches **no**
  runner and always self-skips — kept only for a future agent that qualifies.
- **The shallow-clone skip in `tier_autofetch` / `git-autofetch` outlives
  Hermes.** `~/.hermes/hermes-agent` was only the case that *measured* it (60M
  1-commit clone → 350M after one fetch). The guard is general; do not remove it
  along with the hermes references, and do not go hunting for that directory.
- **Hermes' credentials are gone from disk but were NOT revoked at the source.**
  The removal briefly stashed them at `hermes-removed-2026-08-01/` on each box;
  those stashes were then deleted outright on 2026-08-01, so nothing is
  recoverable. What was live at the time, and therefore may still be live
  upstream with no local copy: a **Telegram bot token**
  (`TELEGRAM_BOT_TOKEN` — revoke via BotFather), the Hermes dashboard basic-auth
  password/secret, and an LLM provider `credential_pool` holding **nous** (the
  active provider) and **copilot** entries. Revoke those provider credentials
  from their own consoles if they were Hermes-only.
- **Windows Hermes was never provisioned by this repo** — `windows.ps1` has no
  hermes step. The 980M install on desktop (`%LOCALAPPDATA%\hermes`, plus a user
  PATH entry) was a manual one, removed by hand. So "wipe it from provisioning"
  and "delete it from the fleet" are genuinely two jobs here, not one.

## latitude storage layout (settled 2026-08-01)

Nothing here is derivable from the repo — latitude is Debian and its disks are
hand-mounted. **Always identify a drive by UUID or bridge serial; `/dev/sdX`
reshuffles on every boot** (five bus-powered USB drives plus a card reader race
to enumerate, and `sde`/`sdf` show as 0 B card-reader slots).

| mount | dev | UUID | fs / label | holds |
|---|---|---|---|---|
| `/mnt/immich` | nvme0n1p1 | `d0dd3972-d279-4b57-8ab4-35d17f37b955` | ext4 `immich` | `ImmichMedia` (live upload tier), `ServarrConfig`, `xs-keepers` |
| `/mnt/servarr` | sdb2 | `fd0b0662-d574-40f5-930d-de8dc0fc5082` | ext4 `servarr` | `ServarrMedia` — 526 GiB, 1843 files, 350 hardlinked |
| `/mnt/immich-2024` | sdc2 | `63c1de22-0607-40bc-aa35-168bf78927fb` | ext4 `immich-2024` | 663 G / 20456 files, immich's external library |
| `/mnt/immich-mirror` | sdd2 | `a7d7b61e-94b1-4673-af71-81152061199f` | ext4 `immich-mirror` | `mirror-refresh.sh` destination |
| `/mnt/spare320` | sdg1 | `3a78fd88-deb0-4c1a-a576-14abd0631d57` | ext4 `spare320` | music 89 G, Downloads 30 G (staging) |
| `/mnt/xs` | sda3 | `FBED-BCAA` | **exfat** `xs700` | empty scratch, 700 G |

- **Drive serials**, since letters move: sda `50026B72833E0877` (Kingston XS2000
  Ventoy stick), sdb `JD100ACC2V5ZVK`, sdc `WD-WX91E575272W`, sdd `S2U5J9ECA34541`,
  sdg `W047MMKS`, nvme0 `50026B76861AC433`.
- **sdc is device-managed SMR** (`WDC WD10SPZX-21Z10T0`) and holds the 2024
  archive *on purpose* — write-once-read-rarely is its best case. It measured
  36 MB/s on the 663 G write vs sdb's 86 MB/s. Never give it the torrent tree.
- **sdg is the most worn spindle** — 36202 power-on hours, `Command_Timeout 299`.
  Fine for a redundant copy, wrong for a sole copy.
- **`ServarrMedia`'s four dirs share inodes.** `movies/`, `tv/`, `xxx/` are
  hardlink views of `torrents/`: 526 GiB actual vs **1.03 TB apparent**
  (rsync reported `speedup 1.83`). Any move MUST be a single `rsync -aHAX`
  invocation over all four — split it or drop `-H` and it will not even fit.
- **The rename `Media` → `ServarrMedia` was invisible to every app** because
  sonarr/radarr/qbittorrent/jellyfin store *container* paths (`/data/movies`,
  `/data/torrents/sonarr`). Only `DATA_ROOT` / `CONFIG_ROOT` in
  `vps/homeserver/servarr/.env` changed. Same trick applies to any future move.
- **sda1 `Boot` (exfat, Ventoy ISOs) + sda2 `VTOYEFI` are Ventoy — never
  reformat them.** sda3 is an independently added data partition; wiping it
  leaves the stick bootable. It is exfat so all three OSes can write it (NTFS is
  read-only on macOS); the cost is no journal, so treat it as scratch only.
- **`mirror-refresh.sh` mirrors `/mnt/immich` → `/mnt/immich-mirror` only.** Its
  four `--exclude=/Media/*` lines stay correct until `/mnt/immich/Media` is
  deleted, then become dead. `ServarrMedia` is now out of scope entirely (wrong
  disk); `ServarrConfig` and `xs-keepers` are picked up automatically, which is
  what we want — *arr configs are not re-derivable.
- **`xs-keepers`** holds what was rescued off the Ventoy stick before it was
  wiped: `repos/` (all four published — `airdrome`, `nix`, `vasya`, and
  `qaz-law`, whose remote is now `metheoryt/qaz-code`), `home/` (the g513ie
  Windows profile, still un-enumerated against the dotfiles branch), plus
  `qaz-code-feature-sync-dashboard.bundle` — 236 K holding 19 commits from
  2026-05-02/03 that reached no remote. Unbundle before deleting `repos/`.
