# Project memory: machines

<!-- KB refreshed against 3816d27 on 2026-09-12 -->

Repo-local, git-tracked Claude memory. Loaded every session (merged with
global + per-host). One bullet per fact under a topical heading.

## Workflow

- **Git workflow — one framework, see `agents/docs/git-workflow.md`.** `main` is
  the fleet-sync truth. **main-checkout mode** (on `main` in `~/machines`): commit
  on `main`, push when ready; big/isolated work spawns a worktree. **worktree
  mode** (Orca worktrees): the `worktree-workflow` SessionStart hook injects the
  live rules — commit on the branch (never `main`), auto-sync `main`→branch, offer
  a fast-forward merge-back into `main` from the base checkout at checkpoints.
- **Before correcting a recorded claim, check the SIBLING repo's memory too.**
  `machines` owns the machines, `~/my/vps` owns the services, and the boundary is
  exactly where a fact gets hunted in the wrong repo. On 2026-08-01 four
  already-written answers were re-derived from scratch and two came out wrong
  first — the fourth was `vps`'s `.claude/memory/project.md` holding the nuance
  that `machines`'s roadmap had flattened, about what blocked telegrind's
  bring-up. (That specific split went away hours later when the user closed the
  rotation question; the lookup failure is the durable part, not the example.)
  See `docs/fleet-roadmap.md` P5.
- **`just test` IS the gate, and it runs the bash suite** (since 2026-08-01). It
  exits nonzero on failure. **Corrected 2026-09-10:** this bullet said the gate
  "names four directories, so the 10 suites under `agents/plugin/**/tests/` are
  run by nothing". That was fixed in `49497bd` — the private `_test-suites`
  recipe is now a recursive `find` for `*.test.sh` and is the ONE definition both
  `just test` and `justfile.test.sh` consume, so nothing is outside the gate any
  more. Ask `just _test-suites`, never a glob of your own. Don't record the suite
  count here — it moved three times on 2026-08-03 and `just test` prints the real
  one (52 on 2026-09-10, against the 54 AGENTS.md still names).
  **It is GREEN as of 2026-08-03; keep it that way.** A red suite gives no signal,
  and that is not theoretical: `provision-wsl.test.sh` sat red for weeks while
  correctly reporting a real bug in shipped code, and nobody read it because the
  failure count had become a baseline.
- **Three portability traps that made tests red on `air` but not on Linux.** All
  three cost real debugging time on 2026-08-01; expect them in any new test.
  - **Brace an expansion that abuts a multibyte character** — always
    `"${var}…"`, never `"$var…"`. **This bullet's MECHANISM was disproven
    2026-09-10:** it claimed the unbraced form is *fatal* under `set -u` in a
    UTF-8 locale, because bash would resolve a variable named `var…`. Measured on
    bash 5.3.9 / 5.2.37 / 5.2.15 under `C`, `C.utf8` and `en_US.utf8`, as
    `bash -c` and as a script file: it is not, anywhere — bash's identifier scan
    is ASCII-only in every build, so no locale could ever have made it so. The
    brace rule is kept as style plus defence-in-depth (it costs two characters
    and the original failure's real cause is still unknown), NOT as a reproduced
    bash bug. Guarded by `provision/tests/expansion-multibyte.test.sh`, whose own
    premise check reports the absence correctly. See AGENTS.md, *Tests*.
  - **BSD `wc -l` pads its count with leading spaces** (`"       1"`), so
    `[ "$(… | wc -l)" = 1 ]` fails on macOS and passes on Linux. Use `-eq`, or
    `| tr -d '[:space:]'`. **`grep -c` does NOT pad** on either platform — that
    asymmetry is why only the `wc -l` assertions broke while 15 `grep -c` count
    assertions were always fine.
  - **On macOS `/var` is a symlink to `/private/var`**, so `mktemp -d` returns
    `/var/folders/…` while anything that resolves the path reports
    `/private/var/folders/…`. When a test compares paths, match the spelling to the
    source: **resolved** for text a script emitted, **unresolved** for a symlink
    target a script stored (it keeps the spelling it was given). Getting this
    backwards reads as a logic failure — it made a working dedup look like
    "synced twice" by counting zero matches.
  - When a count assertion is repaired, **mutation-test it** (expect N+1, confirm it
    fails). A loosened assertion and a fixed one look identical in a green run.
- **THE NIX TREE IS GONE — deleted 2026-08-01 in `f3d63b2`, tag `nixos-final`.**
  `flake.nix`, `flake.lock`, 22 modules, `hosts/latitude/nixos/` and `pkgs/`:
  10.3k lines describing a machine that no longer existed. It was reviewed on the
  way out — **read `docs/2026-08-01-nixos-harvest.md` before restoring anything.**
  What that review found, which is the reusable part:
  - `modules/system/ssh-server.nix` was the only written spec for the `ssh-server`
    role (still a stub). Its firewall shape — port 22 on `tailscale0` only plus one
    explicit `192.168.8.0/24` iptables carve-out — is not guessable.
  - **Two files in that tree were live POSIX provisioning inputs, not packaging.**
    `pkgs/gortex.nix` was grepped by `tier_gortex` on every box for the version to
    install; it is now `provision/gortex.version`, and `update-gortex.sh` no longer
    needs `nix store prefetch-file` for a hash nothing verified. `fleet.json` was a
    reprovision trigger only in `touches_nix`, so it fired on one box while NixOS
    existed and on **none** afterwards — adding a fleet member never reached any
    box's `~/.ssh/config`. Now in `_touches_driver`, asserted on both tiers.
  - The Nix modules were WRONG where Debian disagreed, twice: `laptop.nix` set
    `HandleLidSwitch = "suspend"` (which on today's services host would drop immich
    and every backup timer on a lid close), and the battery module wrote
    `charge_control_end_threshold` without the Dell EC's Custom charge mode, so it
    displayed a ceiling it was not enforcing. Both are handled correctly on Debian.
  - `just quick` and `scripts/quick-check.sh` went too: it **hard-exited 1** with no
    `flake.nix`, so the documented gate did not degrade, it failed.
- **Do NOT reason about latitude as a NixOS box.** This single stale fact produced
  two confidently-wrong turns in one session, so the concrete consequences, all
  observed live:
  - `/etc/fstab` is hand-managed and edits stick (nothing regenerates it).
  - Packages come from `apt` (`sudo apt-get install -y exfatprogs`), not the flake.
  - `~/.ssh/config` is a real file that DOES carry `metheoryt.github.com` and
    `cyphy671.github.com` aliases — the opposite of what `ssh.nix` would render.
  - `sqlite3`, `lsof`, `fuser` are absent from the base install; use
    `python3 -c "import sqlite3…"` and `umount`-fails-if-busy instead.
  - **`/usr/sbin` and `/sbin` are not on the non-interactive ssh PATH.** Scripts
    run over `ssh latitude '…'` must `export PATH=/usr/sbin:/sbin:/usr/bin:/bin`
    or `mkfs.*`, `blkid`, `findmnt` and `wipefs` all come back "command not found".
- **The test suite is plain bash; `just test` runs all of it.** One file directly:
  `bash provision/tests/roles.test.sh` prints `ALL PASS` and exits nonzero on
  failure. (Until 2026-08-01 `just test` was `nixos-rebuild test` and the suite had
  no recipe at all — an easy and costly misread, now closed.)

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

- **SUPERSEDED 2026-08-27 — the box is `g15` and is back in `fleet.json`.** Read
  the bullet below as history, not as the present. The rename and re-enrollment
  are recorded under *`g15` (ex-`server`) back in the fleet* further down this
  file; `AGENTS.md` carries the current facts. Two live corrections to what
  follows: **reach it as `me@g15.gg.ez`** — `server.gg.ez` no longer resolves,
  and `methe@` was the Windows-era user (`ssh.user` defaults to `me`; `d7427db`
  regenerated the block and dropped its stale `User methe`) — and the member
  block is restored, so the bare `ssh g15` alias works from any
  box that has re-provisioned since. What the decommission *did* is not undone:
  `hosts/server/` stays deleted, Forgejo stays wiped, `C:` stays unreviewed.
- **`server` (g513ie) left `fleet.json` on 2026-08-01 — but the hardware is still
  live.** The decommission is done: manifest entry removed, `methe@server` dropped
  from `provision/fleet-authorized-keys`, `hosts/server/` deleted, and the seven
  Caddy routes repointed (roadmap P2). What to know before touching it:
  - **Forgejo was WIPED 2026-08-01, not rehomed** — the owner had never used it,
    and the volume agreed: zero repositories, a bare-install `gitea.db`, nothing
    written since the 2026-05-03 install. Container and **both** volumes removed
    (there were two: `forgejo_forgejo_data`, the one actually mounted because
    compose prefixes the project name, and an 8K `forgejo_data` stub). No old data
    exists to restore — start fresh if git hosting is ever wanted again.
  - **Its Docker state holds nothing unique — checked 2026-08-01.**
    `telegrind_pgdata` is a duplicate: the migration spec §19.3 exported it as a
    raw tar (safe because the container had `Exited (0)`, a clean shutdown, so the
    data dir is self-consistent — a stronger guarantee than a dump comparison, and
    it meant no write ever happened on g513ie), sha256-identical on three hosts,
    restored to latitude. Verified there: 987 files, `PG_VERSION` 15, `base/` +
    `pg_wal/` present. All **four** anonymous volumes (7.1G, 6.7G, 43M, 37M) are
    Python virtualenvs carrying `CACHEDIR.TAG` + `pyvenv.cfg` — self-declared
    disposable, `uv sync`-reproducible, mostly CUDA/torch wheels.
    `telegrind_pgdata`, `embedthat_redis_data` and `tugtainer_tugtainer_data` are
    all confirmed present on latitude.
  - **What gates a wipe is `C:`, not Docker.** Only `C:` is still attached — 953 GB,
    523.5 GB free, so **~430 GB used**, of which Docker is ~20 GB. The other ~410 GB
    (user profile, checkouts, downloads) is unreviewed. Every external drive already
    moved to latitude, which is why the bind-mounted arr configs are gone rather
    than pending.
  - **`CACHEDIR.TAG` is the cheap check worth remembering.** Tooling that writes it
    is telling you the directory is disposable; testing for it beat reasoning about
    contents and correctly cleared 14 GB here in one command.
  - **Reach it as `methe@server.gg.ez` — NAME THE USER.** Removing the manifest
    entry removes the `Host server server.gg.ez` block (`User methe`) from every
    generated `~/.ssh/config` at that box's next provision run, after which the
    FQDN falls through to `Host *.gg.ez`, which carries **`User me`** — and
    server's user is `methe`. Tested both ways: `methe@` → `g513ie`, `me@` →
    `Permission denied`. A bare `ssh server.gg.ez` that works today is working off
    the stale member block, not the catch-all.
  - **Both air and latitude reach it** as `methe@`, verified. An earlier note here
    claimed latitude could not reach server and blamed an unenrolled
    post-rebuild key — that was the username, not the key; latitude's
    `id_ed25519` is authorized on server. A pull-based migration from latitude
    needs no enrolment. Lesson worth keeping: a `Permission denied (publickey)`
    names the user it tried, and reading that field first would have saved the
    wrong diagnosis.
  - Removing a key line here is not an instant revocation: it lands when latitude
    and hub next provision.
  - The `server` **profile** outlives the `server` **machine** — latitude runs
    `profile: server` and `tiers.test.sh` exercises it as `plan server`. Don't
    "clean up" the profile thinking it is the retired box.
- **A manifest entry is load-bearing for more than provisioning, and two tests
  hardcoded it.** Removing a member broke `fleet-ssh-tier.test.sh` (five members
  named in a loop, `-ge 6` IdentityFile lines) and `statusboard.test.sh` (the REAL
  fleet.json fed into `sb_fleet_join` assertions) while the code under test was
  correct. Both now derive from the manifest or use a synthetic fixture. If you add
  or remove a member and the suite goes red, suspect the fixtures first.
- **`--machine <not-a-member>` used to provision nothing and exit 0.**
  `fleet_platform` returned the string `"null"`, `fleet_roles` died with a raw
  `jq: error … Cannot iterate over null` inside a process substitution so `set -e`
  never fired, no roles printed, status 0. `fleet_has_machine` now guards the front
  door: exit 2, and it lists the known members.

- Boundary: `machines` (this repo) owns the machines — Debian/Windows/macOS
  provisioning **and the restic backup profiles** (`backup/<identity>/`, moved
  here from `vps` 2026-09-01); the sibling `~/my/vps` repo owns the services
  (Immich, Navidrome, Caddy, RustDesk server, the restic REST server container,
  the VPS's AmneziaWG hub). Forgejo is not on that list — wiped 2026-08-01.
- The WSL fleet SSH key store (`ssh-wsl.sh`, `FLEET_KEY_DIR` default
  `/mnt/c/Users/<winuser>/.fleet/id_fleet`) is keyed by Windows user with no
  distro in the path, so every WSL distro on the same Windows box shares one
  key identity — the key is named after the fleet member matched via
  `fleet.json` `detect.hostname`, not the distro.
- SSH config generation is implemented twice — `ssh_wsl_render_config`
  (`provision/ssh-wsl.sh`, jq) and `Render-FleetSshConfig` (`lib/Fleet.psm1`,
  PowerShell) — so any hub/jump-host or `HostName` rule change must land in both
  or one platform drifts (see the 2026-09-08 `SKIP unreachable` section below).
  The third implementation, `modules/home/ssh.nix`, went with the Nix tree.
- Every fleet machine's OS hostname differs from its SSH alias by design
  (`latitude5520`↔`latitude`, `g614jv`↔`desktop`, `g513ie`↔`server`), so
  "is this host me?" can't be decided by comparing `hostname` to an alias
  string — use a runtime probe (`ssh $alias hostname` vs local `hostname`), as
  `memory-harvest` self-exclusion does.
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
- Firewall rules in `provision/windows.ps1` must be written to converge
  (remove-then-recreate), not create-if-absent — re-running against a host
  with a stale-scoped rule would otherwise leave the old scope in place.
- **Fleet dispatch is platform-aware, via
  `agents/plugin/skills/lib/fleet-dispatch.sh`** (`fd_probe`/`fd_run`/
  `fd_wsl_hosts`, sourced by `/ship`'s `fleet-pull.sh` and memory-harvest's
  `fleet-gather.sh`). `/ship` + memory-harvest reach every fleet host's
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
- **Orca `serve` on WSL is not how Orca runs any more (2026-07-21).** Orca runs
  on the Windows host and opens the WSL project directly; the per-distro `orca
  serve` runtime, its systemd unit and the `~/.local/bin/orca` CLI shim are gone.
  **`provision/orca-serve.sh` is NOT gone** — it still ships, and must not
  autostart where Orca runs natively (g15): a headless `serve` holds Electron's
  one-instance-per-userData lock and the desktop app cannot open at all. It gates
  on WSL since `63472aa`. `provision/tailscale-wsl.sh` (tailnet identity) +
  `ssh-wsl.sh` (fleet SSH) stay — the WSL box is still a first-class
  tailnet/SSH node.
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
  coexist on the same boxes). Fleet members per `fleet.json` (2026-09-11): hub
  `100.64.0.1`, desktop `.4`, air `.7`, latitude `.8`, g15 `.10`. Non-members
  that are still real nodes: an iPhone, desktop-wsl `.6`, and the dead
  `g15-retired` `.3` / `g15-wsl` `.9`. **Read Headscale
  (`sudo headscale nodes list`), never infer an address from `fleet.json`** —
  the list recorded here as "live 2026-08-01" (latitude `.2`, `server` `.3`) was
  wrong on every Linux member by 2026-09-11. base_domain `gg.ez` (MagicDNS;
  renamed from `fleet.mesh`).
- Probe PASSED 2026-07-13 (spec/plan/results under machines
  `docs/superpowers/`): SSH + RustDesk over the tailnet work, and DERP fallback
  through our own relay is reliable. **Its other finding — "the fleet spans two
  separate LANs; cross-LAN pairs relay via our own DERP, EXPECTED and ACCEPTED"
  — is DEAD.** It rested on latitude sitting on a hotspot behind this ISP's
  CGNAT. Measured 2026-09-07: every member except `hub` is behind the one router
  and gets direct P2P (latitude 2 ms, g15 3 ms, 99 MB/s), and that sentence is
  why a migration design wrote latitude off as a 7-hour target. "Expected and
  accepted" is how a stale measurement survives — measure a relayed pair before
  accepting it. Backlog/roadmap lives at `docs/fleet-roadmap.md`.
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
  `base`/`ssh-server` remain UNIMPLEMENTED and are named in `provision.sh`'s
  `PLANNED_ROLES`, so an undeclared role with no executor now fails `--apply`;
  `backup-client` (`.sh` + `.ps1`) and `backup-hub` got real executors
  2026-09-01.
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

### `SKIP unreachable` was a lie — the bare alias had no HostName (2026-09-08)

- `tier_fleet_ssh` emitted `HostName` only for `hub` (the one member declaring
  `ssh.host`), so every other block let the SYSTEM resolver answer the bare name.
  On g15 the router owns `.lan` and returned `latitude.lan = 192.168.8.154` — a
  stale address — so `ssh latitude` died with `No route to host` while
  `tailscale ping latitude` was direct in 3 ms and `ssh latitude.gg.ez` worked.
- `fd_probe` renders that as `SKIP unreachable`, and the run stays green. Every
  `/ship` and memory-harvest from g15 had been skipping latitude silently. **A SKIP
  row is a claim about the network; check it against `tailscale ping` before
  believing it** — same lesson as the five quiet weeks on desktop-wsl.
- Fixed in `d7427db`: both renderers (`ssh_wsl_render_config`,
  `Render-FleetSshConfig`) now emit `HostName` on every member block, defaulting
  to `<name>.gg.ez`; `ssh.host` still wins. The `Host *.gg.ez` wildcard gets
  none on purpose — `%h` there is already the FQDN the caller typed.
- Regenerating the config also cleared a second stale fact on g15: its own block
  still said `User methe` from the Windows era.


## Backups

> **The per-drive operational record of the 2026-07 storage migration — UUIDs,
> byte counts, per-copy verification, SMART hours, the `/mnt/public` →
> `/mnt/spare320` and `/mnt/immich-backup` → `/mnt/immich-mirror` reformats —
> lives in `docs/2026-07-drive-migration-log.md` (archived 2026-08-01, verbatim).
> Read it before touching any drive on latitude. What stays here is the durable
> rules that outlive the migration.**

### The backup system lives in `machines`, not `vps` (2026-09-01)

- **`machines/backup/<identity>/`** — one directory per box that backs itself up,
  keyed on **who the box is**, not on which `fleet.json` entry owns the hardware:
  a manifest machine (`latitude`) or a `fleet.local.json` nickname
  (`desktop-wsl`), one flat namespace. `vps` keeps only the REST **server**
  container. `git rm -r backup` in `vps` = `f70b9cb`.
- **The identity resolver must let the nickname win OUTRIGHT, never "prefer, else
  fall back".** Measured on desktop-wsl: `hostname` is `g614jv`, which IS
  `desktop`'s `detect.hostname`, so `fleet_detect` returns **`desktop`** — the
  distro would schedule its Windows parent's profile against its own filesystem.
  On g15-wsl the same code returns empty. Two different wrong answers from one
  fallback, which is why a malformed `fleet.local.json` is an ERROR here.
- **Each profile dir ships its own `install-tasks.sh`/`.ps1` because scope is not
  derivable by the caller.** latitude is `schedule-permission: system` and needs
  sudo; a WSL client is user-scope and must NOT be root, or its units land in the
  system manager and the timer that backs the box up is never installed.
- **`resticprofile schedule --all` ignores `-n`** and unit names come from the
  PROFILE, not the directory — one `backup/latitude/profiles.yaml` holds two
  profiles and installs four units. Two schedulers would race on the same files.
- **Reading a restic repo on latitude as `me` reports MISSING, not "unreadable".**
  The repo dirs are `drwx------ root:root`. `restic snapshots` silently skips the
  files it cannot open and prints a SHORTER list; the hub selfcheck printed 2 FAIL
  on a healthy hub for the same reason. Use `sudo`, and treat "could not check" as
  a distinct exit code from "check failed".

### A written instruction did not stop the loss it was written about (2026-09-01)

- The relocation plan said, in bold, to decide deliberately about
  `~/my/vps/backup/wsl/pass.txt` — the last copy of a secret, tracked nowhere.
  **Two days later the personal-projects move to `g15` deleted it** and nothing
  noticed: present in restic snapshot `f7f978d7` (2026-08-27 10:13), absent from
  `5f8d263c` (2026-08-29 18:38).
- **The recovery path was luck.** `.resticignore` excludes `.config/restic/` and
  not `my/`, so a secret that was deliberately kept out of the backup in one
  location was incidentally captured in another. Do not read that as coverage.
- Now escrowed at `~/.config/restic/pass-legacy-wsl-2026-04.txt` on the dotfiles
  `desktop-wsl` branch (`be81e44`), with a `README.md` in that directory naming
  which file is live and which is dead — **an unlabelled 12-byte password file is
  how it nearly went in the first place.**
- The rule this sharpens: when a plan identifies a last-copy secret, **escrow it
  in that same session**. A future-tense instruction is not a safeguard; it is a
  bet that the next person to touch the directory reads the plan first.

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
  beats restic. **That "no restic repo is planned" was true on 2026-07-31 and is
  not true now** — restic came back on 2026-08-01 and latitude runs it daily to
  `/mnt/spare320/restic/latitude` plus a REST hub for the other boxes; see *The
  backup topology, rebuilt 2026-08-01* below. What stayed dead is the pair of
  destroyed `immich-media` / `immich-postgres` repos, which are not being
  recreated. The offsite gap also stands: every copy is in one apartment, and the
  fix remains rotating one dock's drive off-site rather than cloud storage.
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
  dock B (`usb 4-2`) is the worst offender. Check with
  `sudo journalctl -k --since today | grep -aE "usb [0-9.-]+: (reset|USB disconnect)"`.
  Layout consequence: archive *primary* on dock A, *copy* on flakier dock B, and
  give any long write into dock B `--partial --append-verify` so a drop resumes.
- **Neither dock is bus-powered, and both hang off ONE root hub** (measured
  2026-09-07). Both are Ugreen **CM198** two-bay units on JMicron **JMS561U**
  bridges (`152d:1561`), each with its own 12 V brick, occupying ports 1 and 2 of
  the same xhci root hub (`usb4`, 5 Gbps). Serial ↔ port ↔ label:
  **dock A = `670200210032` = `usb 4-1`**, **dock B = `6702002103E1` = `usb 4-2`**
  — the flaky one, and the one carrying immich-2024. This bullet had A and B
  SWAPPED until 2026-09-11; the authority is the live map
  `provision/statusboard/disks.latitude5520.conf`, which the board reads and
  which is re-measured in the room. Consequence for diagnosis: two docks dropping *together* is
  explained by the shared host controller, NOT by shared bus power — a "buy a
  self-powered drive" fix does not address it, and the 2026-08-16 double drop
  stays undiagnosed. Consequence for scheduling: two long jobs on "different
  docks" still contend for one 5 Gbps uplink.
- **SMART passes through the CM198s** — `smartctl -i -d sat /dev/sdX` returns
  model, rotation rate and `SMART support is: Enabled` on all four drives. So a
  new drive can be surface-tested and SMART-audited in a dock, with no need to
  find a native SATA port (there is no free one anywhere in the fleet — every box
  is a laptop). Both docks bind `usb-storage` (BOT), not `uas`; the XS2000 on
  another bus does negotiate `uas`, so driver choice is per-bridge, not per-box.
- **Spare enclosure on hand, and it is NOT a SATA one** — a USB 3.2 Gen 2
  (10 Gbps) Type-C **M.2 NVMe** enclosure, board marked `TP TNP-9210B-V1.22`
  (Realtek RTL9210B family). Recorded so the next storage plan does not ask "do
  we have an enclosure?" and get the wrong answer: it takes **M.2 only**, so
  neither a 3.5″ drive nor a 2.5″ spinner like `spare320` fits, and any
  dual-protocol support it has would be M.2 SATA. What it is good for is speed —
  10 Gbps against the docks' shared 5 Gbps — i.e. staging or moving an NVMe, not
  a permanent member of the layout. **If it ever goes into an acceptance test,
  NVMe SMART through it is `smartctl -d sntrealtek`, not `-d sat`**; `-d sat`
  returns nothing and reads exactly like a bridge that blocks SMART. Not yet
  plugged into any fleet box, so none of this is measured — unlike the CM198
  facts above.
- **`nofail` in fstab applies at boot only.** After any dock power-cycle or bus
  drop, every affected mount needs an explicit `sudo mount <target>`.
- **Every `/dev/sdX` letter reshuffles across a reboot — treat any letter written
  down anywhere as point-in-time only.** Five external USB devices plus a card
  reader race to enumerate, and **USB port paths are not stable either**. Identify
  a drive by **UUID** (mounts), **bridge serial** in `/dev/disk/by-id/usb-*`
  (`670200210032` = dock A on 4-1, `6702002103E1` = dock B on 4-2; suffix `-0:0` is bay 1,
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

### The backup system moved from `vps` into `machines` (2026-08-29)

Tasks 1–2 of `docs/superpowers/plans/2026-08-29-backup-relocation-vps-to-machines.md`
are done: `machines/backup/` now holds the tree (`wsl` → `desktop-wsl`,
`homeserver` → `_retired-homeserver`) and **latitude runs from it** — four timers,
same names, `WorkingDirectory=/home/me/machines/backup/latitude`, snapshot
`2d7cc63e` proving it. `vps/backup/` is still present and is removed in Task 6.

- **A resticprofile systemd unit bakes `Environment="RESTIC_PASSWORD_FILE=…"` in
  at `schedule` time.** Editing `profiles.yaml` changes nothing until the schedule
  is reinstalled, and the env var is not a fallback the `password-file:` flag
  merely overrides — it is copied verbatim into `/etc/systemd/system`. That is why
  moving a password path means moving *both* keys and then re-running `schedule`.
- **Renaming a *profile* strands its timer and orphans its snapshots.** Unit
  names derive from the profile, not the directory
  (`resticprofile-backup@profile-latitude` — see the `schedule --all` bullet
  above), so relocating a config directory overwrites the same unit files rather
  than creating a second set. That is why the relocation froze every profile name
  and every repository URL.
- **latitude's password is one file reached through one symlink, deliberately.**
  The dotfiles-tracked byte-source is still
  `~/g513ie-prod-config/vps/backup/homeserver/pass.txt` — every word of which is
  now false — and `~/machines/backup/latitude/pass.txt` symlinks to it so the
  committed config names only the correct path. The symlink is gitignored and
  host-local: a rebuilt latitude must recreate it by hand.
### The REST server served 401 for two days, and `Result` said success (2026-08-29)

Found while reinstalling desktop-wsl's client (Task 3 of the relocation). The
first hand-fire returned **401 Unauthorized**; a bare `restic snapshots` with the
unchanged absolute env paths returned the same, which is what proved the config
move innocent before anything was reverted. Last good backup **2026-08-27 10:15**,
401 on 08-28 and 08-29 — **two days unbacked-up, silently.**

- **Cause: a container bound to the *underlying* directory of a mountpoint.**
  `restic-server` started 2026-08-27 13:11 while `/mnt/spare320` was unmounted, so
  `${RESTIC_DATA_PATH}:/data` resolved to the empty directory beneath the
  mountpoint; rest-server wrote a 0-byte `.htpasswd` there and kept serving it
  after the drive returned. Third appearance of this hazard on latitude — the same
  one `backup/latitude/profiles.yaml` warns about for `initialize`, and the same
  shape as the 2026-08-23 USB-drop incident. **`nofail` + a bind mount means every
  container on that drive has this failure mode.**
- **Fix: `docker compose up -d --force-recreate`, not `docker restart`** — restart
  reuses the existing container's mount configuration.
- **The discriminator is `docker exec restic-server ls -la /data`**, not a
  successful backup. Healthy shows the 68-byte `.htpasswd` and `g614jv/`; broken
  shows a 0-byte `.htpasswd` stamped with the container's own start time. Every
  host-side check passes in both states.
- **`systemctl show -p Result` is only valid within one boot.** It read `success`
  while the journal showed two consecutive failures, because the WSL distro had
  rebooted and a never-run unit in a fresh user manager defaults to `success`. On
  a WSL box — which reboots whenever Windows does — it is worthless as "did the
  last scheduled run succeed". Use the journal or the profile's own
  `schedule-log`. This narrows AGENTS.md's own recipe ("`systemctl start <unit>`
  then `systemctl show -p Result`"): still right for a run you just fired, wrong
  for a run you did not.
- **The selfcheck is now on a timer, and moved into `machines`** (2026-08-29, at
  his request). `machines/hosts/latitude/debian/restic-hub-selfcheck.sh`, deleted
  from `vps` with a pointer left in `compose.yml`; units in `systemd/` next to it,
  installed by `install-timers.sh` — `OnBootSec=15min` plus 09:00 daily. **Adding
  a pair there means editing `UNITS`, `TIMERS` and the executable pre-flight
  loop**; miss the loop and you enable a timer that fails every fire.
  **Notification is a failed systemd unit and nothing else** — `just health`
  reports it, and alerting proper stays deferred.
- **Its new check 3 is the one that discriminates.** It compares the `.htpasswd`
  **inode** the container sees against the host's — size would only say "a file of
  the same length". Old check 2 claimed to guard the empty-bind-mount case while
  reading the host path, where the mount always looks fine; that is precisely how
  eight checks stayed green for two days. Check 8 (snapshot freshness) is really a
  *client* liveness check and fires when desktop-wsl is merely asleep for a
  weekend, so it cannot be the sentinel.

- **`g614jv-maintenance` holds desktop-wsl's key, not latitude's**
  (`~/.config/restic/g614jv.pass.txt`, outside both repos). It prunes desktop-wsl's
  repo on latitude's own filesystem because the REST server runs `--append-only`,
  so no client can ever delete from it. It needed no edit in the move.
- **A stale 12-byte `pass.txt` in `vps/backup/wsl/` was the last copy of the
  pre-2026-08-01 repo's password** — never git-tracked, in no dotfiles branch,
  and different from the live 64-byte one at byte 1. Deleted on the user's explicit
  call after the drives behind that repo were confirmed reformatted. The lesson is
  the check, not the outcome: a `pass.txt` sitting next to a profile is not
  automatically the password that profile uses — desktop-wsl's reads
  `/home/me/.config/restic/pass.txt` by absolute path.

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
- **Backing up desktop's SSH private keys was `backup.ps1`'s design, and both the
  script and its rationale are gone** (deleted 2026-07-31, `1080828`). The
  rationale died first: `provision/fleet-authorized-keys` is a tracked repo file
  already carrying desktop's pubkey `fFZUwTp9…`, so a fresh install can
  `ssh-keygen`, replace that one line, push, and every fleet box picks the new
  key up through its own provisioning (`windows.ps1` writes it into
  `administrators_authorized_keys`). What a replacement script must NOT
  re-introduce: a `.ssh` copy into `secrets\`, a generic dotfile sweep that
  treats `.ssh` as just another `.*` dir, a per-distro WSL tar of
  `.ssh .gnupg .gitconfig`, `netsh wlan export profile key=clear` (cleartext
  PSKs), or advice to keep the second copy of `secrets` off-SSD **by email**.
  "GPG keys are unrecoverable" was the stated reason and did not apply — the
  captured `.gnupg` held a 32-byte empty `pubring.kbx`.
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
  A dock bridge reports only POPULATED LUNs — nothing appears at `u4-1:1` until a
  disk goes in — the opposite of a card reader, whose slots exist as 0B nodes with
  no card in them. **The live inventory (which bay holds which drive and mount)
  lives in `disks.latitude5520.conf` itself and is re-measured there; do not copy
  it back into this file.** The copy that used to sit here was the 2026-08-01
  layout and was wrong on four counts by 2026-09-10 (XS2000 gone, card reader
  gone, dockA1 populated, an ns1066 slot added).
- **An sd letter is NOT an identity — never cache anything keyed by one** (2026-08-19).
  The kernel hands out `sd?` lowest-free, so unplugging a dock frees its letters and the
  next plug gives the SAME letter to a DIFFERENT disk: on latitude `sdd` was the
  ST1000LM024 in bay `u4-2:0` at 04:34 on 2026-08-16 and the ST320LT020 in `u4-1:0` six
  hours later. The status board cached the bay label per node on the written assumption
  that a replug yields a new node, so the long-running kiosk painted `dockB0` on two rows
  at once while a fresh `--once` run was correct — which is also the diagnostic: a live
  board disagreeing with `--once` on the same box means CACHED STATE, not a map error.
  Fixed by `sb_bays_resolve` rebuilding the whole store every probe (rebuild = prune).
  latitude's docks are told apart by bridge serial in the kernel log: `670200210032` on
  port 4-1 (dockA), `6702002103E1` on 4-2 (dockB); LUN 0 is the FRONT bay, dockA is the
  one holding the 320G — confirmed in the room, and NOT derivable from sysfs.
  **The rule is not fully applied yet**: `SB_PARKS` (and, more mildly, `SB_TEMPS`)
  is still keyed by node, and cannot be fixed the same way because it caches a
  smartctl fork — `docs/fleet-roadmap.md` P6 carries it.
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
  — CPU, GPU, memory, board logic — reading ~16-19W on latitude. The USB storage
  sits outside it, so real draw is well above what the row says — and more so than
  "bus-powered" implied: the four spinners draw from the docks' own 12 V bricks,
  i.e. from the wall and not from the laptop at all. The row prints the domain name (`psys`, or `package-0` where psys is
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
- `/cyphy:memory-harvest` (`agents/plugin/skills/memory-harvest/`) mines per-machine
  Claude Code transcripts into this repo's memory tiers: `distill.py` reduces
  JSONL to `[USER]/[ASSISTANT]/[BASH]/[EDIT]` digests, a git-tracked watermark
  (line-offset + identity-hash, seeded fleet-wide) guarantees read-once, and
  `fleet-gather.sh` distills in-place on other fleet boxes and copies back
  only digests (via `cat`/`tar`, never raw transcripts).
  - Its Windows arm dispatches on `fleet.json` `platform: windows`, and
    **`desktop` is the only such member** (g15 is `debian` since 2026-09-07;
    `server` has not existed since 2026-08-27). It bash-wraps every remote command
    (Windows ssh lands in PowerShell), pushes `distill.py`, transports
    state/digests over `cat`/`tar` (no rsync), distills both the Windows-profile
    and WSL projects roots, and stamps digests with the fleet `detect.hostname`.
    Design: `docs/superpowers/specs/2026-07-19-fleet-gather-windows-design.md`.
  - Operational gotchas (invocation paths, digest pruning, self-exclusion, slug
    reuse, the Lane 1/Lane 2 write targets): *## memory-harvest / fleet-gather.sh
    gotchas* below — demoted out of `global.md` 2026-09-11, where 10.2 KB about
    one script in this repo was loading on every box.
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
- The `.nix`-era updaters are gone (`orca-bin.nix`, `scripts/update-orca.sh`,
  `scripts/update-rustdesk.sh`, `just update`/`just upgrade`) — they wrote only
  into `modules/home/*-bin.nix` and nothing else read those files.
  `scripts/update-gortex.sh` is the only survivor: it bumps
  `provision/gortex.version`, the pin `tier_gortex` installs.
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
- **`scripts/quick-check.sh` and `just quick` no longer exist** (deleted
  2026-08-01 with the flake). It hardcoded `hosts/latitude/…` and
  `.#nixosConfigurations.latitude…` as literal strings, and hard-exited 1 without a
  `flake.nix` — so the documented gate did not degrade to a skip, it failed. `just
  test` (the bash suite) is the gate now.
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
  `settings.local.json`); `GORTEX_REWIRE=1` forces it. The `[ -e /etc/NIXOS ]` skip
  is still in `bootstrap.sh` but INERT — no Nix host exists. `just gortex-setup` is
  now the REWIRE path (what you want after `just update-gortex`), not a NixOS
  escape hatch.
- **Note:** the settings-normalizer (Claude Code itself, on `/config`/model changes)
  rewrites `~/.claude/settings.json` **through the symlink** into the committed
  `agents/settings.json`, reordering keys — a recurring source of a spurious
  `M agents/settings.json`. It's cosmetic (no semantic change); not caused by gortex.
- **`just update-gortex`** (`scripts/update-gortex.sh`) bumps
  `provision/gortex.version` — a plain semver file, rehomed there 2026-08-01 from
  `pkgs/gortex.nix`. It used to need `nix store prefetch-file` for a hash, which made
  it unrunnable fleet-wide once Nix was gone while `tier_gortex` still read the pin;
  it is curl + jq only now. No hash is verified (none ever was at install time:
  `tier_gortex` untars the GitHub release over HTTPS). `just update` is gone, so this
  is a standalone bump — commit and push it and convergence carries it, because the
  pin is a reprovision trigger in `_touches_driver`.
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
- **Never bootstrap an Orca account dir as a secondary profile (2026-08-01).** Its
  POSTFIX resolves to `auth`, so the fallback deployed the tracked baseline over
  the mirror. `git-hooks/_refresh-claude-config` did exactly that after every
  pull/checkout by passing the shell's inherited `CLAUDE_CONFIG_DIR` through —
  one `git stash` round-trip re-seeded a live account's `settings.json` and moved
  the merged file to `.bootstrap-bak`. Fixed at both ends: the hook runs bootstrap
  under `env -u CLAUDE_CONFIG_DIR`, and bootstrap **REFUSES** an Orca account dir
  outright — `agents/bootstrap.sh`:152, exit 3. It used to redirect to the
  `~/.claude-profiles` mirror; the three `orca-profile-*.sh` scripts behind that
  mirror were deleted 2026-09-09 and Orca's own account switcher replaced them.
- **Codex was retired fleet-wide 2026-08-01.** `agents/codex/`, bootstrap's
  `IS_PERSONAL` Codex block, the `agent_clis codex` installer arm and
  `pkgs`-level `codex` are all gone; `~/.codex` (627MB, almost entirely vendored
  release binaries) is deleted on `desktop`. Unused in practice. The plugin's
  `hooks/hooks.json` still passes the config dir as an argument rather than
  deriving it — that is what made a second agent deployable, so keep the shape if
  another one ever arrives. Driving extra profiles through `$CLAUDE_CONFIG_DIR` is
  deprecated generally; Orca's own account dirs are the one surviving user.

## Pending follow-ups

- **`fleet-pull.sh`'s `self_alias()` is blind to self-declared WSL hosts
  (2026-08-30).** It maps this box's tailnet IP to a `fleet.json` member, and a
  WSL host is deliberately not in `fleet.json` — so on `desktop-wsl`/`g15-wsl`
  the header reads `(self: unknown)`. Harmless today only because `fd_wsl_hosts`
  still dispatches over ssh and so never enumerates the calling box: fix
  `self_alias` (read `fleet.local.json`'s nickname) BEFORE making
  `fd_wsl_hosts` interop-aware, or the box will try to pull itself. The two are
  kept decoupled on purpose — see the fleet-dispatch section of AGENTS.md.

- **Profile-aware `touches_linux` (deferred by decision 2026-07-25).** The regex is
  profile-blind, so a routine `provision/gortex.version` bump re-runs hub's whole tier list on
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

- **Pre-commit git hooks: CLOSED, cannot recur.** The `git-hooks.nix` mechanism
  (`2af7c5b`) and the whole Nix tree are gone, and the only box that ever ran
  `nix develop` was reinstalled. `just fmt` / `just check` / `just shell` no
  longer exist; shell linting is unenforced — if that ever matters, `shellcheck`
  in `just test` is the shape to add.

- **VPS base-machine reproducibility (idea, NOT started — 2026-07-11).** Bring a
  fresh cloud VM back to the VPS baseline reproducibly. Still blocked on the
  unimplemented `base` and `ssh-server` roles (roadmap P3) — `backup-client` got
  its executor 2026-09-01, and the `mesh-hub`/`mesh-member` roles this item used
  to name no longer exist. Scope when built: base machine only; services stay the
  `vps` repo's `setup-*.sh` (awg server, caddy, rustdesk), secrets/data via
  restic + (unbuilt) age/agenix. Open: Debian vs Ubuntu LTS — both apt-family, so
  `base` can be written family-generic; deferrable.

## Fleet migration 2026-07 (MacBook primary, latitude → server, retire G15)

Plan: `docs/superpowers/plans/2026-07-27-fleet-migration-mac-primary-latitude-server.md`
(the `worktree-fleet-migration-mac-primary` work branch is gone). Settled: the
Kingston NVMe went into a **Thunderbolt enclosure** — latitude has TB4
(`00:0d.0` USB controller + `00:0d.2` NHI, Tiger Lake; `bolt` enabled) and no
free M.2 2280 socket.

- **A DMI slot table omits the occupied socket, so absence proves nothing.** On
  the Latitude 5520 `dmidecode -t slot` reports three PCIe slots and the live
  KIOXIA (`00:1d.0`) is in none of them; the three are the Realtek card reader
  (`00:1c.0`, billed as x16), the Wi-Fi AX201 (`00:14.3`) and an empty **x1**
  WWAN port (`00:1c.5`). Cross-check every entry's `Bus Address` against
  `lspci -t -v`, and decide on lane width — an SSD needs its own root port, and
  an x1 one is never wired for one.
- **The live photo tier still has no off-site copy, by decision.** The 2 TB
  staging drive was deferred 2026-07-27 and never bought;
  `backup/latitude/profiles.yaml`'s header now records the standing choice — the
  libraries are protected by whole-filesystem rsync mirrors on the same box, not
  by restic.
- **Never infer a tailnet address from `fleet.json` — read Headscale.** The
  manifest holds only fleet members (today latitude `.8`, air `.7`, desktop `.4`,
  g15 `.10`, hub `.1`), while an iPhone and every self-declared WSL host are real
  nodes that never appear in it. Addresses also move with a rename: the old
  `server .3` node is `g15-retired` and g15 is `.10`. The 2026-07-27 list once
  recorded here (latitude .2, server .3) is wrong on every Linux member now.
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
- **A role with no executor is no longer safe to declare.** `provision.sh`
  carries `PLANNED_ROLES` (`base ssh-server`): a declared-planned role prints
  "no executor yet (declared)" and continues, but a role that is neither
  implemented nor listed there prints `✗ … not declared in PLANNED_ROLES` and
  makes `--apply` exit 1 (`provision.sh:103-117`; a dry run still exits 0).
  Executors today: `agents`, `dotfiles`, `repos`, `backup-client`, `backup-hub`.
- **[HISTORY — unit deleted in `9b8d63c`] A passphrase-encrypted key breaks
  every systemd-run git pull, silently.** latitude's `nix-repo-auto-pull` logged
  `Permission denied (publickey)` every 5 min and still exited 0, so it sat 100+
  commits behind with `systemctl` reporting success: a service has no ssh-agent
  and no TTY, while interactive pulls work. It could not self-heal, because
  converge is triggered by the pull. Resolved by stripping the passphrase (see
  the `id_ed25519` entry below). The lesson binds for any unattended puller.
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

## Credential decisions (do not re-raise)

- **The leaked telegrind credentials are NOT being rotated — user decision,
  2026-08-01: _"let's not rotate anything, there's no risk."_** `BOT_TOKEN`,
  `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY` and `POSTGRES_PASSWORD` reached one agent
  transcript on air via `docker inspect --format '{{.Config.Env}}'`; all four were
  measured still-live and still-matching at the time of the decision, so it is
  closed by decision rather than by action. The values stay as they are.
  Second instance of this call in the same week — see the `fFZU…` entry — and the
  shape is the same: the user is judging *reachability*, not disputing that the
  value was exposed. Full basis in `docs/fleet-roadmap.md` P6.
- **The standing rule survives the decision:** use `{{.Config.Image}}` alone, never
  `{{.Config.Env}}`, when inspecting a container. Not rotating a leaked value is a
  judgement about that value; leaking the next one is a separate mistake.
- **Nothing about a credential gates telegrind or embedthat any more.** A
  "rotate first" step was written into `docs/fleet-roadmap.md`,
  `vps/.claude/memory/project.md` and `vps/homeserver/DEPLOYING-A-REPO.md` before
  the decision, and was removed from all three rather than reordered. Do not
  reintroduce it.

## latitude storage layout (settled 2026-08-01)

Nothing here is derivable from the repo — latitude is Debian and its disks are
hand-mounted. **Always identify a drive by UUID or bridge serial; `/dev/sdX`
reshuffles on every boot** (five external USB devices plus a card reader race
to enumerate, and two letters show as 0 B card-reader slots — which letters is
itself unstable, so do not memorise `sde`/`sdf`).

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

## The pre-arr torrents: `F:\qb` is gone, `torrents/xxx` is not (2026-08-05)

Recurring question — "where are the old torrents from before the arr stack?" —
and the answer is two different answers, which is why it keeps getting re-asked.

- **`F:\qb` (60 G, 1749 files, 63900157812 B) no longer exists anywhere.** Both
  copies died within 18 hours: the original when the ST320LT020 was reformatted
  ext4 → `/mnt/spare320` (2026-07-31 18:17), and the safety copy made that
  morning (`overnight.log` 02:40 `qb TALLY OK`, re-verified 18:07 in
  `public-reformat.log`) when the HGST that held it was consumed as
  `/mnt/servarr` for the servarr migration on 2026-08-01. `archive-mirror.sh:10-12`
  records the second event. The storage baseline spec had classified `qb` "drop —
  replaceable downloads"; whether the reformat reaped it deliberately or
  overlooked it is not recoverable from the trail. **Do not go looking for it
  again** — it is not on any attached drive, and g513ie has only `C:` (no media).
- **But the old pre-arr corpus partly survived inside the arr stack.**
  `ServarrMedia/torrents/xxx` (24 G, 312 files — `realdrunkengirls.com` 18 G,
  `studentsexparties.com` 3.4 G, `RIP.avi`, `Kseniya (vkontakt)`, `Valerija`) is
  old content carried into the new stack, not new downloads. **The tell is the
  mtime: every one of the 312 reads exactly 2026-07-20**, the day the stack went
  live — a copy event resetting mtimes. Mtimes are otherwise preserved on this
  path (`music-from-g513ie` spans 2015→2026), so a single uniform stamp means
  carried-over, not downloaded.
- **A Jellyfin library holding only `*.trickplay/` dirs and zero media means the
  hardlinks were dropped, not that the media is gone.** `ServarrMedia/xxx` was
  exactly that — 337 orphan trickplay JPEGs mirroring a tree whose files all sat
  unlinked in `torrents/xxx`. Re-linking restored 299 videos. Check
  `find torrents -type f -links 1` before concluding anything is missing.

### Importing orphaned downloads — what works and what bites

Done 2026-08-05: all 465 media orphans (68 GiB) hardlinked into the libraries,
`df` grew 64 KB total. Verify a hardlink job by `df --output=used` before/after —
a copy would silently succeed, there is 246 G free.

- **`DownloadedEpisodesScan` rescans the WHOLE release folder, not just the file
  you want**, re-importing episodes already present and deleting their existing
  library file. Harmless to the media (same inode) but it **deleted 44
  `-thumb.jpg` sidecars** in the 3 seasons touched. Those are **Jellyfin's**
  artwork, not sonarr's — every sonarr metadata consumer is `enable=False`.
  Restore with `POST /Items/{id}/Refresh?imageRefreshMode=FullRefresh`, not with
  anything sonarr-side.
- **`Invalid season or episode` on import means TVDB lacks the episode, and
  `RefreshSeries` will not fix it.** Hit on Simpsons S36E19-21 / S37E16-17 and
  Solar Opposites S05E12 — releases that carry more episodes than TVDB lists.
  The only route is a direct hardlink into the season dir; Jellyfin then shows
  them by filename, with no title or artwork from the provider.
- **Hardlink rather than add-series for content sonarr does not track.** Azumanga
  Daioh (26 eps + 52 `.mka` + 52 `.ass`), Devil May Cry, Digital Circus and
  I Fought the Law went straight into `tv/<Series>/Season 01/`; Jellyfin matched
  all 46 on its own — and matched them under RUSSIAN titles (`Адзуманга Дайо`,
  `Я боролась с законом`), so **search the library by the Russian name before
  concluding a series failed to index**.
- **`/Shows/{id}/Episodes` returns 0 without a `userId`.** It is not evidence the
  import failed. Count by `Items?IncludeItemTypes=Episode&Fields=Path` instead.
- Sonarr's 44-record queue of stale entries was left alone — it is the user's
  library and their call (`progress.md:632-639`).

## A USB drop leaves latitude broken in TWO places (incident 2026-08-23)

At **Aug 23 15:58:27** both UGREEN docks (`usb 4-1` and `usb 4-2`) disconnected
within one second of each other — a mains blip on two externally-powered docks,
not a bus fault. All four spindles went with them, mid-write (`device offline
error ... op 0x1:(WRITE)` on the then-current `sdd`/`sdf`/`sdg`/`sdh`). They
re-enumerated cleanly at **16:02:03**, ~3.5 minutes later, with new letters. The
box never rebooted (uptime spanned the whole event).

**Nothing brought them back, and the damage was in two layers — fix both:**

1. **Host layer.** The fstab entries are `nofail`, so when the devices vanished
   systemd *stopped* the mount units and they sat `inactive dead` — not `failed`.
   Nothing re-pulls a plain fstab mount when its device reappears (that is what
   `x-systemd.automount` would buy), so `nofail` is exactly why this was silent:
   **`systemctl --failed` was clean the entire 20 hours.** Recover with
   `systemctl start /mnt/<name>`; journal replay takes ~15-35 s per 931 G disk.
2. **Container layer — the one that is easy to miss.** Docker resolves a bind
   mount at container *start*, so eight containers went on holding the **dead**
   device nodes inside their own mount namespaces long after the host let go:
   `immich_server` on `sdh2`, the servarr stack (`sonarr` `radarr` `bazarr`
   `whisparr` `qbittorrent` `jellyfin`) on `sdf2`, and **`restic-server` on
   `sdd1`**. They were not down — they were serving `error -5` in a loop for
   ~20 h. Remounting the host does **not** reach them; only a restart does.

Find them by device liveness, never by guessing which app uses which disk:

```sh
for c in $(docker ps -q); do pid=$(docker inspect -f '{{.State.Pid}}' $c)
  for d in $(sudo grep -oE '/dev/sd[a-z][0-9]*' /proc/$pid/mountinfo | sort -u); do
    [ -b "$d" ] || echo "$(docker inspect -f '{{.Name}}' $c) STALE $d"; done; done
```

- **`restic-server`'s repo is `/mnt/spare320/restic-rest`** — so a spare320 drop
  takes the whole fleet's backup hub down with it. That is what the two failed
  `resticprofile-*` units meant; they were the only *loud* symptom, and they
  pointed at the wrong machine.
- **`ConditionPathIsMountPoint=/mnt/immich-mirror` on `mirror-refresh.service`
  saved this run and was REMOVED anyway.** On 2026-08-23 the 03:39 run logged
  "skipped, unmet condition check" instead of rsyncing 254 G of immich into the
  root filesystem. But a skipped unit is `Result=success`, so on 2026-09-10 the
  same mechanism reported success for 90 minutes while the destination dock was
  gone and nothing was mirrored (`0d4444e`). Both mirror units are Condition-free
  now and assert their mounts by UUID inside the script — **never gate a backup
  DESTINATION on a `Condition*`.**
- **The statusboard was right and was the only thing that noticed.** "unmounted"
  was the true state, not a display bug — do not go looking for a resolver bug
  (`f759459`, `96b3bb1`) before checking `findmnt` on the box.
- Residual `EXT4-fs (sdX): I/O error while writing superblock` lines timed to the
  container restarts are the stale filesystems being *released*, not new damage.
  Expect one pair per stale device, then silence.

## `g15` (ex-`server`) back in the fleet + the WSL-host provisioning traps (2026-08-27)

**Renamed `server` -> `g15` the same day**, and its WSL host `server-wsl` ->
`g15-wsl`. Reason: `server` also names the `linux.sh` PROFILE latitude runs, so
one token meant two things in one manifest — and the role the name claimed had
moved to latitude. The tailnet nodes, the dotfiles branch and
`fleet-authorized-keys` all moved in the same change; that set is the checklist
for any future rename. Below, `server-wsl` in the trap descriptions means the box
now called `g15-wsl`.

State is in `AGENTS.md` and `docs/fleet-roadmap.md` P2; what follows is only what
the code does not say and a re-read of the diff would not tell you.

- **`tier_dotfiles` resolves the WRONG logical name on a WSL host's first run.**
  `provision-wsl.sh` runs `linux.sh` (step 3) BEFORE `fleet-local.sh` (step 4),
  so at tier time there is no `fleet.local.json` and `fleet_logical_name` falls
  through to the `fleet.json` hostname match — which on a WSL distro is the
  **Windows parent's** entry (`uname -n` = `g513ie` → `server`, `g614jv` →
  `desktop`). So a first run tries to check out the *parent's* dotfiles branch
  into the distro's `$HOME`. Every re-run is correct, because by then
  `fleet.local.json` exists. Re-adding `server` to `fleet.json` is what made this
  reachable on g513ie — before that the hostname matched nothing and the tier
  merely skipped. If you provision a new WSL host: expect the dotfiles step to be
  wrong or skipped on pass 1, and run `linux.sh` again afterwards.
- **A dotfiles clone on a box with no registered GitHub key HANGS, it does not
  fail.** `git clone --bare git@github.com:metheoryt/dotfiles.git` sat for 12
  minutes with `provision-wsl.sh` blocked behind it. Not auth — ssh was at the
  interactive **host-key** prompt with no TTY to answer it (`known_hosts` had no
  github.com entry). `ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T
  git@github.com` is the one-line probe: it returns `Permission denied
  (publickey)` in a second and seeds `known_hosts`, after which the clone fails
  fast instead of hanging. **Fixed 2026-08-27**: `role_dotfiles` (both the `.sh`
  and the `.ps1`) now sets that posture itself, `local -x` rather than `export` so
  it does not retune git for the rest of the run. Both options are load-bearing and
  pull opposite ways — `BatchMode=yes` alone REJECTS an unknown host key, which is
  the fresh-box case; `accept-new` alone still prompts for a password. A caller's
  own `GIT_SSH_COMMAND` still wins.
- **`ssh-wsl.sh` needs `jq` but runs BEFORE the `linux.sh` tier that installs
  it.** On a fresh distro it dies at step 2. `apt-get install -y jq git curl` as
  root first; do not reorder the chain.
- **`FLEET_WIN_USER=methe` was mandatory on `server`/`g15` — MOOT since
  2026-09-07**, when that box's Windows install and its `g15-wsl` distro were
  wiped. Kept because the mechanism still applies to any future WSL host with
  more than one Windows user profile, and `desktop` has only `methe`, so nothing
  in the fleet needs the override today. `ssh-wsl.sh` auto-detects
  the Windows key store by globbing `/mnt/c/Users` and requires **exactly one**
  non-system dir; g513ie has `methe` AND `WsiAccount`, so the detect yields
  empty, key persistence is skipped, and the only symptom is one warning. The
  loss shows up later as a lost `id_fleet` after a `wsl --unregister`.
- **The distro's sudo needs a password and the `workstation` profile is asserted
  never to grant NOPASSWD** (`tiers.test.sh`). To drive a provision from another
  box, `wsl -d <distro> -u root` gives unauthenticated root from Windows anyway —
  install a `/etc/sudoers.d/` NOPASSWD drop-in, run, then REMOVE it and assert
  `sudo -n true` fails. `provision-wsl.sh` `die`s on any step failure, so the
  removal must be its own invocation, not a trailing line.
- **Driving a WSL distro over ssh: the remote shell on the Windows boxes is
  PowerShell.** `&`, `|` and `$(…)` inside the ssh command line are parsed by
  PowerShell, not bash. Base64 the whole script and `echo <b64> | base64 -d |
  bash` — anything else eventually breaks on quoting.
- **The initial clone came from a `git bundle` over `scp`, not from GitHub.**
  The box had no registered key and `gh` here lacks `admin:public_key`, so the
  repo was bundled on another member, scp'd to `C:\Users\methe`, cloned from the
  bundle, and `origin` reset to the ssh URL. No token ever touched the box. Same
  trick works for any fleet box whose GitHub identity is not live yet.

## The dotfiles checkout guard was blind to dangling symlinks (fixed 2026-08-27)

- **`_dotfiles_collisions` used `[ -e ]`, which FOLLOWS symlinks.** A dangling
  symlink at a tracked path therefore tested false and was skipped, while git —
  which only `lstat`s — refused the checkout over it anyway. Net effect: the
  backup pass moved nothing, and `role_dotfiles` failed with "checkout refused —
  untracked files in $HOME already occupy tracked paths" listing paths that the
  guard had just declared absent. Fixed with `[ -e ] || [ -L ]` in both
  `_dotfiles_collisions` and the `.pre-dotfiles` name check; regression case in
  `provision/tests/dotfiles-collisions.test.sh` (6 assertions fail without it).
- **What made it reachable: `~/.claude` on g15-wsl was a graveyard of 12 links
  into `/mnt/c/Users/methe/GitHub/nix/claude/`** — a Windows checkout of the old
  `nix` repo layout, gone since the NixOS tree was deleted. Not just the four
  dotfiles-tracked paths: `hooks/global-memory-load.sh`,
  `hooks/project-memory-check.sh`, `hooks/gortex-onboard-check.sh`,
  `agents/quick-tasks.md`, `skills/{update-balance,gortex-align}` and
  `host-memory.md` were dead too, i.e. the memory-loading hooks on that box had
  been inert for weeks.
- **Why bootstrap never cleared them — and it is NOT `link()`.** Checked on
  2026-08-27: `link()` handles a dangling link correctly (`-L` true, readlink
  mismatch, `rm -f`, relink). The gap is `retire_link`, whose ownership test is
  PATH-based — it drops a link only if it points into `$SRC_DIR`, so links from an
  era when the checkout lived somewhere else (here `/mnt/c/.../GitHub/nix/claude/`)
  read as *someone else's link* and live forever. It cannot recognise its own past.
  And `~/.claude/hooks/*` is owned by nothing at all since hooks moved into
  `plugin/` — no code path even looks at it. A clean `linked=0 skipped=4 failed=0`
  summary is therefore not evidence of a healthy profile: run
  `find ~/.claude -xtype l` before trusting one.
- Removing them is safe: a broken symlink holds no data, and the target root
  (`/mnt/c/Users/methe/GitHub`) does not exist at all on that box. Verified before
  deleting, not assumed.
- **The clone hang is fixed too (same day).** `role_dotfiles` sets
  `GIT_SSH_COMMAND` + `GIT_TERMINAL_PROMPT=0` before the clone — and before the
  `fetch` and the new-branch `push`, which reach the remote the same way and would
  hang the same way; `|| true` on the fetch prevents a failure, not a hang.
  Pinned behaviourally in `dotfiles-collisions.test.sh` by a PATH-shimmed `git`
  that records the environment it was handed (7 assertions fail without the fix).
  The test `env -u`s `GIT_TERMINAL_PROMPT` first: a dev shell can already export
  `0`, which made that one assertion pass vacuously until it was cleared.

## Moving personal projects onto g15 — the WSL traps that cost the most (2026-08-28)

Context: qaz-code (and its 186 GB pgvector DB) migrated from desktop-wsl to
g15-wsl. The move itself was routine; four things about WSL as a fleet host
were not, and all four will recur for the next project moved there.

- **A WSL distro lives only while a `wsl.exe` client from Windows is attached to
  it.** There is no config switch for "stay running" — `vmIdleTimeout` governs
  the utility VM, not the distro. g15-wsl therefore self-terminated about a
  minute after every command returned and kept dropping off the tailnet, which
  reads as a flaky host. desktop-wsl looks immune only because Docker Desktop's
  `docker-desktop-user-distro proxy --distro-name desktop-wsl` runs inside it and
  is exactly such an attached client. **Consequence for the "drop Docker Desktop,
  install native docker" plan: removing DD removes the thing holding desktop-wsl
  up.** Fix on g15 is a Windows scheduled task `wsl-keepalive` (ONLOGON,
  `/RL HIGHEST`) running `wsl -d Ubuntu-26.04 -u root -- /bin/sleep infinity`.
  `provision-wsl` installs nothing of the sort — a real gap for a `dispatch:direct`
  host that is supposed to be reachable.
- **Docker Desktop leaves a dpkg diversion behind.** On a distro that ever had DD
  integration, `/usr/bin/docker` is diverted to `/usr/bin/docker.native`, so
  installing `docker.io` yields a working daemon and no CLI at all —
  `docker: command not found` with `dockerd` active. Undo with
  `dpkg-divert --rename --remove /usr/bin/docker`. Re-enabling DD integration
  will re-divert it.
- **Windows cannot open TCP to its own WSL distro's NAT address on g15**
  (172.26.x:22): ICMP passes, TCP does not, and it stays broken with an explicit
  Hyper-V firewall allow rule for 22 *and* `DefaultInboundAction Allow` on the WSL
  VM. So `netsh portproxy` into the distro does not work there. What does work is
  jumping through Windows: `ProxyCommand ssh methe@<g15> "wsl -d <distro> -- nc
  127.0.0.1 22"` gives a real ssh connection (rsync runs over it normally). Note
  desktop-wsl does not have this problem because it runs `networkingMode=mirrored`.
- **Piping binary through Windows OpenSSH → PowerShell → `wsl.exe` does NOT
  corrupt the stream.** Verified by sha256 over 100 MB and then 186 GB at
  117 MB/s. PowerShell passes the stdin handle to the child rather than reading
  it. This is the simplest fast path into a distro and needs no port plumbing.

Transport, for the next time something big has to move. The g15-wsl route table
here is dead (that distro was destroyed 2026-09-07) and the live fleet numbers
are in AGENTS.md's *One LAN, not two*. Two rules survive it:

- **A relayed pair cannot be fixed with a faster radio; only by leaving the
  relay.** Two NATed WSL distros had no direct path and sat at 3.3 MB/s through
  hub's DERP in Kazakhstan — unchanged after both laptops moved to a 1201 Mbps
  WiFi 6 rate. NAT blocks reaching *in*, not going out, so the winning route was
  always the distro **pushing outbound** to a LAN address (78 MB/s), or the LAN
  route through the Windows host's sshd into `wsl.exe` (44 MB/s, 13x the relay,
  same radio). A direct Ethernet cable on APIPA (169.254.x, no DHCP) gave
  117 MB/s and turned 8 hours into 40 minutes.
- **Two traps that produced three false zero-byte "measurements":** `ssh` to a
  **bare IP** does not pick up the fleet identity (the generated config keys on
  `Host *.gg.ez`) — pass `-i ~/.ssh/id_fleet -o IdentitiesOnly=yes`, or it fails
  in 0.2 s having transferred nothing, which looks exactly like no bandwidth. And
  **only port 22 is open inbound** on a Windows box, so `nc` to any port you pick
  is refused and the transfer must ride ssh.

### qaz-code PGDATA landed on g15 (2026-08-29, verified)

- 185.2 GB physical copy of `qaz-law_db_data` -> `g15-wsl:/data/qaz-law/pgdata`,
  bind-mounted by a git-excluded `compose.override.yml` that also pins the image
  by digest. Postgres starts clean there (no recovery), HNSW index present at
  13 GB and `indisvalid`, and the plan uses it.
- **Both sides agree**: 184 GB `pg_database_size`, 25 468 309 chunks /
  5 545 473 with embeddings, `data_checksums on`.
- The copy is a **chunked** tar-over-ssh (`scratchpad/xfer2.sh`): 18 batches of
  10 GB, a marker per batch, so an interruption costs one batch and the script
  resumes. 28 minutes at ~114 MB/s over the direct Ethernet cable.
- **Verify a physical copy by manifest, never by `du`** — path+size for every
  file, sorted `LC_ALL=C` on both sides. `du` totals match even when one file is
  truncated, which is exactly the failure a killed tar produces.
- Remote commands to a Windows fleet host go through PowerShell, which eats
  quotes: `wsl -d <distro> -- find ... -printf "%s\t%P\n"` silently returns one
  line. **Feed the script on stdin instead** — `printf '%s\n' ... | ssh host
  "wsl -d <distro> -u root -- bash -s"`. Same trick as the tar pipe.
- Nothing is deleted from the desktop yet; that stays a separate, confirmed step.

### The other ten personal projects landed on g15 (2026-08-29, verified)

All of `~/my/` is now on `g15-wsl` alongside qaz-code. Nothing was deleted from
the desktop — that stays a separate, explicitly confirmed step.

**Two repos have no remote at all: `DeMarket` (1 commit) and `housing` (20).**
They are the only irreplaceable things in this migration and also the two
smallest, which is exactly how they get skipped. They were `rsync -aH`'d
wholesale *including `.git`*, not cloned. Verified by sha256 over every file:
identical except `.git/index` on both — that file stores stat data (inode,
ctime) and **differs across a correct copy**. An index-only diff is a pass, not
a failure. No GitHub repos were created for them; that is an outward-facing
action and was not asked for.

The other eight (`airdrome`, `arbuz-concierge`, `buton`, `embedthat`, `skep`,
`telegrind`, `vasya`, `vps`) were cloned from `git@github.com:metheoryt/…` on
g15 — it already authenticates as `metheoryt` — then HEAD compared against the
desktop, all eight identical.

**The real payload of a repo move is what git ignores.** `git status
--porcelain` reported every repo clean while ~50 MB of unrecoverable content sat
on disk: `.env` × 4, `buton/google-account.json`, `buton/harvester.db` + 2 dated
backups + `harvester.ledger.db`, `telegrind/local/telegrind-*.json` (a Google
service-account key), `vps/backup/wsl/pass.txt` (a 12-byte restic password),
`skep/.superpowers/sdd/` (62 files of plans and review diffs),
`skep/SKEP_SUMMARY.md` (untracked), and `.claude/settings.local.json` × 5.
Enumerate it with `git status --porcelain --ignored=matching` **plus** the
untracked lines — neither alone is complete. Copied by explicit file list and
verified by sha256: 79 files, byte-identical. Venvs (`buton` 183 MB,
`embedthat` 725 MB) deliberately skipped — `uv sync` rebuilds them.

**No named docker volumes for any of the ten.** The desktop's ~70 hex-named
volumes are anonymous; with no containers left for those stacks they are already
orphaned and unreachable by compose, so restarting a stack on g15 creates fresh
ones either way. Only `qaz-law_db_data` (moved) and the `backend-api*` work
volumes are named.

**g15's WSL firewall is back to `DefaultInboundAction: Block`**, and the
never-working `0.0.0.0:2222 → 172.26.251.77:22` portproxy plus its `wsl-ssh-2222`
rule are gone. Tailnet SSH to `g15-wsl.gg.ez` is unaffected — tailscaled runs
*inside* the distro, so the Hyper-V VM firewall never sat in that path. There was
no `wsl-ssh-in` Hyper-V rule to remove.

**Desktop copies deleted 2026-08-29 — except `vps`.** `~/my/` on `desktop-wsl`
went 1.3 GB → 4.9 MB. **`~/my/vps` stays and must not be deleted:** it is the
`WorkingDirectory` of the enabled user timer
`resticprofile-backup@profile-wsl.service`, which backs up this WSL box daily at
06:00 from `vps/backup/wsl/profiles.yaml`. It is live infrastructure that happens
to live in a project checkout, not a copy. Before deleting any project directory,
`grep -rl '/home/me/my/' ~/.config/systemd/user/ /etc/systemd/system/` — that one
grep is the whole gate.

Two things the pre-delete sweep caught that the first pass had missed, both
because `git status --porcelain --ignored=matching` **does not recurse into an
ignored directory** and my listing was additionally `head`-truncated:
`buton/.superpowers/` (harmless, one empty `.gitignore`) and the fact that
**`--ignored` without a mode is the listing you actually want**. Also compare
*refs*, not just HEAD, before deleting a source: `git rev-list --branches --not
--remotes` plus `git stash list` per repo. All eleven came back zero, and
`skep`, `telegrind`, `qaz-code` and `DeMarket` each carry a second branch that
HEAD comparison alone would never have shown.

g15's `qaz-code` sits on `metheoryt/kazhackstan-2026` (0/0 against its own origin
ref), while the desktop was on `main` — the HEADs differing was the branch, not a
divergence. `id_cyphy671{,.pub}` removed from g15; the now-stale
`Host cyphy671.github.com` stanza in its `~/.ssh/config` was left alone
(dotfiles-tracked, harmless unused). g15 still authenticates to GitHub as
`metheoryt`.

**The pre-delete gate was missing `git worktree list` (2026-08-29).** Refs,
stashes and HEAD all came back clean, and deleting `~/my/` still orphaned three
Orca worktrees under `~/orca/workspaces/<repo>/<branch>` — their `.git` files
point at `<repo>/.git/worktrees/<name>`, which went with the parent. **A
worktree's uncommitted state is invisible from the main repo's `git status`, and
its existence is invisible from `for-each-ref`.** One command would have caught
all three. Add it to the gate:

    git -C <repo> worktree list      # alongside rev-list --branches --not --remotes + stash list

Recovery, if it happens again: the worktree's *files* survive the parent's
deletion. Re-create the parent, `git worktree add <path> <branch>` (a clean
checkout at the tip), then rsync the orphaned directory over it excluding `.git` —
whatever `git status` then reports IS the uncommitted work, and an empty status
proves nothing was lost. To check an orphan *without* a repo at all, compute git
blob hashes by hand — `{ printf 'blob %d\0' $(stat -c%s "$f"); cat "$f"; } |
sha1sum` — and diff against `git ls-tree -r --format='%(objectname) %(path)'` on
the branch. That is how `telegrind/telegrind-spendings-analytics` was cleared: 36
files, every blob identical to `origin/main`, so the branch had been merged and
only its name was lost (it is not on GitHub either).

**`rsync --exclude '.git'` silently strips nested repositories (2026-08-29).**
The qaz-code Orca worktree carries `laws/` — 108 448 untracked files, 5.8 GB —
and inside it four nested git repos (`codes`, `government`, `ministerial`,
`local`, 139 653 commits and 1.8 GB of history between them, none with a remote).
Excluding `.git` when copying a worktree is right — the worktree's own `.git` is
a pointer file that must not travel — but it takes nested repositories with it,
and the copy still reports `rc=0`.

**`laws/` is regenerable from qaz-code's own database** (confirmed by Maxim
2026-08-29), so nothing there was at risk and it need not be copied at all next
time. What survives as the lesson is the mechanism: the omission was caught by a
plain file-count diff after the transfer (108 336 vs 108 448), not by the exit
status. **Count files across the boundary; an rsync that succeeded is not an
rsync that copied what you meant.** Before excluding `.git` anywhere, run
`find <tree> -name .git -maxdepth 4` and decide about each hit by name.

**Desktop cleanup finished 2026-08-29.** `~/my/` holds only `vps` (live backup
timer); `~/orca/workspaces/` holds only the work repos plus `vps` — 14 GB → 737 MB,
gated on a path+size manifest of 108 610 files matching g15 exactly. The
`qaz-law_db_data` volume and its container are gone: Docker's `Local Volumes` line
went 200.9 GB → 2.047 GB, and the g15 copy was re-confirmed live first (184 GB,
25 468 309 chunks, 5 545 473 embeddings, `hnsw_valid=true`).

**Deleting the volume did not return one byte to Windows.** `docker_data.vhdx` is
still 1007 GB — a dynamically-expanding VHD never shrinks on its own. Reclaiming
it needs Docker Desktop stopped and an elevated `diskpart` (`select vdisk file=…`
→ `attach vdisk readonly` → `compact vdisk` → `detach vdisk`), or `Optimize-VHD
-Mode Full` where the Hyper-V module is present. Worth knowing before promising
anyone that a volume delete freed disk space.

## Orca headless serve: what survives from g15-wsl (2026-08-29)

The host is gone (g15 was wiped to native Ubuntu 2026-09-07), so the paired
`ws://100.64.0.9:6768` environment and its three worktrees are history. The
reason serve exists is not: **`orca serve` + `environment add --pairing-code` is
the only way one box can drive another's Orca** — there is no ssh-remote mode,
and Windows Orca reaches only its own host's distro. The 2026-07-21 removal
("Orca runs on Windows now") was host-local, and the abandoned 2026-08-01 spec
abandoned *two distros per host*, not the serve model; don't re-read either as
"serve was tried and rejected". Four findings that still hold:

- **Serve needs an X display and under WSLg cannot make its own.** Orca starts an
  Xvfb on `:99` when `DISPLAY` is unset; WSLg mounts `/tmp/.X11-unix`
  **read-only**, so Xvfb never binds and Electron dies with `Missing X server or
  $DISPLAY` — a crash loop (72 restarts before it was caught), not the "browser
  panes may be unavailable" the warning suggests. WSLg already serves `:0` on
  that tmpfs; hand serve that.
- **Electron flushes a non-tty stdout only at exit**, so under systemd the
  journal shows nothing until the process dies and the documented "read the
  pairing URL from `journalctl`" never works. `script -qefc … /dev/null` gives it
  a pty; `-e` preserves the exit status for `Restart=on-failure`.
- **Judge a serve run by whether the unit stays active, never by shutdown
  lines.** Piping serve into `grep | head`, or capping it with `timeout`, makes
  Chromium tear down noisily ("Network service crashed", "GPU process isn't
  usable. Goodbye.", `SIGTRAP`). Two fixes were spent on that phantom (SUID
  `chrome-sandbox`, `ELECTRON_DISABLE_SANDBOX`); both were reverted, neither was
  needed.
- **Backticks inside an UNQUOTED heredoc run as a command substitution.** A
  comment reading `` `script -e` `` executed `script`, spawned an interactive
  bash and hung the provisioner. And a `timeout` that kills the local ssh client
  does NOT kill the remote script — `pkill -f "bash /tmp/orca-serve[.]sh"`, where
  the bracket keeps the pattern from matching your own command line.
- A pairing code is **not single-use**: the runtime's identity is stable across
  restarts, so the same code paired two clients.

## Servarr: a yearless release name stalls Radarr import forever (2026-09-03)

- **Symptom:** Jellyseerr shows 100% and never advances; the movie never reaches
  Jellyfin. Radarr's queue says `trackedDownloadState: importPending`,
  statusMessage **"Unable to parse file"**; `GET /api/v3/manualimport` on the
  folder rejects with **"Unknown Movie"**. qBittorrent is fine — `stalledUP`,
  `progress: 1`, file complete in `/data/torrents/radarr/<release>/`.
- **Cause:** RuTracker (via Prowlarr) hands over release names with **no year**,
  and Radarr's parser returns *nothing at all* for those — not a wrong match, a
  null parse. Proven with `GET /api/v3/parse`: adding `.2026.` to the same name
  parses and resolves; without it `movieTitle` is `null`. The
  `_New-Team_il68k` group suffix is NOT the problem —
  `Backrooms.2026.720p...New-Team_il68k` imported fine.
- **The grab history does not rescue it.** Radarr knows the movieId in the queue
  record and still won't import, so this needs a human every time. Three items
  had been sitting like this since 2026-08-05.
- **Fix (per item), all API, no UI:**
  `POST /api/v3/command` with `{"name":"ManualImport","importMode":"auto",
  "files":[{path, movieId, quality, languages, downloadId}]}`. Take `quality` and
  `languages` **verbatim** from the `manualimport` GET response; take `movieId`
  and **`downloadId` from the queue record**. Omitting `downloadId` imports the
  file but leaves the queue item in place — Jellyseerr keeps showing it in flight,
  i.e. fixes Jellyfin and leaves Seer wrong.
- `importMode: auto` hardlinks (link count 2, no extra space) because
  `/data/torrents` and `/data/movies` are the same mount; the torrent keeps seeding.
- **Radarr has zero notification connections** (`GET /api/v3/notification` → 0),
  so nothing tells Jellyfin about an import. It still works: Jellyfin's
  `LibraryMonitor` watches `/data/movies` in real time and picked the folder up
  ~60s after the import, trickplay included. Don't "fix" this by adding a
  Jellyfin connection unless real-time monitoring gets turned off.
- Radarr API key: `sudo grep -oP '(?<=<ApiKey>)[^<]+' /mnt/immich/ServarrConfig/radarr/config.xml`.
  qBittorrent's WebUI **rejects `localhost`** (`Forbidden`) — `AuthSubnetWhitelist`
  is `100.64.0.0/24`, so curl it as `--interface 100.64.0.8 http://100.64.0.8:8084`.
- Ignore `DownloadedMovieImportService: path does not exist or is not accessible`
  bursts right after a container restart — they stopped 23 min in on 2026-09-03
  and were not the blocker.

## "Environmental failure" was never a category — both reds were bugs (2026-09-02)

The finding and both post-mortems now live in `AGENTS.md` (*Tests*: "Known
environmental failure" is not a category, plus the measured retraction of the
multibyte brace mechanism). Kept here is the one detail that is not there:

- **On WSL, put `pwsh.exe` FIRST in any shell-out candidate list.** `for c in
  pwsh powershell powershell.exe` always lands on Windows PowerShell **5.1**,
  because only the `.exe` spellings are on PATH there; the Windows members run
  PS 7. `pwsh.exe` under `WindowsApps` is a real binary (7.6.5), not a Store stub.

## PowerShell provisioning traps (2026-09-02, closing roadmap P3)

`Write-Error` cannot implement a guard, `$env:X = ''` REMOVES the variable (hence
`-PlannedRoles` as a parameter, not an env var), and `foreach` over `$null`
iterates zero times — all three are written up in `AGENTS.md`'s Windows
front-door paragraphs. Three traps that are only here:

- **Do not port the padded-substring match.** posix needs `case " $PLANNED " in
  *" $role "*)` so `ssh` cannot match `ssh-server`. PowerShell's `-contains` is a
  whole-element match on the array; the hazard does not arise and the padding
  would be cargo.
- **Defining a function in a `.psm1` and exporting it are separate acts.**
  `Export-ModuleMember`'s backtick-continued list is easy to miss, and an
  unexported guard simply never runs. The suite asserts the name reaches that line.
- **`provision.ps1` runs end to end from WSL** via `pwsh.exe` against the real
  Windows side, which makes the exit-code assertions real coverage rather than a
  source grep. ~8s for a full dry run, ~1s for the unknown-machine arm.

## Servarr: удаление в *arr не освобождает место — держит qBittorrent (2026-09-07)

- **Импорт делает хардлинк** (`copyUsingHardlinks: true`, `/data/torrents` и
  `/data/movies|tv` — один mount `/mnt/servarr`). Значит у файла ДВА линка:
  библиотека и торрент. Удаление сериала/сезона/фильма в Sonarr/Radarr снимает
  только библиотечный — **на диске не освобождается ничего**, и qBittorrent
  продолжает раздавать «удалённое».
- **`Remove Completed Downloads: True` этого не спасает.** Он работает по
  очереди *arr, а *arr забывает торрент после импорта: замерено 2026-09-06 —
  очередь Radarr 3 записи, Sonarr 0, при 46 живых торрентах.
  **Ограничителем был не ratio, а `max_ratio_act = Pause`** — правило срабатывало
  и ничего не удаляло. Опровергнуто на следующий день (см. ниже, 2026-09-07):
  с `max_ratio_act = 3` (Remove torrent AND files) qBittorrent снял 25 **уже
  скачанных** торрентов вместе с файлами. То есть ratio действует и на старые
  закачки; «влияет только на новые» было неверно.

- **Порядок:** удалить в Sonarr/Radarr (галка *Delete Series Folder* /
  *Delete Files*), потом снять торрент в qBittorrent с *Delete files*.
  `recycleBin` пуст в обоих — отката нет.
- **Как найти, что реально освободится** — по link count, не по `du`:
  файл с `n=1` под `torrents/` ничей → освободится; `n>1` → второй линк в
  библиотеке, удаление даст 0 байт. Для незавершённых торрентов считать
  `st_blocks*512`, а не `st_size`: qBittorrent преаллоцирует, и apparent size
  врёт (38 GB «свободных» у скачанного на 1 GB The Dark Knight).
- **Обход по списку qBittorrent НЕ находит всё.** Так пропустилась пачка
  `torrents/sonarr/Devil May Cry (Season 1)` — 12.6 GB без торрента вообще.
  Правильный обход: пройти дерево `torrents/`, собрать иноды живых торрентов и
  вычесть. Сделано 2026-09-07; после этого в дереве осталось ~35 MB мусора.
- **Не всякая папка без торрента — мусор.** `Azumanga Daioh` (20.9 GB),
  `The Amazing Digital Circus`, `I Fought the Law` лежат под `torrents/` без
  торрента, но с `n>1` — те же иноды, что в библиотеке. Удаление освободит ноль.
- Результат прохода: 15 GB свободных → **259 GB** (99% → 72%), 217 GB за два
  шага. `Everybody Hates Chris` один занимал 106 GB в торрентах.
- **Jellyseerr показывает русские названия** (`user_settings.locale = ru` у
  единственного юзера, глобальный `main.locale = en` проигрывает ему): Silo =
  «Укрытие», Family Guy = «Гриффины» — расходятся все 16 сериалов с tmdbId.
  Искать по названию из Sonarr бесполезно.
- Кнопка удаления в Jellyseerr/SeerTV = `DELETE /api/v1/media/:id/file` →
  `removeMovie`/`removeSeries` с **`deleteFiles: true`**, `addImportExclusion:
  false`. Сносит фильм/сериал ЦЕЛИКОМ, посезонно не умеет; сезон — только Sonarr
  (*Delete Selected Episode Files*). Соседний `DELETE /media/:id` чистит лишь
  базу Jellyseerr и файлов не трогает.

## Orca IDE on g15-wsl never upgraded — the cache key was the word "latest" (2026-09-07)

Both bugs are fixed and each fix ships with its reasoning in the code —
`provision/orca-serve.sh:124-137` for the upgrader, `justfile:79-82` for the
gate's `< /dev/null`. What generalises past that one dead distro:

- **`apt`'s `orca` package is the GNOME screen reader**, not Orca IDE, and
  `which orca` under non-interactive ssh finds `/usr/bin/orca` FIRST because
  `~/.local/bin` is not on that PATH. Orca IDE on Linux is only ever the AppImage
  under `~/.local/opt/orca`. `orca --version` does not exist on this build — it
  prints help — so the one truthful record of what is EXTRACTED is
  `squashfs-root/orca-ide.desktop`'s `X-AppImage-Version`, compared with the
  leading `v` stripped from BOTH sides.
- **A cache key that never varies is a cache that never misses.** Naming the
  download `…-${VER:-latest}` and gating on "the file exists" made the upgrader
  run green while doing nothing, for nine days. Resolve the tag up front, name
  the cache file by the resolved tag, download to `.part` (a truncated file at
  the final name is a permanent cache hit — the same bug again), and gate the
  extract on the extracted version, never on the directory existing.
- **A test runner that hands each suite the loop's own stdin truncates itself.**
  A suite that execs PowerShell reads that fd to EOF; the gate then printed
  "all 32 suites passed" while skipping 17, and only on boxes where PowerShell is
  on PATH. `just test`'s printed total is a floor, not the repo.

### qBittorrent: автоудаление включено 2026-09-07 — и у застрявшего импорта теперь таймер

- Настройки (проверены через `/api/v2/app/preferences`): `max_ratio = 7`
  (ставился 3, поднят до 7 в тот же день),
  `max_seeding_time = 44640` мин (31 день), **`max_ratio_act = 3` = Remove
  torrent AND files**. Было `max_ratio = 10` / act `Pause`, то есть де-факто
  вечное сидирование и ноль автоочистки.
- **Библиотеке это не угрожает, замерено:** после автоснятия 25 торрентов вместе
  с файлами `df` не изменился (662 GB занято / 259 свободно до и после), Radarr
  21/21 файлов на диске, Sonarr 143/143, пропавших 0. Хардлинк: удаление снимает
  ИМЯ, данные уходят с последним именем, у библиотеки имя своё.
- **Что стало опаснее — зазор «докачано, но не импортировано».** Раньше
  застрявший `importPending` (имена без года, см. выше) сидел безопасно месяцами,
  потому что торрент жил вечно. Теперь его снесёт ratio 3 или 31 день, после чего
  *arr увидит «path does not exist», пометит failed и **пойдёт качать заново**.
  Вывод: застрявшую очередь надо разбирать за дни, а не «когда-нибудь»;
  `queue?includeUnknownMovieItems=true` — единственный способ её увидеть целиком.
- `Remove Completed Downloads: True` в обоих *arr включено, но практически не
  срабатывает (они не отслеживают почти ни один торрент). Реально удаляет только
  правило qBittorrent — на него и рассчитывать.
- `torrents/sources` — это **export dir** qBittorrent (`export_dir =
  /data/torrents/sources`), куда он кладёт копию каждого добавленного `.torrent`.
  Не watch dir (`scan_dirs = {}`), так что удаление старых копий ничего не
  переподхватит. Свои копии qBittorrent держит в `/config/qBittorrent/BT_backup`.
- **С 2026-09-07 правило ровное: удалять в Sonarr/Radarr, и только для живого
  торрента ещё в qBittorrent.** Три папки со «вторым линком без торрента»
  (`Azumanga Daioh` 20.9 GB, `The Amazing Digital Circus` 2.8 GB,
  `I.Fought.The.Law.2025` 2.1 GB) удалены — они освобождали 0 байт, но ломали
  правило: qBittorrent про них не знал, значит его автоудаление их не тронуло бы
  никогда. После удаления библиотека цела (38 крупных файлов — те же иноды,
  `nlink` 2→1), Sonarr 143/143, `df` не изменился, как и ожидалось.
  Под `torrents/` осталось ровно содержимое живых торрентов.
- **Проверка перед удалением, если торрента нет:** глянуть, нет ли одноимённой
  папки в `torrents/radarr` / `torrents/sonarr`. Если появилась — это снова тот
  же класс, и её надо снести руками; иначе она останется навсегда.

## g15 phase 1 done — where the only copies live (2026-09-07)

**Closed. The wipe happened 2026-09-07 and the staging is fully unwound
(2026-09-10):** `pgdata` deleted from the mirror by the owner's decision — the
live `qaz-law-db-1` runs on g15 at `/data/qaz-code/pgdata` (126 G) and is
rebuildable; `home-me` is back on g15 and off staging; `Music` (152 G) is on g15
inside the restic profile `g513ie-maintenance`. The one-copy question was decided,
not deferred — do not re-raise it. `tier_docker` is no longer "undecided": it
exists (`provision/lib/tiers.sh`) and AGENTS.md documents it.

Two things outlive the phase:

- **The Ventoy drive is shared with latitude.** The same physical drive that
  carried `ubuntu-26.04.1-desktop-amd64.iso` also holds latitude's `xs700`
  archive-mirror partition, and `archive-mirror.timer` next fires
  **2026-10-01 05:01** — return the drive before then. Secure Boot on g15 is
  OFF, so Ventoy needs no MokManager enrolment.
- **Why Ubuntu and not Debian:** asus-linux names a **6.19+ kernel floor**;
  trixie ships 6.12, Ubuntu 26.04 ships 7.0 out of the box. Spec:
  `docs/superpowers/specs/2026-09-07-g15-linux-migration-design.md`.

## g15 phase 4 — what the Ubuntu box actually cost us (2026-09-07)

The migration itself went as designed. Everything below is a thing that was NOT
in the spec and that a future session would otherwise rediscover.

**An AppImage does not "install" on Ubuntu 26.04.** There is no `libfuse2` in the
release, only fuse3, and AppImageKit type-2 needs the second — so `chmod +x` and
run dies on `libfuse.so.2`. `--appimage-extract` is the install, and it needs no
FUSE and no root. `provision/orca-serve.sh` has always done it that way; the trap
is only for a hand-downloaded AppImage.

**Setting setuid on `chrome-sandbox` does nothing for Orca, and leaves a
setuid-root binary in `$HOME`.** `AppRun` decides the sandbox by probing
`unshare -Ur true`; Ubuntu ships
`kernel.apparmor_restrict_unprivileged_userns = 1`, so that probe fails and
AppRun appends `--no-sandbox` unconditionally. It never looks at `chrome-sandbox`
at all. Two sudo commands were spent on this before reading `AppRun`. The real
route to a sandbox here is an AppArmor profile granting userns to the launcher
path — not setuid, and not `--no-sandbox` for a tool that runs agent code.

**`cat > path` follows a symlink and truncates its TARGET.** That is how
`~/.local/opt/orca/squashfs-root/resources/bin/orca-ide` — Orca's own 1592-byte
CLI shim — got replaced by a four-line wrapper: `~/.local/bin/orca-ide` is a
symlink into the install, and writing "to the symlink" wrote through it.
Restored byte-for-byte from a second extraction of the same AppImage. Worth
knowing that `orca-serve.sh` line 170 already carried `rm -f` before its `>`
with a comment saying exactly this; the lesson was in the repo and not applied.

**uid 999 is `dnsmasq` on Ubuntu and `postgres` in the container.** A restored
PGDATA at `999:0` mode 700 looks alarming in `ls -l` on the host and is exactly
right. Check ownership numerically (`stat -c %u`), never by name — and postgres
validates PGDATA's mode at startup, so it cannot be handed to `me` without also
running the container as uid 1000, which then needs the socket dir moved.

**qaz-code's 184 GB lives in the DEFAULT `postgres` database**, not a named one —
`\l` shows only the three system DBs and that is not a failed restore.
`act_version` 104 GB, `act_version_chunk` 80 GB, extension `vector 0.8.4`. The
compose project is named `qaz-law` while the directory is `qaz-code`; the only
path that needed changing was the bind mount in the untracked, host-local
`compose.override.yml` (which has no home in git — `hosts/g15/` is where it
belongs).

**Restoring by PULL needs `--rsync-path="sudo rsync"`.** The *sending* side's
rsync is what must be able to read the tree, and local sudo does nothing for it.
Phase 1 never hit this because it pushed.

**Music went desktop-wsl → g15 direct, ~40 MB/s.** Not via latitude: that plan
existed because g15-under-Windows could not pull from OpenSSH by key, which
stopped being true. The 99 MB/s figure recorded elsewhere for this box is
tailnet throughput with no disk in the path; reading 88 GB off `/mnt/c` through
9p is the real ceiling.

**`fleet-selfpull` refuses a dirty tree silently and forever.** `air` sat 43
commits behind for eight days with 87 skipped runs, and the only evidence was a
counter in `~/.local/state/fleet-selfpull/dirty-<path>`. Nothing escalates. The
tree was dirty because of one uncommitted `AGENTS.md` edit; see `294c1ad` for
what was salvaged out of it.

**`orca-serve.sh`'s "none of [libxkbcommon0] installed" warnings over ssh are a
sudo artifact**, not missing packages. `_apt_try` runs `$SUDO apt-get install`,
and `me` has no NOPASSWD sudo on g15, so every dep install fails
non-interactively and warns. On a desktop box the libs come with GNOME anyway.

### All three staging legs are verified — the staging copies are now redundant (2026-09-07)

Proof, not confidence — the gate for deleting 292 GB of staging:

- **pgdata** — byte-identical, 198,834,159,212 B / 1268 files, postgres 18.4 up
  on 5436 with a clean recovery.
- **Music** — manifest match, **18377 entries**, path+type+size+symlink-target
  identical, and the count agrees with phase 1's `src=18377 dst=18377`.
  rsync's own tally: 14,878 regular files, 94,813,954,726 B, 0 matched (a fresh
  copy, not a resume).
- **home-me** — checked as a **subset, deliberately not a diff**: g15's live home
  has legitimately diverged (`.config` 4.3 G vs 11 M staged, `.claude` 8.6 M vs
  596 K) because the box is a new install that has been running for a day. Of
  226,123 staged regular files, **57 did not match on path+size**, and every one
  is named divergence: `machines`/`.dotfiles`/`.cache` (repos advanced 4 commits
  this session), `.config/orca/*` runtime state (Orca runs natively now),
  `.ssh/known_hosts*` (new host keys), `my/*/.git/FETCH_HEAD`,
  `my/qaz-code/compose.override.yml` (we edited it), `.local/state/dotfiles-sync/branch`
  (g15-wsl → g15), and **`.local/bin/orca`** — absent because `orca-serve.sh`'s
  new guard installed it as `orca-cli` instead. A green subset check with a
  reason for each miss is the useful shape here; a plain `diff` would have been
  57 lines of noise and no signal.

Where they sit: `latitude:/mnt/immich-mirror/g15-staging` (203 G — `home-me` 18 G
+ `pgdata` 186 G) and `desktop:/mnt/c/Users/methe/g15-staging/Music` (89 G).
`hosts/g15/staging/stage.sh` logged phase 1 to `/var/log/g15-staging` **on the
source box**, which was the wiped `g15-wsl` — so those logs are gone and this
section is the only surviving record of the phase-1 counts. The script itself
was **deleted 2026-09-09** (it could only run on a host that no longer exists);
the one live fact its `identity-snapshot.txt` carried — `origin/g15-wsl` is the
last copy of that box's host-local dotfiles — is now roadmap P6.

**Deleting the latitude staging also closes the `id_fleet` second copy** (its
private half is in `home-me/.ssh/`), which was one of the two arguments for
rotating the key. What survives rotation-wise is hygiene only: `methe@g15` and
`me@g15-wsl` are stale entries in `provision/fleet-authorized-keys`.

### The staging cleanup, and the one line in it that would have cut g15 off (2026-09-07)

Freed 105 GB and pruned the dead fleet trust. What is worth keeping:

- **`me@g15-wsl` in `provision/fleet-authorized-keys` was NOT a stale line.**
  Two lines named the wiped box and only one was dead. `me@g15-wsl`'s public
  half is byte-identical to the `id_fleet` now live on g15 — the private key was
  restored to the new Ubuntu install from the staging copy — so deleting it as
  "the other g15-wsl leftover" would have revoked g15 from the entire fleet. It
  is renamed to `me@g15`; `methe@g15` (the wiped Windows install's own key,
  private half gone with the disk) is the one that was removed. **The check that
  tells the two apart is matching each line's key body against the live
  `id_fleet.pub`, not reading the comments** — sshd ignores the comment and so
  does the key. Do this before pruning any line here.
- **`known_hosts` was never the problem.** I reported g15's host key as `STALE`
  on desktop-wsl and it was current — my own `awk` had taken `ssh-keyscan`'s
  banner line as the key. The bare `g15` entries on air and desktop-wsl are live
  aliases, kept. Only `server.gg.ez` and `g15-wsl.gg.ez` were dead and pruned.
- **`methe@g15` is pruned on all 6 members — desktop included, automatically.**
  This bullet said "5 of 6, pending an elevated shell, closed by its next
  `provision.ps1`", and both halves were wrong. The script is
  **`provision/windows.ps1`** (step 6d), not `provision.ps1` — that one is the
  role front door and never touches sshd. And it is not pending: on desktop the
  trust file's mtime is 16:54:04 and `converge` recorded `ok` on the revoking
  commit at 16:54:19, so it closed within minutes of the push.
  `C:\ProgramData\ssh\administrators_authorized_keys` still denies a
  non-elevated read, which is what made it look manual — but reading it was
  never the mechanism.

  **Why it works unattended: the post-merge hook fires `schtasks /run /tn
  machines-converge`, and that task is registered as SYSTEM.** So converge on a
  Windows box runs with a full token, `windows.ps1` step 6's
  `if (-not $isAdmin6) { throw }` passes, and 6d rewrites the file wholesale from
  `provision/fleet-authorized-keys` and re-locks the ACL by well-known SID. The
  hook's own comment says this is the point of the task. **A SYSTEM task is
  invisible to a limited token** — `Get-ScheduledTask` from the distro lists
  `fleet-selfpull` and not `machines-converge` — so absence there is not evidence
  it is unregistered. Consequence worth generalising: a key revocation reaches
  the Windows members through convergence like everywhere else, and the elevated
  path to check is `machines-converge`'s last result, never a read of the file.
- **`wsl-keepalive` and the `nc` ProxyCommand do not exist in this repo.** They
  were host-local on the wiped box, so phase 6's "retire the Windows-shaped
  workarounds" is already done for two of its three items. `ssh.user: methe` in
  `fleet.json` is **desktop's**, live and correct — g15 carries no `ssh` block.
- Headscale nodes 3 (`g15-retired`) and 9 (`g15-wsl`) deleted. Seven remain, all
  live; node 5 `ipheoryt12` is his phone, offline is normal.

### A WSL-era shim survived the native reinstall and shadowed xdg-open (2026-09-08)
- **A host-local WSL shim can outlive the distro and shadow a system binary.**
  `$HOME` survived the 2026-09-07 Windows→Ubuntu reinstall, so `~/.local/bin`
  still held `xdg-open`→`wslopen` (plus `wslview`), the opener
  `provision/wsl-fixes.sh` installs; it shells out to `powershell.exe`, so every
  `shell.openExternal` in every Electron app silently exited 1 — the symptom was
  Orca refusing to add a second Claude account. `~/.local/bin` precedes
  `/usr/bin`, the shims are untracked, so no provision run removes them and
  nothing reports them. All three deleted 2026-09-08 and none remains on g15.
  **When a GUI/tooling failure on g15 makes no sense, check `command -v <tool>`
  before believing the app is broken.**

## g15 has a restic client — and what is still NOT in it (2026-09-08)

`backup/g15/` exists, `backup-client` is in g15's roles, and the client covers
`~/my` (8.7 G) + `~/Music` (89 G). Repo is `rest:.../g513ie` on latitude's REST
server. What a future session would otherwise re-derive:

- **`~/my` earns its place on the GITIGNORED half.** All eleven checkouts have
  GitHub remotes; the tracked content is not what this protects.
  `qaz-code/laws` is 7.6 G of scraped corpus (`laws/` is in .gitignore) and is
  **the INPUT the 184 G database was built from** — the cheapest thing in the
  fleet to lose expensively. Plus four `.env` files, `buton/google-account.json`,
  `buton/harvester.db`, `telegrind/local/*.json`, and unpushed commits in the
  four repos that have been dirty for 65+ fleet-selfpull ticks.
- **PGDATA is excluded, and since 2026-09-10 permanently — do not "fix" this by
  adding the source.** The method was never the blocker and is proven on this
  exact data: a cleanly stopped PGDATA copied physically (the container's
  STOPSIGNAL is SIGINT = postgres fast shutdown, `me` is in `docker`, reading it
  needs root at `999:0` mode 700). It is excluded because the DB is rebuildable
  and its corpus (`~/my/qaz-code/laws`) is already a source here.

- **`schedule-permission: user_logged_on`, not `user`.** resticprofile's `user`
  means a ROOT-OWNED unit that merely runs as the user, so installing it needs
  sudo — and g15 has NO NOPASSWD sudo (`sudo -n` fails; latitude's works). The
  generated user timer carries `Persistent=true`, so a 05:00 window missed while
  the laptop was suspended fires on resume. `Linger=yes` here.
- **`schedule-ignore-on-battery` stays `true` on g15**, unlike BOTH of
  latitude's profiles which override it to false. Same key, opposite decision,
  and the reason is the box: latitude has sleep/suspend/hibernate masked, so
  "on battery" there means the mains failed; g15 is a laptop that gets carried
  around, where it is ordinary operation.
- **resticprofile is in `~/.local/bin` on g15, not `/usr/local/bin`.**
  `backup/restic-install.sh` is `sudo apt-get` + a curl'd installer into
  `/usr/local/bin`, so it cannot run on a box without NOPASSWD sudo at all.
  Installed with `install.sh -b "$HOME/.local/bin"` (0.33.1, matching the rest
  of the fleet). `backup_client_install` now appends `~/.local/bin` to PATH
  **before** its binary probe, because a non-interactive ssh PATH excludes it
  and the probe's wrong verdict was a hard role failure, not a slow path.
- **Three host-local secrets, escrowed once each — the machines repo is PUBLIC.**
  `~/.config/restic/{pass.txt,transport.txt,repo.txt}` on g15, tracked on the
  `g15` dotfiles branch (anchored `!` lines). `pass.txt` is escrowed a SECOND
  time on latitude as `~/.config/restic/g513ie.pass.txt`, because
  `g513ie-maintenance` prunes and checks the repo there — `--append-only` means
  the client cannot. Verified the two copies by sha256, not by eye.
- **The htpasswd user is created live, not from a repo:**
  `docker exec -i restic-server sh -c 'htpasswd -iB /data/.htpasswd g513ie'`.
  `-i` keeps the password out of argv; `create_user`'s two-arg form does not.
  The file lives inside the container's volume and is in no repo.
- **Six resticprofile timers on latitude now** (was four): the two new ones are
  `forget@profile-g513ie-maintenance` 09:30 and `check@profile-g513ie-maintenance`
  Sun 10:30, both clear of the four writers already on that drive.
- **The client declares no `check` schedule on purpose.** The integrity check
  runs on latitude, the box that HOLDS the repo — a client-side check goes dark
  at exactly the failure it should catch, a client that quietly stopped. Same
  argument as `g614jv-maintenance`, and the `check:` section is kept on the
  client only so nobody adds `check-before` without noticing it would inherit
  `read-data-subset` from there.

### The first snapshot, measured (2026-09-08)

- **`e5940ee8`** — 124985 files, 95.540 GiB processed → **88.945 GiB added,
  82.012 GiB stored**, in **36:34** (≈44 MB/s end to end, not the 99 MB/s
  tailnet ceiling: the `laws` corpus is ~125k small files and per-file overhead
  dominates the music half). На диске **83 G**.

- **Restore verified per source class, not just per repo**: `arbuz-concierge/.env`
  (362 B, gitignored), a `laws/codes/**/rus.md` (47983 B), and an mp3
  (1989603 B) — sha256 identical to the live files. `restic restore --include`
  restored 16 dirs for 3 files, which is the expected shape.
- **`check --read-data-subset=5%` from latitude: no errors**, 248 packs in 2:00.
  Run it there, not on the client — local disk, no tailnet, and the box that
  holds the repo cannot hide its own failure.
- **`--private-repos` isolation verified rather than assumed**: g513ie's
  transport credentials against `/g614jv` return **401**, so one client cannot
  read another's repo even though both live in one volume on one drive.

### Verifying it the way the repo demands — and the dirt that found (2026-09-08)

- **Fired the systemd USER unit, not the script.** AGENTS.md's rule ("verify a
  scheduled job by firing its schedule") earns its place here: the hand run had
  `export PATH=…` and cwd in the config dir, and the unit has neither.
  `systemctl --user start resticprofile-backup@profile-g15.service` →
  `Result=success`, `ExecMainStatus=0`, incremental in 0:11 / 207 KiB added
  (`skip-if-unchanged` plus the parent snapshot). **Check AC first** — with
  `schedule-ignore-on-battery: true` a battery run logs `WARN running on
  battery, leaving now` and exits 0, so a green Result would prove nothing.
- **`~/machines` on g15 had stopped pulling, and nothing said so.**
  `fleet.local.json.pre-migration` (137 B, the wiped g15-wsl's self-declaration,
  restored with `/home/me`) is untracked and `.gitignore`'s line is the exact
  name `fleet.local.json`, so the suffixed copy did not match. `git pull
  --ff-only` by hand ignores untracked files and worked, which is why this was
  invisible — `fleet-selfpull` does not, and had it counted as dirty. Deleted;
  the next tick pulled `69e61fb..993ef06`. **A hand pull succeeding is not
  evidence selfpull is pulling.**
- Latent hazard worth knowing: had that file been named `fleet.local.json`,
  `backup_client_identity` would have taken its nickname `g15-wsl` outright and
  looked for `backup/g15-wsl/`, i.e. skipped the backup on a green run. g15 is
  a `fleet.json` member and must carry no self-declaration at all.
- `backup/**/*.lock` is now ignored alongside `*.log`: resticprofile holds a
  lock in the profile dir for the length of a run and removes it on exit, so it
  never survives — but a selfpull tick inside a 36-minute first run would have
  counted a dirty tick against `~/machines`.
- Three repos under `~/my` on g15 (`buton`, `skep`, `vps`) are STALE at 97
  consecutive dirty ticks and `airdrome` SKIPs — pre-existing, his uncommitted
  work, and the posix selfpull DOES escalate ("dirty for 97 consecutive
  ticks — still not pulling"). It is the PowerShell one that has no escalation.

## What was still left of the g15 Ubuntu setup — audited on the box (2026-09-08)

Asked "is anything left"; answered by measuring g15 itself rather than reading
the spec's checkboxes. Three of the four open phase items were already closed by
the distro; the fourth turned out to be a decision the profile had already made,
not a step anyone missed.

- **The charge cap: my first read of WHY it was missing was wrong, and the rule
  it turned up is worth more than the fix.** Measured: `BAT0`
  `charge_control_end_threshold` = 100, no `charge-upto`, no default file, no
  unit. I diagnosed `tier_battery_limit`'s `PRIV=0` guard and told him to re-run
  the driver. The tier was **never in g15's plan**: g15 is `workstation`, which
  listed no `battery_limit`, and `tiers.test.sh` asserted that absence.
  **Read the profile's tier list before explaining why a tier did not run** — a
  plausible mechanism inside a tier body is not evidence the tier was reached.
  The spec's own §4 said "Charge limit via `tier_battery_limit`", so the plan was
  wrong first, which is the case for checking the code even against this repo's
  own documents.
- **THE RULE, from him (2026-09-08): a charge cap follows MAINS, not the profile
  and not the form factor.** "Both g15 and desktop (g16) are always-on-power
  hosts. So they both need a battery cap… Air won't get a cap because it's
  carried." So `battery_limit` is now on **both** posix profiles;
  `linux.sh`'s old "workstation = a laptop someone carries" described `air`
  alone and was untrue of both workstation-profile laptops the fleet has.
  desktop's cap is G-Helper's under Windows, not this repo's. Three consequences:
  - **`air` is protected by being darwin, not by its profile.** `macos.sh` has no
    battery tier, and the tier could not be shared anyway — it writes
    `charge_control_*` and `charge_types` under `/sys`. So the assertion that
    actually guards the carried laptop is `hasnt "$mac"`, not `hasnt "$ws"`.
  - **desktop-wsl no-ops, but not for the obvious reason.** Measured: the distro
    exposes `BAT1` and `AC1` under `/sys/class/power_supply/`; what is absent is
    `charge_control_end_threshold` inside it. `tier_battery_limit` loops testing
    for that FILE, not for a battery directory, which is the only reason it
    returns 0 there — I first wrote "WSL exposes no BAT*" and that is false.
  - **`tiers.test.sh` has a macos↔linux parity check** that reads any
    one-driver-only tier as drift unless it is an enumerated exception; adding
    the tier broke it, correctly. `battery_limit` is now its sixth documented
    exception — the first that is about hardware rather than packaging.
  - **It still needs one privileged run at g15's keyboard.** The tier is in the
    plan now and `--dry-run` says "no root available non-interactively —
    skipping the battery charge limit"; only a TTY run applies it.
- **The cap is APPLIED on g15 (2026-09-08): ceiling 85, unit enabled,
  `Result=success`, `ExecMainStatus=0`.** He ran `bash provision/linux.sh` at the
  keyboard. What the run revealed about this hardware and about the tier:
  - **g513ie exposes ONLY `charge_control_end_threshold`.** No
    `charge_control_start_threshold`, no `charge_types` — so the whole Dell story
    the tier was built around (the EC honours the ceiling only in `Custom` mode,
    which is why the mode write exists) is inert on ASUS asus-wmi, and the
    `CHARGE_START=80` in `/etc/default/charge-upto` is a knob with nothing to
    write. The cap itself works: `charge-upto` reported
    `BAT0 ?-85% mode  — now 100%, Full`.
  - **That report line carried a real bug, now fixed.** It read `charge_types`
    inline and was wrong twice: `tr … < "$b/charge_types" 2>/dev/null` **leaks**,
    because a redirection is processed before the command's own stderr redirect
    applies, so the SHELL prints `cannot open …: No such file` — an error line in
    the journal on every boot and resume of a unit that exits 0. And
    `… | tr -d '[]' || echo n/a` never fired, because `||` binds to the last
    command of the pipeline, which succeeds on empty input, so the mode column
    printed empty instead of `n/a`. Both reproduced before fixing, both covered.
    Replaced by a guarded `charge_mode()` helper.
  - **A nested function in a tier broke five unrelated assertions at once.**
    `tiers.test.sh` extracted tier bodies with `awk '/^tier_x\(\)/,/^}/'`, which
    stops at the first column-0 `}` — `charge_mode`'s. The fix is in the test
    (run to the next tier definition, then trim back to the last column-0 `}`),
    NOT indenting the function's brace to placate the awk. The other four tiers
    still use the fragile form; give it this one the moment one of them grows a
    nested function.
- **`hasnt` invites two mistakes and I made both, in two suites.** Its pattern
  goes to `grep -E`, so (1) a `$` in it is an end-of-line anchor, not a literal —
  `hasnt … '< "$b/charge_types"'` could never fire, and a mutation restoring the
  exact bad line passed clean; and (2) over a raw body it matches the COMMENT
  that quotes the bad form to explain it. Four wrong assertions between this and
  `tailscale-wsl.test.sh` before both were right. There is now a `code()` filter
  next to `has`/`hasnt` in `tiers.test.sh`: **an assertion about what runs must
  read only what runs.** `has` is usually safe raw; `hasnt` usually is not.
- **The PRIV=0 observation survives on its own, as a class.** g15 has no NOPASSWD
  sudo, so on any non-interactive run every privileged tier that IS in its list
  degrades to a warn and exit 0 — `bash provision/linux.sh` prints "no root
  available non-interactively — skipping" for `apt_min`, `apt_dev` and `docker`
  in a row, then finishes green. Same silent-green family as `PLANNED_ROLES` and
  the `platform: linux` trap, reached through the privilege gate. `linux.sh`
  takes prompting `sudo` only on a TTY, so a privileged tier can be applied here
  only from the box's own keyboard.
- **The kernel had already absorbed the asus-linux stack, which inverts the
  spec's phase 3.** Open NVIDIA module 595.84 with `prime-select` = `on-demand`
  (both GPUs enumerated), `asus_custom_fan_curve` exposed at hwmon7 under
  `asus-nb-wmi`, charge threshold as plain `asus-wmi` sysfs. So `asusctl` /
  `supergfxctl` — the "build from source, own phase, own rollback, could eat a
  weekend" item — are convenience and were never installed. The ≥6.19 kernel
  floor that chose Ubuntu is exactly why.
- **The 2.4 GHz wifi record is retired.** g15 associates on **ch112 / 5560 MHz /
  80 MHz / 1170 Mbit/s**. "Stuck on 2.4 GHz channel 12, no band-preference
  property" was a property of the wiped Windows driver, not of MT7921.
- **`just` is installed now — 1.58.0 into `~/.local/bin`, not apt's 1.45.0.**
  The archive has `just` (`resolute` ships 1.45.0-1) but installing it needs
  sudo, which this box does not have non-interactively, so it went in the way
  `gortex` and `resticprofile` already live here: a prebuilt musl tarball into
  `~/.local/bin`. `just test` then reported the gate itself — **54 suites, all
  passed** — which is also the count AGENTS.md was carrying as 48. No tier
  installs `just` on any box (roadmap P6); this closes g15, not the fleet.
- **The 89 G music pile on latitude was proven redundant and is DELETED
  (2026-09-08, his go). spare320: 82 G → 170 G free.** The proof was run against
  snapshot `b46c563d` **directly, not through g15's live tree**: path+size
  manifest identical (14878 rows, empty `diff`, byte totals equal to the digit),
  plus five sha256 matches hashed from an actual restore — largest file (528 MB),
  smallest non-empty (74 B), two random, Cyrillic paths throughout. Two things
  the deletion itself taught:
  - **The pile was root-owned**, so an unprivileged `rm -rf` died with
    `Permission denied` across most of the tree and left the directory standing
    at 537 files. latitude has NOPASSWD sudo and g15 does not — that asymmetry
    decides which box can clean up its own disks.
  - **Assert the identity (count + bytes) BEFORE the destructive command**, not
    after: because the full tree had already been pinned, finishing a
    half-deleted state needed no re-derivation and no second judgement call.
- **The DB leg is CLOSED, 2026-09-10 — not deferred.** ~~DEFERRED until the new
  8 TB HDD passes acceptance (his call, 2026-09-08); the 186 G `pgdata` staging
  leg stays and must not be deleted.~~ He decided the database needs no backup:
  it is rebuildable, and `~/my/qaz-code/laws` (7.6 G, the corpus it is built
  from) is already a restic source on g15. So the whole argument was about 186 G
  of derived index. The staging copy was deleted 2026-09-10 after re-confirming
  the live DB up on g15, and the g15 NOPASSWD-sudo blocker went void with it.
  Space had already stopped being the blocker when the music pile went.
- **`restic ls <snapshot> <path>` is not recursive.** It reported 1 file / 3 dirs
  for that 14878-file tree — indistinguishable at a glance from a backup that
  stored almost nothing. `--recursive` is mandatory whenever a path filter is
  given, and the first number I read off it was wrong because of this.
- **A second Claude session had committed `70422f9` here and not pushed it**, so
  `~/machines` sat **ahead 1 / behind 5** — and `fleet-selfpull` is ff-only, so
  its next tick could not pull either. Worth knowing that a clean tree is not
  evidence selfpull is current; check `status -sb`, not `status --short`.
- Nothing else is outstanding that is g15-specific: the desktop toolchain (nvim,
  rust, go, ghostty) is deliberately nobody's job, `ssh-server` is the fleet-wide
  P3 stub (latitude is hand-rolled too), and `buton`/`skep` at 124 dirty
  selfpull ticks are his own uncommitted work.


## Приёмка нового диска: identity-гейт впереди surface (2026-09-08)

Runbook — `docs/2026-09-08-8tb-acceptance-plan.md`, скрипт —
`hosts/latitude/debian/disk-acceptance.sh`, тесты —
`provision/tests/disk-acceptance.test.sh`.

- **Прошлая потеря была ПОДМЕНОЙ товара, а не смертью диска** (подтверждено им
  же 2026-09-08). Роадмап писал «как именно сломался — не записано»; записано:
  `docs/superpowers/specs/2026-07-30-6tb-return-claim-ru.md` — вместо нового
  6 ТБ WD Purple приехал HGST Ultrastar `HUS726060ALE611` 2015 г., 74 502 ч,
  3.02 ПБ, под наклейкой WD Purple. **Поверхностный тест такой диск прошёл бы.**
  Отсюда порядок: identity (~5 мин, решает возврат, идёт по часам магазина)
  строго перед surface (~41 ч, решает доверие данным, идёт по гарантии).
- **WWN — единственный идентификатор, который перенаклейкой не подделать:**
  прожжён на заводе и несёт OUI. `50014EE2…` = Western Digital,
  `5000CCA…` = HGST (подпись июльской подмены). Парсить только то, что **после
  двоеточия**: слова «LU WWN Device Id» сами состоят из валидных hex-цифр и
  давали мусорный префикс `deced…` (поймано живым прогоном).
- **JMS561U (оба CM198) пропускает 48-битные GP-log чтения** — измерено на доках
  2026-09-08: через `-d sat` читаются каталог логов 0x00 и SATA Phy 0x11. Четыре
  старых 2.5″ шпинделя отвечают «Device Statistics (GP 0x04) not supported`
  потому что сами старше ACS-3, а не из-за моста. `-d sat,12` не может работать
  в принципе (12-байтный passthrough не несёт 48-битную команду). То есть от
  диска 2025 года Head Flying Hours / Logical Sectors Written **ожидаются
  читаемыми**, и их отсутствие — вопрос к диску.
- **`badblocks -b 4096` обязателен на 8 ТБ.** При дефолтных 1024 B это 7.8e9
  блоков — выше потолка badblocks в 2^32, и он падает. `-c 4096` — потому что
  дефолтный буфер в 64 блока морит BOT-мост. `badblocks` **не возобновляется** →
  только под `systemd-run`.
- **ETA считать с коэффициентом 1.4** (первый час — внешние дорожки, к внутренним
  CMR-шпиндель падает примерно вдвое). **Прогон целиком, 2026-09-09: 16 ТБ за
  26 ч 27 м = 168 MB/s в среднем** на WD80EAAZ через CM198. 227 MB/s — это был
  пик на внешних дорожках из пробы в первые минуты; **для ETA берём 168**.
  Поправка 1.4 к пику дала 27 ч против 26.5 фактических — метод подтверждён.
  Это первый в парке замер **3.5″** через эти доки: прежние 86 / 97 / 36 MB/s —
  2.5″ шпиндели, упиравшиеся в себя, а не в мост. Для 3.5″ прикидка роадмапа в
  150 MB/s занижена.
- **Surface пройден 2026-09-09, VERDICT PASS.** `badblocks -w -t random` по всем
  1 953 506 646 блокам: 0 бэд-блоков, 0/0/0 ошибок, атрибуты 5/197/198 = 0, 199
  не сдвинулся, ни одного `usb reset` за 26.5 ч. Devstat подтвердил, что диск
  действительно прожевал весь объём: Logical Sectors Written 15 628 053 168 —
  ровно ёмкость, Head Flying Hours 26, POH 30, максимум температуры 41 °C.
  Диск можно доверять данным. Сырьё — `docs/2026-09-08-wd80eaaz-smart-evidence.txt`.
- **`g15-staging/pgdata` доказан избыточным 2026-09-09 — сверкой кластера, не
  на глаз.** `system_identifier` из `global/pg_control` staging-копии и из
  `pg_control_system()` живого `qaz-law-db-1` на g15 совпали:
  **7659741180334813227**. Первые 8 байт `pg_control` — это и есть
  `system_identifier`, читается питоном без `pg_controldata`, который всё равно
  не прочёл бы файл v18. **Стоявший здесь запрет «удалять пока нельзя, сначала
  лег в restic» СНЯТ 2026-09-10** — БД признана перестраиваемой, лега не будет,
  staging-копия удалена; см. «The DB leg is CLOSED» выше.

- **На XS2000 нет ничего уникального, но он держит единственную вторую копию
  архива 1970–2024** (663 G, источник живой на `/mnt/immich-2024/admin`;
  `xs-keepers` уже лежит на зеркале; `Boot`/Ventoy пересобирается). Вынули его
  из парка 2026-09-09 → у закрытого архива снова одна копия, и та на флаки-доке.
  Копировать с XS нечего; нужно перенаправить `archive-mirror.sh` на 8 ТБ.
- **Свободных бэев нет: 8 ТБ занял бэй зеркала.** Док 4-1 — servarr + spare320,
  док 4-2 — новый 8 ТБ + immich-2024. Вернуть `immich-mirror` в стойку можно
  только после того, как ServarrMedia переедет на 8 ТБ и освободит свой бэй; до
  тех пор диск зеркала лежит на столе, а `g15-staging` (204 G) на нём — в
  единственном экземпляре.
- **Identity нового WD80EAAZ (S/N RD2RRPWH) пройден 2026-09-08**: Head Flying
  Hours 0, Logical Sectors Written 0, 5/197/198/199 = 0, ёмкость ровно
  8 001 563 222 016, WWN совпал, журнал самотестов пуст. Сырьё —
  `docs/2026-09-08-wd80eaaz-smart-evidence.txt`. **ATA-серийник несёт префикс
  `WD-`, которого нет на наклейке** — точное сравнение дало бы ложный RETURN.
- **Выключение дока A забирает ОБА бэя.** 2026-09-08 при замене зеркала ушёл и
  `immich-2024` (bay 2): mount-юнит `dead` после I/O-ошибок, `immich_server`
  остался с мёртвым `/dev/sde2`. Лечится `systemctl start /mnt/immich-2024`
  (переигрыш журнала ~25 с) + `docker restart immich_server`. И `mask` на
  таймеры зеркала НЕ встаёт: `install-timers.sh` копирует юниты в
  `/etc/systemd/system`, там работает `disable --now`.
- **Бэй под тест берём у `/mnt/immich-mirror` (dock A bay 1), не у `spare320`.**
  Проверено живьём: `/mnt/immich-mirror` не биндит ни один контейнер, это
  копия, и `mirror-refresh.service` несёт `ConditionPathIsMountPoint`. (Вывод
  верен, но проверялось по `.HostConfig.Binds` — **ненадёжный ключ**, см.
  раздел про `.Mounts` ниже; перепроверено 10.09 по `.Mounts`, всё так же ноль.
  `ConditionPathIsMountPoint` с тех пор снят — он и оказался дефектом.) Выселение `spare320` уложило бы backup-hub всего
  парка на 41 ч (`restic-server` биндит `/mnt/spare320/restic-rest`). Возврат
  монтирования — **руками**: fstab-записи `nofail`, никто их не перетягивает.
- Диск на руках: `WD80EAAZ-22BXBB0`, S/N `RD2RRPWH`, WWN `50014EE216C6BF75`,
  R/N `3VAHA2`, Thailand **19 MAY 2025** (за 16 мес. до покупки — гарантию WD
  считает от производства, если нет подтверждения даты покупки). Срок возврата
  DNS 14 дней от 2026-09-07 → **до 2026-09-21**, surface стартовать **не позже
  2026-09-18**.

## Lid close no longer sleeps a mains-bound box — `tier_lid_ignore` (2026-09-08)

What the tier is and why it exists is in `AGENTS.md` (the `tier_*` list, and the
latitude entry). Only what was measured on the boxes is kept here.

- **g15 shipped stock: `HandleLidSwitch=suspend`, `HandleLidSwitchExternalPower=suspend`**,
  and logind's own config was the whole lever — `/etc/systemd/logind.conf.d/` did
  not exist, GNOME's idle suspend is already `nothing` on AC and battery
  (`org.gnome.settings-daemon.plugins.power sleep-inactive-*-type`), and
  `systemd-inhibit --list` showed **no** `handle-lid-switch` block from gsd-power
  (GNOME only takes that one with an external monitor attached). That negative is
  the reusable part: do not re-investigate GNOME here.
- `HandleLidSwitchDocked` and `IdleAction` are already `ignore` upstream
  (`systemd-analyze cat-config systemd/logind.conf`, systemd 259 on g513ie / 257
  on latitude), which is why the tier writes two keys and why deleting latitude's
  hand-written `99-server.conf` changes nothing.
- **Drop-ins merge in filename order, so read back the merged config, not the
  file you just wrote.** `cat-config`'s LAST assignment is the effective one; the
  tier warns by name about a competing drop-in, and latitude's `99-server.conf`
  sorts after `99-fleet-lid.conf` and will keep nagging until P6 retires it.
  Retire it AFTER latitude's next converge run, never before: `tiers.sh` is a
  `_touches_driver` trigger, so that run comes on its own.
- Both mutations bite: masking a sleep target, and dropping the `/proc/acpi/button/lid`
  gate, each turn an assertion red.

## `hub` is in Almaty — it cannot be a censorship-bypass exit node (2026-09-09)

- **`hub`'s egress is `78.40.108.102`, Almaty KZ, AS48716 PS Internet Company** —
  measured on the box, not inferred. So the VPS lives in the same jurisdiction as
  every other fleet member and is behind the **same ISP-level DPI**: `curl
  https://archive.org/` times out there exactly as it does on g15, while
  `openssl s_client -noservername` to the same IP handshakes fine.
- **Consequence for any "route around a block" design: no existing fleet box is a
  usable exit node**, `hub` included. `tailscale exit-node list` is empty and no
  member advertises one. A foreign node would have to be rented (Oracle Always
  Free / GCP e2-micro joined to Headscale with `--advertise-exit-node`).
- **But the local fix is usually enough, because the filter reads only the TLS SNI
  field.** Port 80 with a `Host:` header sails through; a TLS record boundary
  placed inside the SNI string (`ciadpi -r1+s`, byedpi) restores the domain with no
  tunnel, no detour and no speed cost. Full measurements — which strategies failed,
  which names are on the block list — are in g15's `~/.claude/host-memory.md`.
- The block list is a **name list, not a domain match**: `web.archive.org` is
  reachable while `archive.org`, `www.archive.org` and the `ia*.us.archive.org`
  download nodes are not. Do not conclude "the domain is blocked" from one probe.
- Not provisioned by this repo (no tier, no role): the byedpi install on g15 is a
  hand-rolled systemd **user** unit. If a second box needs it, that is the moment
  to make it a tier — a `~/.local/bin` binary plus a user unit needs no root, so it
  would fit `agents`-style user-scope provisioning rather than `linux.sh`.
- **Superseded the same day: the deploy target is the ROUTER, not a per-box tier.**
  The home LAN is one NAT behind a GL-iNet **GL-MT6000** (`192.168.8.1`), so one
  install there covers every LAN member *and* the phones, the TV, Windows and macOS —
  none of which a `tier_*` could reach. What makes it viable was measured: upstream's
  aarch64 release binary is **static-pie**, so the same tarball runs on OpenWrt/musl
  with no cross-compile. **Landed the same day** (`ciadpi -E` + dnsmasq-populated ipset +
  an fw3 include; verified from latitude with no local proxy) — the shape, its
  DNS-path limit and the rollback are in `~/.claude/memory/global.md`
  (`### Deployed at the router, not per box`). `hub` is NOT behind that router and
  keeps its own per-box install — and it needs its own block list anyway (`torproject.org` stays 000 there
  with `-r1+s` that works on the LAN).

## RustDesk on g15: unattended Wayland works, greeter included — but only in a preview build (2026-09-10)

- **Upstream's own capability, not a community hack** — announced 2026-08-14 for
  **x86_64 Debian/Ubuntu only**, which is exactly g15. **NOT in stable 1.4.9**;
  it ships as a separate preview build, installed here as
  `rustdesk-unattended-wayland` 1.5.0 (.deb from the `nightly` tag). Trust
  `rustdesk.com/blog/unattended-remote-access-wayland` over third-party
  writeups — both found were partly wrong, and the DRM/KMS capture backend
  (discussion #15417) is a PROPOSAL, not a release.
- **The mechanism, proven across a reboot on this box.** The packaged unit is
  `User=root`, but root captures nothing itself: it `sudo -u <user>`s a
  `rustdesk --server` into each graphical session on the seat, injecting that
  session's `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`.
  At boot one of the spawns is **`gdm-greeter` (uid 60578)** carrying the
  greeter's own `wayland-0`. **So it does not need a logged-in user; it needs a
  graphical session on the seat, and the GDM greeter is one** — and GDM
  auto-login is OFF here (every `AutomaticLogin*` key in `/etc/gdm3/custom.conf`
  still commented out), so the login-screen pass was a real one. The corollary
  is the limit: a box with **no display manager running** offers nothing to
  attach to, so this is no route to a headless server's console.
- **Deliberately NOT a `tier_rustdesk`, and the reason is the tag.** The
  `releases/download/nightly/...` URL is stable but its BYTES are replaced in
  place; combine that with the `tier_gortex` precedent of untarring the pin
  unconditionally and any provision run for any reason silently swaps the box's
  remote-access daemon. Pinning the per-asset `digest` only trades silent drift
  for break-on-every-upstream-rebuild. **Revisit when it lands in a stable
  release, not before.**
- **Both configs must be seeded, and `systemctl is-active` proves nothing.** The
  service reads `/root/.config/rustdesk/RustDesk2.toml`, the tray reads the
  user's; seeding one leaves the other on the public `rs-ny.rustdesk.com`. The
  actual proof the options took effect is that RustDesk **rewrites its own
  top-level `rendezvous_server` to `cyphy.kz:21116`** on restart. Seeding is
  `hosts/g15/ubuntu/rustdesk-seed.sh` — a merge, never a clobber. The unattended
  password is set in the tray, never by script: it lives in `RustDesk.toml` as an
  encrypted per-install secret, which is why the seed script never touches that
  file.
- Live state: id **`1722388240`** against our own `cyphy.kz` hbbs
  (`[keys_confirmed] cyphy = true`). **`/dev/uinput` needed no udev rule
  precisely because the service is root.** Peer map in
  `docs/2026-08-01-nixos-harvest.md` §2). The server's public key had not rotated
  since the NixOS tag — checked against the live `hbbs` container's
  `data/id_ed25519.pub` on hub, not against the tag.
  **Direct IP access is OFF, and that is the default, not a regression:** nothing
  listens on 21118, so a connect to `100.64.0.10` reaches nothing and it is not a
  tailnet fault. Connect by ID.
- **The rejected alternative, so it is not re-derived:** `gnome-remote-desktop`
  50.2 is ALREADY installed on g15, ships a `gnome-remote-desktop-headless.service`
  and `grdctl` sets
  credentials non-interactively — Wayland-native unattended RDP with no
  rendezvous server at all. Rejected only because RustDesk is one tool across
  Windows/macOS/Linux/Android; it stays the fallback if the preview regresses.

## Доки роняет розетка, а не USB — и это два разных отказа (измерено 2026-09-10)

Инцидент 2026-08-23 был не одиночным. По журналу за 2026-07-29..09-10 (все
загрузки, `journalctl --boot=all`; **`-k` подразумевает текущую загрузку — мой
первый замер был слепым на 11 boot'ов**) видно **восемь** событий одной формы:

```
usb 4-1: USB disconnect   07:37:12
usb 4-2: USB disconnect   07:37:13      <- второй док в ту же секунду
usb 4-1: new SuperSpeed … 07:37:37      <- сами вернулись через ~25 с
```

04.08 (×3), 16.08, 23.08, 01.09 (×2), 02.09. Два физически независимых дока на
разных портах падают в одну секунду и возвращаются вместе — это розетка, а не
шина: ни `PM: suspend`, ни сброса контроллера в окне нет.

- **`ACPI: AC Adapter [AC] (off-line)` за всё это время — РОВНО ОДИН раз
  (29.07T02:15), и не в момент падения.** Значит просадка короче порога, на
  котором EC замечает потерю AC: 65-ваттный кирпич ноутбука её переживает,
  дешёвые 12 В блоки доков — нет. Это и есть механизм.
- **Ноутбук сам себе UPS, доки — единственная часть фленки без батареи.** Отсюда
  же живучесть bind-race: хост не падает и продолжает писать, пока диски
  исчезают. UPS на блоки доков закрывает весь класс; разнесение копий по докам —
  нет, стена забирает оба в одну секунду.
- **Разнесение копий по докам почти ничего не даёт против главного отказа.**
  Настоящие независимые домены — внутренний NVMe (едет на батарее ноутбука) и
  off-box. По докам разносить всё равно стоит, но это второй по важности риск,
  не первый.

**Второй, отдельный отказ — «флаки-док 4-2».** Шторм 31.07T22 → 02.08T03:
25 `usb 4-2: reset` под нагрузкой, **только 4-2, без 4-1** — вот это
действительно линк/док, и отсюда `UDMA_CRC_Error_Count` 144 у `sdf`
(immich-2024) и 18 у `sdb`. **С 17.08 не повторялся**: 8 ТБ прогнал через 4-2
16 ТБ за 26 ч с нулём CRC и нулём сбросов. AGENTS.md и этот файл описывают
4-2 как постоянно флаки — это состояние июля-августа, а не свойство дока.

**Не сваливать одно в другое.** `disconnect` обоих доков = питание;
`reset` одного под нагрузкой = линк. Первое лечится UPS, второе — кабелем/доком.

## ServarrMedia переехал на 8 ТБ WD Blue (выполнено 2026-09-10)

`/mnt/wd8` — `/dev/sdd1` на момент записи, но идентичность диска это
`wwn-0x50014ee216c6bf75` / `WDC WD80EAAZ-22BXBB0` / S/N `WD-RD2RRPWH`;
UUID фс `726efd1f-7eb1-45d7-a09e-1e9467c6319f`, метка `wd8`, ext4 `-m 1`.
**`usb-` by-id имя тут не идентичность** — оно несёт серийник ДОКА и одинаково
у обоих отсеков (`…-0:0` / `…-0:1`).

Скрипт — `hosts/latitude/debian/migrate-servarr-wd8.sh`
(`plan|prepare|sync|status|verify|cutover|rollback`). Что он доказал на живом
прогоне:

- **Двухпроходная схема окупилась ровно так, как задумано.** Балк-проход 2 ч
  31 мин под работающим стеком: 736 732 102 931 байт, `speedup 1.22`. За это
  время источник потерял один хардлинк (`Spawn.1997`), и `verify` честно упал:
  файлов 2075 против 2076, при **совпавших до байта** real 736 552 035 464 и
  инодах 2041. Delta под погашенным стеком удалила лишнее за 158 КБ трафика,
  повторный verify — PASS. **Так будет всегда: `verify` вне `cutover` против
  живого стека почти наверняка покажет дрейф — это свойство, а не поломка.**
- **Ловит именно группировка ссылок, а не суммарная экономия.** Real-байты
  сошлись идеально при реальном расхождении; поймал канонический `frozenset`
  групп инодов.
- Простой стека — минуты. Пути внутри контейнеров (`/data/*`) не менялись,
  правится только `DATA_ROOT` в `homeserver/servarr/.env` → БД *arr и
  qBittorrent трогать не надо.
- `/mnt/wd8` **добавлен в `MOUNTS`** `install-docker-ordering.sh` ДО первого
  бинда — окно, от которого защищает guard 3, это самый первый `compose up` на
  новый диск.
- **`/mnt/xs` в `/etc/fstab` закомментирован** (диск физически снят): живой
  `[E]` в `findmnt --verify` полностью блокировал `install-docker-ordering.sh
  -go`. Это был латентный дефект самого скрипта — любая посторонняя протухшая
  строка вырубала главный guard фленки; **исправлен в тот же день** (гейт
  сравнивает кандидата с текущим файлом), см. раздел про гейты, рапортующие
  успех.
- Старая копия servarr на `/mnt/servarr` (sdb2, HGST 931 G) держалась до
  проверки, что в qBittorrent нет errored-торрентов. **Условие выполнено в тот
  же день** — qBittorrent перехешировал все раздачи против wd8, диск освобождён
  и принял вторую копию закрытого архива 1970–2024 вместо снятого `/mnt/xs`.


## Оба restic-репозитория на 8 ТБ — и почему гейт «поздний pull» не гейт (2026-09-10)

Хаб `restic-rest` (112 G: g513ie + g614jv) и собственный репозиторий latitude
(12 G) переехали `/mnt/spare320` → `/mnt/wd8` скриптом
`hosts/latitude/debian/migrate-restic-wd8.sh`. Балк-проход 40 мин (123 G,
~58 МБ/с), дельта под остановленными писателями — ноль байт, обе проверки
чистые с первого раза (в отличие от servarr: репозиторий append-only, и хаба
за время копии никто не трогал).

- **Проверять надо не rsync.** Байт-в-байт необходимо и недостаточно;
  сохраняемое свойство — «restic этим может пользоваться». `restic check` по
  всем трём репозиториям, до и после: 33 / 19 / 4 снимка, одинаково. Baseline
  снимался на источнике ДО копии — иначе падение проверки на приёмнике нечем
  объяснить.
- **Коммит с новыми путями нельзя придержать до `cutover`.**
  `fleet-selfpull.service` — пользовательский таймер, который сам делает
  ff-merge всех fleet-репозиториев; он подтянул коммит за 25 минут до конца
  копии, и `profiles.yaml` указал на `/mnt/wd8` поверх наполовину
  скопированного дерева. Ничего не сломалось только потому, что до 04:30 не был
  запланирован ни один писатель: `run-before` в профилях — половина гейта, он
  проверяет наличие объекта `config`, а не ПОЛНОТУ репозитория, так что
  `forget --prune` в этом окне отработал бы по частичной копии. Поэтому
  писателей останавливает `sync`, в начале, а не `cutover`: это суточные
  задания, вся миграция меньше часа — держать их выключенными дешевле, чем
  угадывать окно. И `status` печатает, сколько таймеров стоит: брошенная между
  `sync` и `cutover` миграция иначе тихо оставляет бэкапы выключенными, а
  `systemctl --failed` на просто остановленный таймер чист.
- **Что переезд НЕ купил.** На `/mnt/wd8` лежит и ServarrMedia, отдельного
  диска у репозиториев больше нет; радиус поражения теперь ограничивает
  off-site копия, а не выбор отсека. И опасность пустой точки монтирования
  никуда не делась: доки роняет розетка, а 8 ТБ стоит в таком же доке.
- **Освободилось:** место для PGDATA-ноги g15 (~130 G) — это был единственный
  storage-блокер, теперь 6.4 T свободно. Копии на `/mnt/spare320` не тронуты —
  сносить только после выдержки, и это то, что освободит отсек дока.

## Архив 1970–2024 получил вторую копию — и почему не на 8 ТБ (2026-09-10)

- **Комната была не той осью.** `/mnt/wd8` с 6.4 T свободного выглядел
  очевидным приёмником для 663 GiB архива, и это худший выбор из доступных:
  wd8 и источник `immich-2024` — два отсека ОДНОГО дока Ugreen (`usb4/4-2`),
  один общий линк 5 Гбит; HGST на `4-1` имеет свой линк. Контроллер один
  (10 Гбит) и он никогда не был ограничением. **Мерить топологию (`udevadm info
  -q path -n sdX`) до выбора отсека, а не размер.** Довод «на 4-2 24 reset'а за
  сутки» в этом выборе НЕ участвует: тот шторм кончился 17.08 — см. раздел про
  доки.
- Живая расстановка на 2026-09-10: `u4-1:0` spare320, `u4-1:1` HGST
  (`/mnt/immich-2024-backup`), `u4-2:0` wd8, `u4-2:1` immich-2024,
  `u3-2.4:0` immich-mirror в стопгап-корпусе NS1066.
- **HGST освобождён под архив, потому что копия servarr была ДОКАЗАННО
  избыточна**, а не потому что «прошло достаточно дней»: verify PASS на живом
  стеке (цифры — в разделе про ServarrMedia) плюс qBittorrent уже перепроверил
  все раздачи хешами против wd8. Выдержка по календарю стоила дороже, чем
  давала: невосстановимые фото лежали в одной копии, пока единственный
  подходящий отсек держала избыточная копия скачиваемой медиатеки.
- Приёмник стал ext4 вместо exfat, и это сняло весь набор уступок:
  `-aHAX` вместо `-rlt --no-perms --no-owner --no-group --modify-window=1`.
  Восстановление больше не требует `chown`.
- **`rollback` в `migrate-servarr-wd8.sh` теперь отказывается, если источник
  пуст.** Старое тело направило бы `DATA_ROOT` на путь, который уже не точка
  монтирования; docker создаёт отсутствующий bind-источник, стек поднялся бы на
  пустом каталоге на `/`, и базы *arr свели бы библиотеку к нулю. Проверка —
  «есть ли файлы», а не флаг: маркер пришлось бы обновлять тому, кто удалял
  источник, а именно этот класс забывчивости здесь и ломается.
- **`du -sb` НЕ считает `st_size` каталогов** — измерено на GNU coreutils 9.7
  (latitude) и uutils 0.8.0 (desktop-wsl). Я утверждал обратное — что гейт
  `archive-mirror.sh` на равенстве `du -sb` напечатал бы ложный `INCOMPLETE`, —
  и это было неверно дважды: механизм не тот, а «доказательством» служило
  сравнение недокопированного дерева с полным (каталог, в который ещё пишут, не
  достиг конечного размера). **Механизм, который собираешься написать в
  сообщении коммита, — это ровно тот момент, когда его надо померить.**
- **Оси групп хардлинков в этом гейте нет НА ПРОВЕРЕННОЙ предпосылке** — в
  дереве 0 файлов с `nlink>1` (2026-09-10 и обзор 2026-08-01). Скрипт теперь эту
  предпосылку проверяет и кричит, если она перестанет держаться; тогда нужна
  группировка, как в `migrate-servarr-wd8.sh phase_verify`.
- **Асимметричное sudo снова.** `-verify` читал источник через `sudo find`, а
  приёмник голым `find`: под каталогом, который не обойти, `find` недосчитывает
  МОЛЧА и печатает MISMATCH на здоровой копии. Ровно та форма, что заставляла
  самопроверку хаба звать живые restic-репозитории MISSING. Выживает потому, что
  ловится только ручным прогоном — юнит работает от root.
- **Нельзя править файл скрипта, пока его юнит работает**: bash дочитывает
  скрипт с диска по ходу, а `git pull` может усечь тот же инод. Правильно —
  остановить юнит (rsync возобновляемый, `--partial-dir` держит недокачанный
  файл), подтянуть, запустить снова.
- Метка ext4 обрезается до **16 байт** без ошибки, только с
  `Warning: label too long` — `immich-2024-backup` стал `immich-2024-back`.
  Живёт как `immich-2024-bak`.
- **`just` на desktop-wsl нет, и ручной прогон сюит требует `</dev/null`** —
  без него цикл проглатывает часть сюит (тест, читающий stdin, выедает остаток
  подстановки процесса). Это НЕ дефект гейта: рецепт `test` уже делает
  `bash "$t" < /dev/null`. Ловушку репозиторий уже знал; переоткрыл её я.

## Гейт, который рапортует успех, ничего не сделав — общая форма (2026-09-10)

Пять отказов одного класса за один день на latitude. Механизмы и итоговые
правила лежат в `AGENTS.md` (*Key patterns*: `Condition*`/`Result=success`,
гейт `findmnt --verify`, конвенция кодов 75/78, `.Mounts` вместо
`.HostConfig.Binds`) — он грузится каждой сессией, здесь только то, чего там
нет.

- **Форма, по которой их узнавать:** защита, чей отказ неотличим от «работы не
  было». Проваленная `Condition*` → `Result=success`; гейт `findmnt --verify`,
  выключавший сам себя из-за чужой строки в fstab; `rollback`, направляющий
  `DATA_ROOT` на путь, который уже не точка монтирования (docker создаст пустой
  bind-источник, и откат уничтожит то, что должен вернуть); `run-before` в
  restic-профилях, проверяющий наличие объекта `config`, а не ПОЛНОТУ
  репозитория; просто остановленный таймер, который в `systemctl --failed`
  чист. Спрашивать надо «как выглядит этот гейт, когда он не сработал», а не
  «что он проверяет».
- **Обоснование в комментарии было ещё и фактически ложным.** `/mnt/immich` —
  это `/dev/nvme0n1p1`, второй ВНУТРЕННИЙ NVMe, никакого дока; «источник
  отключили» там не бывает в принципе. Комментарий пережил переезд ФС,
  на которой был написан.
- **Остаточный риск, названный явно:** самолечение приёмника даёт
  `Result=success`. Диск, отваливающийся каждую ночь, теперь перемонтируется и
  копируется — из «невидимо и сломано» стало «невидимо и работает». Единственный
  след — строка `WARN … remounting once` в журнале. Настоящее лечение — увести
  зеркало с этого порта (см. раздел про 480 Мбит).
- **У `install-docker-ordering.sh` не было ни одного теста** — при том что он
  стоит между Docker и автосозданием bind-источника на корне (два инцидента:
  servarr 03.08.2026, immich-2024 03.09.2026). Чтобы файл стал сорсабельным,
  блок запуска ушёл в `main()` за `[ "${BASH_SOURCE[0]}" = "$0" ]`.
- Сегфолт `findmnt --verify` в тесте **подменён функцией-заглушкой**, а не
  воспроизведён: иначе кейс отвалится на util-linux, где багу починят.
- `fstab_patch` **переписывает строку в выровненные колонки**, поэтому `remove`
  обратен `add` по полям, но не по байтам — и наивный diff `/etc/fstab` после
  прогона показывает изменённой каждую охраняемую строку.
- Грабли тестов на юниты: оба зеркальных скрипта **описывают** в комментариях
  тот `findmnt -no SOURCE`, который заменили, — утверждение «этой строки нет»
  сначала запретило объяснять, зачем меняли; комментарии режутся `sed` перед
  проверкой. И `archive-mirror.sh` держит два присваивания в одной строке, так
  что якорь `^…UUID=` на регистр не сработал.
- Мутации: `docker-ordering.test.sh` — снятие `rc>=2` 4 падения, возврат гейта
  на весь файл 4, retirement-скан без пропуска членов набора 2;
  `latitude-timer-units.test.sh` — 7 из 7.
- **Апостроф внутри `ssh box '…'` разрывает команду.** Питон-правку с
  `connector's` в комментарии съело на середине, `assert` ушёл в bash. Скрипт
  правок — через stdin: `ssh box 'sudo python3 -' < file.py`.

## Зеркало сидит на 480 Мбит из-за ОДНОГО порта хаба, а не из-за коробки (2026-09-10)

- Ядро говорит это прямым текстом: `usb 2-2-port4: Cannot enable. Maybe the USB
  cable is bad?` — 4 раза, оба раза при переподключении. Топология:
  `2-2` — тот же хаб на 5000 Мбит (SuperSpeed-сторона живая), `3-2` — его же
  480-сторона, NS1066 висит на `3-2.4`. **Ни один другой порт этого хаба такого
  сообщения не даёт.** То есть SuperSpeed-дорожки не поднимаются именно на
  порту 4.
- **Порядок подозреваемых поэтому меняется: порт хаба → кабель → коробка.**
  Раньше в памяти стояло «у NS1066 не контачат SuperSpeed-пары» — это была
  догадка, и она оказалась ПОСЛЕДНЕЙ в списке, а не первой. Проверка стоит 30
  секунд: переткнуть в другой порт того же хаба и посмотреть
  `cat /sys/bus/usb/devices/*/speed`.
- Следствие для планов: ждать освобождения `spare320` ради бэя Ugreen, возможно,
  не нужно вовсе.
- Событие 18:01:33 10.09 в журнале — это его переподключение, не новый сбой.
  16:30:54 — тот самый отвал, который скрыл `ConditionPathIsMountPoint`.

## GoPro-видео уехало в immich, зеркало полегчало на 226 ГБ (2026-09-10)

- **На бэкапном диске стояли 226 ГБ данных в ЕДИНСТВЕННОЙ копии** — это ровно
  то, чего бэкапный диск не должен делать. `staging/` (40 G видео с GoPro,
  подписано «вторая копия», а первой не нашлось ни на g15, ни на десктопе, ни
  на дисках latitude) и `g15-staging/pgdata` (186 G снимок postgres). Обе
  папки были dest-only: `--delete` выключен, в источнике их нет, **ни один гейт
  в репозитории их не видит**. Проверяй, что накопилось dest-only на зеркале.
- **Видео залито в immich через официальный CLI в докере**, альбом
  «Настя Стас GoPro», 162 объекта (158 mp4 + 4 jpg), 41.9 ГБ, дубликатов 0.
  Ключ API создаёт владелец в UI; путь `originalPath` в ответах API —
  **внутри контейнера** (`/data` = `/mnt/immich/ImmichMedia/library`), первая
  попытка проверки отрапортовала 162 MISSING именно из-за этого.
- **`GET /api/albums/{id}` не отдаёт `assets` даже с `withoutAssets=false`** —
  только `assetCount`. Список с контрольными суммами берётся через
  `POST /api/search/metadata` с `albumIds`. `checksum` там — sha1 в base64.
- **Гейт удаления: sha1 каждого файла НА ДИСКЕ против суммы, записанной immich,
  и на nvme, и на зеркале.** 162/162 сошлись с обеих сторон, объём 41 905 063 663
  байта совпал с исходной папкой. Это правильнее, чем сверять исходник с базой:
  перед удалением важна целостность ХРАНИМОЙ копии, и читать её с nvme в 20 раз
  быстрее, чем перечитывать 42 ГБ по USB.
- **Порядок операций: залить → проверить → отзеркалировать → проверить копию на
  зеркале → и только теперь удалять исходник.** Если удалить сразу после
  заливки, данные полдня живут в одном экземпляре до ночного прогона.
- CLI по умолчанию читает 7 файлов параллельно — на механическом диске это 10
  МБ/с вместо 80. С `-c 3` вышло ~22 МБ/с; сначала он хеширует ВСЁ (полчаса на
  42 ГБ, прогресс стоит на 0%), потом заливает.
- Запускать долгие задачи на latitude надо `docker run -d` / detached: проверку
  на 42 ГБ, шедшую через ssh, убил OOM на локальной машине.

## 280 строк защиты от зависания лежали незакоммиченными на g15 (2026-09-11)

- **Работа, сделанная НА боксе, на боксе и осталась.** `~/machines` на g15 был
  грязным с 9 сентября: 280 строк — `tier_oom_guard` + `tier_sysrq`, AGENTS.md,
  README.md, `linux.sh`, `tiers.test.sh`. В репозиторий не попало ничего.
  Проверять надо не только «зелёный ли гейт», а **чистое ли дерево на каждом
  боксе фронта** — грязное дерево к тому же останавливает `fleet-selfpull`, так
  что g15 два дня не подтягивал ничего.
- **Перенос: `git apply --3way` из `git diff` по ssh.** Патч сначала в
  scratchpad, `--3way` чтобы конфликт был маркерами, а не тихой промашкой, и
  `git stash` на боксе (а не `checkout --`), пока не доказана избыточность —
  единственная копия работы была именно в том diff.
- **Из двух тиров применён был только один, и не тот, что казалось.**
  `tier_sysrq` жив с той ночи, а `tier_oom_guard` — нет: `user-.slice.d` не
  существовало, лимиты `infinity`. Защита при этом БЫЛА, но пользовательским
  файлом `~/.config/systemd/user/app.slice.d/50-memory-guard.conf`, то есть
  только для того, что запускает рабочий стол; по ssh то же самое не
  покрывалось. После прогона `bash provision/linux.sh` на его клавиатуре:
  user-1000.slice MemoryHigh=18.2 G / MemoryMax=22.7 G / MemorySwapMax=2 G,
  вживую. (Про лексический порядок `/etc/sysctl.d` и конкурирующий
  `60-sysrq.conf` — в AGENTS.md, *Key patterns*.)
- **NOPASSWD на g15 снят со списка, а не сделан.** Он был там ради ноги бэкапа
  qaz-law/PGDATA, а её владелец отменил 2026-09-10: база пересобираема, а корпус
  `~/my/qaz-code/laws` (7.6 G), из которого она строится, уже лежит в restic
  g15. Спорили, выходит, про 186 G производного индекса. Плюс
  `provision/tests/tiers.test.sh` прямо утверждает, что профиль `workstation`
  NOPASSWD не выдаёт никогда.
- **Четыре живых места в репо приказывали не удалять то, что удалено вчера** —
  `backup/g15/profiles.yaml`, `hosts/g15/ubuntu/README.md`,
  `docs/fleet-roadmap.md` и этот файл. Инструкция будущей сессии, ставшая
  ложной, опаснее устаревшего факта: она запрещает действие, которое уже
  совершено. Помечены закрытыми с датой, не вычищены.
- **Побочно: `fleet-selfpull.test.sh` три недели писал в живое состояние.**
  `FLEET_SELFPULL_STATE` подменялся не с начала файла, и вызовы `selfpull_one`
  выше писали в `~/.local/state/fleet-selfpull` — тот самый каталог, куда каждые
  10 минут пишет реальный таймер (62 файла здесь, 34 на g15). Подмена перенесена
  в начало, мусор удалён. Один прогон гейта из трёх дал одиночный красный именно
  на этом сьюте и не воспроизвёлся; причину я не поймал — общее изменяемое
  состояние с работающим таймером это объясняло бы, но доказательства нет, и
  «environmental» это не диагноз.

## memory-harvest / fleet-gather.sh gotchas (demoted from global.md 2026-09-11)

- **Invoke `fleet-gather.sh` by its repo path, or pass `FLEET_JSON`.** It derives
  `SKILL_DIR` with a plain `cd … && pwd` (logical, not `-P`), so when the skill is
  reached through the `~/.claude/skills/cyphy` symlink, four-up resolves to
  `~/.claude/fleet.json` — which does not exist. `fleet_hosts` then returns empty
  and the whole run degrades to **local-only with no warning**, indistinguishable
  from "no fleet configured". Use
  `~/machines/agents/plugin/skills/memory-harvest/fleet-gather.sh` or
  `FLEET_JSON=$HOME/machines/fleet.json`.
- **The remote digest dir `~/.cache/kb-digests` is never pruned**, and the pull is
  `tar cf - .` over the whole dir, so every run re-delivers previous runs' digests
  (carrying their remote mtimes — so the *stale* ones can sort **newer** than the
  genuinely fresh local ones, and nothing in the file marks which run delivered
  it). **`manifest.tsv` is NOT the authoritative
  list for a fleet run** — the remote pull is a `tar` that EXCLUDES it, so a
  remote box's digests can never appear in it. Measured 2026-09-11: 14 rows
  against 47 genuinely new digests, i.e. trusting it would have discarded 33 of
  47. It is authoritative for the LOCAL box only. For remote digests the usable
  discriminator is the per-run mtime of the freshly pulled files — but check it
  against each host's reported `digests_written` (the numbers must sum), because
  a stale remote digest can carry a newer mtime than a fresh local one.
- **Self-exclusion is by OS hostname, which a WSL distro shares with its Windows
  parent.** Running memory-harvest inside WSL on `g614jv` prints `[desktop] is this
  box, skipping self` and never harvests the Windows-native
  `/c/Users/<user>/.claude/projects` profile. Run it from the Windows side to
  cover those sessions.
- On Linux the four-up `fleet.json` default resolves **correctly** through the
  `~/.claude/skills/cyphy` symlink, because the kernel resolves `..` physically
  after following the symlink — a logical `pwd` only affects the string, not what
  the OS opens. Verified on `g614jv` (WSL): `SKILL_DIR` printed
  `/home/me/.claude/skills/cyphy/skills/memory-harvest`, and
  `$SKILL_DIR/../../../../fleet.json` opened `/home/me/machines/fleet.json`. So the
  local-only degradation is not universal — it presumably needs a path layer that
  normalizes `..` lexically (MSYS/Git Bash) or a copied rather than symlinked skill
  dir. Passing `FLEET_JSON` explicitly is harmless and still the safe habit.
  <!-- conflicts-with: "**Invoke `fleet-gather.sh` by its repo path, or pass `FLEET_JSON`.** It derives `SKILL_DIR` with a plain `cd … && pwd` (logical, not `-P`), so when the skill is reached through the `~/.claude/skills/cyphy` symlink, four-up resolves to `~/.claude/fleet.json` — which does not exist." -->
  <!-- src: airdrome c4d5423 | 2026-07-26 -->
- **`git -C ~/machines pull --ff-only` (the cron prompt's Lane 2 preflight) can abort
  on a clean tree.** A prior unattended run commits shared memory locally and, if its
  push step never ran, leaves `main` ahead while origin moves on — the tree is clean
  and `git status` says nothing, yet the pull fails `Not possible to fast-forward`.
  Seen on `g614jv`: 1 ahead / 3 behind. Reconcile with `git merge origin/main`
  (never rebase — fleet repos), then continue; treat it as normal, not as the
  prompt's "dirty tree, defer Lane 2" abort condition.
  <!-- src: airdrome c4d5423 | 2026-07-26 -->
- **A transcript slug dir outlives the checkout it was named after, so a slug is
  not evidence the repo is on that box.** `~/.claude/projects/<cwd-with-dashes>/`
  is never garbage-collected when the working copy is deleted; what remains can be
  an empty husk (only a `memory/` subdir, zero `.jsonl`). Seen 2026-07-26:
  `C--Users-methe-GitHub-airdrome` still listed on the Windows side of `g614jv`
  while nothing named `airdrome` exists anywhere under `C:\Users\methe`. Before
  concluding a box holds unharvested sessions — or that a repo is checked out
  there — check for `.jsonl` files, not just the directory.
  <!-- src: airdrome ff21a95 | 2026-07-26 -->
- **The cron prompt's `last_refresh.commit` is the pre-write HEAD, so Track B's
  baseline permanently lags one refresh and every run re-diffs the previous run's
  own docs commit.** Verified against the full history of airdrome's
  `.claude/kb-harvest-state.json`: the field has never once equalled the refresh
  commit it was written by (`ef148b8` → committed as `c4d5423`, `c4d5423` →
  `ff21a95`, `ff21a95` → `10a649e`). The result is that a repo with no real
  activity between runs still shows a non-empty `<base>..HEAD`, consisting
  entirely of kb writes — which reads as drift and isn't. Fix without contradicting
  the doc: keep the base semantics, but have Track B skip commits whose subject is
  `docs(kb): refresh knowledge base against …`.
  <!-- src: airdrome ff21a95 | 2026-07-26 -->
  - Second-repo sighting: qaz-code's first refresh recorded
    `last_refresh.commit = 4c25471` while committing as `c5ec625`. Same offset,
    different repo — the lag is in the prompt's Step 6 wording ("HEAD sha from
    Step 0"), not in one repo's state file.
    <!-- src: qaz-code c5ec625 | 2026-07-26 -->
- **A repo that gitignores `.claude` wholesale silently breaks the whole harvest,
  and the failure is invisible until the next run.** The state file
  `.claude/kb-harvest-state.json` is only load-bearing if it is *git-tracked*: the
  watermark advances at gather time, so if it can never be committed, every run
  re-reports the same sessions or (worse, once a stale untracked copy exists)
  reports "0 digests" forever. Plenty of repos have a bare `.claude` line from a
  "gitignore local config" commit. **Check before gathering** —
  `git check-ignore -v .claude/kb-harvest-state.json .claude/memory/project.md` —
  and fix it with negations, not `git add -f` (a force-added file still confuses
  the next run's `git status` preflight). A bare `.claude` cannot be negated from
  inside, because git never descends into an excluded directory; the pattern has to
  become `.claude/*` first:

      .claude/*
      !.claude/kb-harvest-state.json
      !.claude/memory/
      .claude/memory/*
      !.claude/memory/project.md

  Verify with `git add -A --dry-run` — it must list exactly those two paths and no
  `settings.local.json`.
  <!-- src: qaz-code 4c25471 | 2026-07-26 -->
- **The cron job's Lane 1 writes can land where nobody reads them.** Step 6 pushes
  the *worktree branch*; merging back into `main` is user-gated (worktree-mode
  rules) and an unattended run has no user, so it can silently never happen. The
  repo's own `project.md` then keeps improving on a branch while the base checkout
  — where agents actually work — goes on loading the pre-refresh copy from `main`,
  and the gap widens by one commit per run with nothing flagging it. Seen on
  airdrome 2026-07-28: several consecutive `docs(kb): refresh` commits stacked on
  `metheoryt/ubuntu26-airdrome-memory-harvest-daily` while `/home/me/my/airdrome`
  `main` still sat at `ff21a95`. The behaviour is the same in every repo — the
  cron prompt has no merge step at all — so a repo whose refresh commits *have*
  reached `main` (qaz-code's `c5ec625`) only got there because someone worked in
  the base checkout afterwards and fast-forwarded it in passing. Don't go looking
  for a config difference between two cron jobs; there isn't one. Whether a repo's
  memory is current on `main` is purely a function of unrelated human activity.
  Cheapest check when reading a cron-refreshed repo's memory:
  `git log --oneline main..<refresh-branch>`. The durable fix is either a final
  FF-merge step in Lane 1 or accepting that the branch, not `main`, is the source
  of truth for that repo's memory.
  <!-- src: airdrome 9fd979a | 2026-07-28 -->
- **Lane 2's targets are no longer in `machines` — `agents/memory/` and
  `agents/hosts/` were deleted on 2026-07-28** (`87bf673`, `6364b31`). The agent
  memory store now lives in the private dotfiles bare repo at its real `$HOME`
  paths: `~/.claude/memory/global.md` and
  `~/.claude/memory/personality/{tone,habits,values,practices}.md` on dotfiles
  `main` (shared, byte-identical everywhere), `~/.claude/host-memory.md` on each
  machine's own branch. `agents/plugin/skills/memory-harvest/` survived the move, so
  the `fleet-gather.sh` invocation path above is still correct. The harvest
  prompt, the reflection prompt and the skill's tier table all pointed at the
  dead paths for a day and were re-pointed on 2026-07-29 (`1340072`, `35a5244`).
  Two consequences a run still has to keep in mind:
  - **You can no longer write another box's host memory.** Per-host files are
    branch-scoped, one per machine, so from `g614jv` latitude's is readable but not
    writable:
    `git --git-dir=$HOME/.dotfiles --work-tree=$HOME show origin/latitude:.claude/host-memory.md`.
    A `host:<name>` candidate for a box you are not sitting on has to be reported,
    not written.
  - **`agents/memory/projects/*` has no counterpart at the new location.** It did
    not move; there is no per-project tier in the dotfiles store. Repo-specific
    facts go to Lane 1 and nowhere else.
  <!-- conflicts-with: "**`git -C ~/machines pull --ff-only` (the cron prompt's Lane 2 preflight) can abort on a clean tree.**" -->
  <!-- src: airdrome adae7fe | 2026-07-29 -->
- **After that move, unattended Lane 2 stops one step short of shared memory —
  the same failure as the Lane 1 merge-back gap, and worse.** Appending to
  `global.md` is now a plain write to a file tracked in the dotfiles bare repo;
  the 10-minute `dotfiles-sync` timer commits and pushes it to *this machine's*
  branch (`/dotfiles-sync` forces that immediately), but getting it onto dotfiles
  `main` — where every other box and the Hermes reflection job read it — is a
  manual `/dotfiles-promote`, user-gated exactly like the Lane 1 merge-back. The
  cron prompt's whole premise is that the reflection job curates what the harvest
  jobs append; until someone promotes, it cannot see any of it, and the harvest
  jobs' append-only design means nothing else will ever surface the backlog. An
  unattended run should write, let the timer (or `/dotfiles-sync`) commit, and
  report the pending promote by name. It must never run `dotfiles checkout main`
  to "get to" the shared copy — that deletes every host-local tracked file from
  `$HOME`, `~/.ssh/config` included.
  <!-- src: airdrome adae7fe | 2026-07-29 -->
- **A repo's basename is NOT a safe `--match` fragment once repos nest.** The
  skill's Step 0 says it is; measured on g15 2026-09-12 it is not. The depth-2
  glob finds dozens of repos here and the number is not worth writing down — a
  scheduled clone dropped a whole second `~/kazakhstan-law-0912/` tree in *while
  this very harvest was running*, so the set moved under the run's own feet. Two
  of those repos are both called `codes` (`~/kazakhstan-law/codes` and
  `~/split-test/codes`), so one `--match codes` harvests both into whichever
  repo asked. Worse, `~/kazakhstan-law` is itself a repo AND the parent of two
  dozen nested per-region ones, so `--match kazakhstan-law` is a substring of
  every child's slug and pulls all of them in.
  Qualify a nested repo with its parent directory (`kazakhstan-law-codes`,
  `split-test-codes`) and keep the bare basename only for a repo that is unique
  at depth 1. The failure is silent in both directions — over-matching looks
  like a productive run, and the cross-matched facts land in the wrong repo's
  `project.md`.
  <!-- conflicts-with: "Slug matches: **the repo's basename is enough**." -->
  <!-- src: machines 73a5334 | 2026-09-12 -->
- **One batched gather covering every repo at once works, and a box this size
  needs it.** The skill files N-fan-outs-for-N-repos as a known unoptimised
  cost; on a box with repos in the dozens that is dozens of ssh fan-outs per
  nightly run. Passing every
  repo's `--match` to a single `fleet-gather.sh` invocation against one union
  state file does the whole box in one pass, and the digests partition by repo
  afterwards from their own `# cwd:` header. Nothing in `distill.py` had to
  change for it.
  <!-- src: machines 73a5334 | 2026-09-12 -->
- **The transcript filter is a directory-name substring glob, so a work repo's
  sessions are never opened at all.** `distill.py` globs
  `~/.claude/projects/*<match>*/*.jsonl` — a slug like
  `-home-me-pure-backend-api` is not read on any box, and raw transcripts never
  leave the machine they live on; only the distilled digests come back.
  Demonstrated 2026-09-11: air holds nine `backend-api` / `claude-plugins` slugs
  in the same directory and reported exactly the 14 `machines` sessions. The
  same substring rule is what makes the collisions above possible, and it also
  means a *worktree* whose path happens to contain the match word is harvested
  regardless of which repo it belongs to.
  <!-- src: machines 73a5334 | 2026-09-12 -->

## The fleet-ssh renderer and `provision/ssh-wsl.sh` (demoted from global.md 2026-09-11)

`machines`-repo mechanism, not fleet-wide truth. The portable halves — "a stale
block reads as unreachable, re-render after a membership change" and the
two-failure-mode tell — stay in `global.md` under *Fleet SSH reachability*.

- **The generated `# >>> fleet-ssh` block goes stale silently, and a missing member
  reads as "unreachable".** Found + fixed on `desktop-ubuntu26` 2026-07-30: the
  on-disk block held only latitude/desktop/server/hub — no `Host air`, though `air`
  is a full `fleet.json` member (`ssh-server`, `repos`, `agents`, `dotfiles`). So
  `ssh -G air` resolved to the stock `identityfile ~/.ssh/id_rsa …` with no
  `id_fleet` and no `accept-new`; under `BatchMode=yes` that dies as a bare
  `Host key verification failed.` and `fd_probe` files it as plain "unreachable" —
  meaning `fleet-selfpull`, `/ship`'s `fleet-pull.sh` and memory-harvest's
  `fleet-gather.sh` had all been skipping `air` from that box. **Not a renderer bug:**
  `ssh_wsl_render_config` iterates every `.machines` entry unfiltered, so the block
  was simply written before `air` joined (it also predated the 2026-07-29
  unconditional-`User` change — latitude's stanza had no `User me`). Re-run
  `provision/ssh-wsl.sh` after any fleet.json membership change.
  - **Distinguishing tell for the two SSH failure modes:** `latitude`'s error names
    an offending `known_hosts` line, `air`'s named nothing. Named line = stale host
    key; nothing named = no `Host` stanza / no identity.

  - **`ssh-wsl.sh` cannot run unattended** — its sshd step needs `sudo`, which dies
    with `sudo: A terminal is required to authenticate`, aborting before it ever
    reaches the config block. The config half is a pure jq function over
    `fleet.json` with no sudo requirement, so it can be rendered standalone and
    spliced between the markers; the inbound half (sshd + the
    `fleet-authorized-keys` snapshot into `~/.ssh/authorized_keys`) is what needs
    the TTY. Check whether it does before asking for one — on desktop-ubuntu26 every
    fleet key body was already present and only the `methe@methe-server` comment was
    stale (cosmetic, the box is `g513ie` now), so the sudo run was unnecessary.

## memory-harvest 2026-09-11 — what the fleet transcripts held (Track A + B)

### The harvest machinery itself

- **Run `/memory-harvest` BEFORE `memory-harvest` on the same box.** Dream's queued items carry
  verbatim replacement text keyed to a memory file's *pre-harvest* content;
  memory-harvest appending to the same file invalidates those replacements. (The
  `manifest.tsv` correction above is from the same run.)
- **latitude has no `~/.claude/projects` directory at all**, so the services host
  contributes zero transcripts to every memory-harvest — absence, not failure. Don't
  chase it as a broken dispatch.
- **Transcripts had a 30-day expiry until 2026-09-10.** `agents/settings.json` now
  sets `cleanupPeriodDays: 90` (Claude Code's silent default is 30), added after
  desktop-wsl was found holding 350 of 479 local transcripts unharvested and
  everything between the 2026-07-24 refresh and the 30-day cutoff already deleted.
  **That window is gone for good.** The value must live in the tracked baseline,
  not a hand-edit of the deployed `~/.claude/settings.json`, or `agent-bootstrap`
  overwrites it.
- **`enabledPlugins` in `agents/settings.json` loads at USER scope on every repo on
  every box**, not per-project — `sentry@` and `atlassian@` were removed 2026-09-08
  because the Pure repos already carry their own MCP config for both.

### Backups / restic

- **`check-before` at profile level is silently inert in resticprofile 0.33.1** — it
  parses and echoes back from `show`, and never runs. It must be nested under
  `backup:`. Reading the YAML cannot tell working from inert; grep the run log for
  the issued `restic check --read-data-subset` line.
- **`roles/backup-hub.sh` schedules nothing and creates no repositories** —
  verification only. `backup/latitude/profiles.yaml` holds BOTH the `latitude` and
  `g614jv-maintenance` profiles and `backup-client`'s `schedule --all` installs
  both from one place; a second scheduler in `backup-hub` would race to write the
  same four unit files.
- **`roles/backup-client.ps1`'s apply path has never run.** It exists and is
  registered in `provision.ps1`'s `$RoleExecutors`, but no `backup/desktop/`
  profile dir has ever been shipped to run it against (`backup/g15/` does exist).

### Test-harness traps — three shapes of false green

- **`roles.test.sh` used to `source` a hardcoded three-file list** of role
  executors, which is a false-green *generator*: a forgotten role leaves its
  `role_*` function undefined, the call emits "command not found" into `2>&1`,
  that text does not match the expected skip pattern, and the `not_skipped` check
  passes anyway. Now globs `roles/*.sh` plus a `defined()` helper.
- **`tiers.test.sh`'s `hasnt()` feeds its pattern to `grep -E`**, so a bare `$` is
  an end-of-line anchor rather than a literal and can make an assertion
  permanently inert. Its `awk '/^tier_X()/,/^}/'` body extraction also truncates
  early on any tier that defines a nested function (the nested `}` is at column 0);
  only `tier_battery_limit` and `tier_lid_ignore` use the robust form that scans to
  the next tier and trims back.
- **Not every `*.test.sh` prints `ALL PASS` as its last line**, so a loop grepping
  for that string undercounts failures. Check each suite's exit code — which is
  what `just test` does.

### Provisioning shape

- **`provision/linux.sh` and `provision.sh --apply` are two separate entry
  points**, and `provision.sh` never invokes the tier driver. On a fresh box
  `linux.sh` must run first, or a role like `repos` (which needs `gh` from
  `tier_apt_dev`) finds nothing.
- **A `tier_*` function cannot be run outside a driver**: `info`/`warn`/`ok`/`have`
  are defined in `linux.sh` and `macos.sh`, not a shared lib.
- **No tier installs tailscale or `just`** — the fleet's own transport and its
  documented command surface are both hand-installed on every Linux box. Roadmap P6.
- **`ts_mint_key` defaulted `HEADSCALE_SSH` to `debian@cyphy.kz`**, which matches no
  block in the generated `~/.ssh/config` (only `Host hub hub.gg.ez` exists), so
  `--enroll` failed with "Host key verification failed" from every fleet box.
  Fixed 2026-09-08 with a single `ts_headscale_target()` accessor defaulting to the
  alias `hub`.
- **`repos.sh`'s dry run is NOT inert** — it switches the active `gh` account and
  restores it — so `repo-groups.test.sh` deliberately never runs `repos.sh` and
  shims `bash` to assert the composed argv instead.
- **`curl … | $SUDO tee "$file"` reports tee's exit status, not curl's**, and
  `provision/linux.sh` runs without `pipefail`: a 404 or truncated download prints
  "installed" and the script proceeds with a corrupt file. Fetch to a temp file,
  check curl's own rc and non-emptiness, then `install` it.

### Orca

- **`orca serve` starts its own Xvfb on `:99` when `DISPLAY` is unset, and under
  WSLg that can never work** — `/tmp/.X11-unix` is mounted read-only there, so Xvfb
  cannot bind its socket and Electron crash-loops on "Missing X server or $DISPLAY"
  instead of degrading. Hand it WSLg's already-live `:0`.
- **Electron flushes a non-tty stdout only at process exit**, so a systemd unit's
  `journalctl` output — the pairing URL included — stays empty until the process
  dies. Run it under `script -qefc "<cmd>" /dev/null` to give it a pty while
  preserving the exit status for `Restart=on-failure`.
- **RustDesk's unattended-Wayland install on g15 is deliberately NOT a tier.** The
  preview `.deb` is served from the mutable GitHub `nightly` tag whose asset bytes
  are replaced in place (rebuilt 2026-09-01 and again 2026-09-10), so any
  provisioning run would silently swap the box's remote-access daemon. Revisit when
  the capability ships in a stable release.

### Agent config

- **`register-reinject.sh`** re-injects a ~475 B per-turn cue extracted from
  `memory/core.md` between the `REGISTER-REINJECT:START/END` markers, capped at
  900 B by its own suite. It replaced a `tone-reinject.sh` that
  `personality/tone.md` had claimed existed since 2026-08-04 but which was never on
  disk or wired anywhere.
- **The `gortex:rules` span inside `~/.claude/CLAUDE.md` is regenerated per-box** by
  `gortex install` (it embeds that box's own `$HOME` in an `@import`), while
  `CLAUDE.md` itself is shared on dotfiles `main` — so a box without gortex gets a
  dangling `@import`, and any fallback note must live OUTSIDE the markers or the
  next `gortex install` overwrites it.
- **Two Claude sessions can commit to the same checkout concurrently** without
  either knowing — a diverged HEAD, and one commit's message surviving only in
  `git reflog` after the other `--amend`s its content in. Check `ps` and
  `git reflog` before assuming you are the only writer in a shared checkout.

### Repo housekeeping

- **`.gitignore`'s `*.sublime-*` line must stay** even though Sublime is off g15:
  `hosts/desktop/windows/windows-reinstall-runbook.md` still winget-installs
  `SublimeHQ.SublimeText.4`, and a stray project file on that box dirties the clone
  and makes `fleet-selfpull` silently skip it.
- **`review/2026-08-03-path-ledger.md` holds a keep/delete/merge verdict for 240
  paths**, and five weeks later exactly 1 of its 19 actionable rows had been acted
  on. This repo's cleanup bottleneck is unmade decisions, not missing measurement —
  consult the ledger before commissioning a fresh audit.
- **A design exists to retire `provision/statusboard/`** for node_exporter +
  smartctl_exporter + cAdvisor + Prometheus + Grafana (containers in the sibling
  `vps` repo) plus a chromium kiosk:
  `docs/superpowers/specs/2026-09-09-statusboard-to-grafana-design.md` (`bf790bf`),
  not implemented. Three statusboard facts have **no exporter equivalent** and must
  stay a custom textfile collector: the Dell battery charge window, per-bay disk
  naming from `disks.latitude5520.conf`, and "expected but unmounted" detection —
  the check that catches a dropped USB dock.

### Other boxes' host facts (parked here — their `host-memory.md` is branch-scoped)

These were harvested on g15 and belong in `desktop` / `desktop-wsl` / `latitude`
host memory, which is not writable from this box. Move them when a refresh next
runs there; until then this is their only home.

**desktop-wsl — the Docker Desktop family.** The cross-distro socket share
`/mnt/wsl/docker-desktop/shared-sockets/host-services/` can silently lose its bind
mount (docker/for-win#8032), hanging every `docker` call inside the distro while
`docker.exe` from Windows still works; fix is `docker.exe desktop restart`. After a
restart the per-distro integration agent can die writing the credstore
(`wsl.exe -d <distro> -e sh -c "cat - > ~/.docker/config.json"`, `Wsl/Service/0x8007274c`
at exactly 30 s), which stops `/var/run/docker.sock` ever being recreated —
pre-fill `~/.docker/config.json` with `{"credsStore":"desktop.exe"}` so DD skips
that write. **Never kill a hand-started `docker-desktop-user-distro proxy`**: it
unlinks the socket path and orphans DD's own listener, tearing down the whole
integration. **A torn-down integration never self-heals** while the toggle still
reads enabled — check `%LOCALAPPDATA%\Docker\log\host\com.docker.backend.exe.log`
for fresh `wsldistroproxy` lines, not `docker ps`. DD's backend log is timestamped
**UTC** while the box is `+0500`, which once made one teardown look like two. And
DD's "Skip WSL distro integration" button is persistent, not a dismissal — it
writes `EnableIntegrationWithDefaultWslDistro: false` into `settings-store.json`.

**desktop.** RDP with a bare Microsoft-account UPN fails NLA silently and looks
exactly like a wrong password; the working forms are `MicrosoftAccount\<email>` or
`g614jv\methe`. The client caches one credential per PC entry and reuses it even
after retyping. `Orca.exe` holds a Windows `DISPLAY` power request (visible in
`powercfg /requestsoverride`), keeping the screen on regardless of the power plan.
The box has no S3, only Modern Standby, so the AC **"Sleep after"** timer — not the
screen-off timer — is what pulls it under once the screen darkens; it must be Never
for "screen off, agents keep running". Wake-on-LAN is wired-only (Realtek GbE,
`S5WakeOnLan=1`); the AX211 Wi-Fi has no working WoWLAN, and as of 2026-08-31 the
cable was on a different L2 segment (APIPA). `.wslconfig` raised `memory=` 16→40 GB
(host 63.6 GiB) and that ceiling is **VM-wide** across every distro plus the DD
backend, not per-distro. desktop carries TWO dotfiles instances —
`/home/me/.dotfiles` (branch `desktop-wsl`) and `C:\Users\methe\.dotfiles` (branch
`desktop`); a Windows-only file like `.wslconfig` belongs on the latter.

**latitude.** Deleting a movie/series in *arr only removes the library-side
hardlink — the qBittorrent copy stays and nothing reclaims the space, because *arr
stops tracking a torrent once imported (only 3 of 46 live torrents were in Radarr's
queue). To find what is actually freeable, check link count under `torrents/`
(n=1 is an orphan) and use `st_blocks*512`, not `st_size`, for in-progress
downloads. Enabling qBittorrent's ratio auto-delete is safe for the library
(verified: 25 torrents removed with files, `df` unchanged, 0 missing files) but it
puts a deadline on any stuck `importPending` item that used to sit safe forever.
qBittorrent's WebUI returns `Forbidden` for API calls from localhost
(`AuthSubnetWhitelist=100.64.0.0/24`) — call it via `--interface 100.64.0.8`. And
**the dual-dock disconnects were confirmed by the owner on 2026-09-11 as real home
power outages**, not the brief voltage dips previously assumed — which moves UPS
selection from AVR-only toward runtime/autonomy plus USB NUT monitoring for a
graceful shutdown.

## memory-harvest 2026-09-11, air addendum — 14 sessions, 2026-07-31..08-31

Air was unreachable on the first pass and harvested on a second. Its window
predates most of the above, so what survived dedup is mostly machinery nobody
revisited since.

### gortex hooks — three defects, one of which meant no hook ever ran on Windows

- **`windows.ps1` never installed `jq`**, and `gortex_merge_hooks` is written in
  jq — so it silently no-opped and **gortex's `PreToolUse` hooks never ran on ANY
  Windows box, at any posture, until 2026-08-30**, when `windows.ps1` gained
  `winget --id jqlang.jq`.
- **`gortex_merge_hooks`' jq predicate `isgx` matched only the literal
  `"gortex hook"`** and missed `gortex.exe hook`, so it never converged on Windows
  and left duplicate bare+nudge hook entries with **deny winning** on desktop and
  g15 for two weeks. Fixed 2026-08-30 by anchoring an optional `.exe` suffix.
- **`agents/bootstrap.sh` pins `GORTEX_HOOK_MODE=nudge`** by default (2026-08-05),
  overriding gortex's own `--hook-mode deny`. Override per run with
  `GORTEX_HOOK_MODE=deny just gortex-setup`.
- **The `consult-unlock` posture never unlocks.** Ten probes on 2026-08-05: a
  source `Read` stayed denied even after a real `mcp__gortex__search` in the same
  session. That is why the fleet runs `nudge`, not a preference.
- **gortex's `PreCompact` handler returns `additionalContext`**, which Claude
  Code's hook schema allows only for UserPromptSubmit / PostToolUse /
  PostToolBatch / Stop / SubagentStop — so every compact prints a visible
  "Hook JSON output validation failed".

### Fleet plumbing

- **`fleet-selfpull.sh` escalates a persistently dirty tree** to `STALE dirty Nt`
  and a non-zero exit after `FLEET_SELFPULL_DIRTY_LIMIT` (default 36 ticks, ~6h at
  the 10-minute cadence). Non-`main` branches are deliberately excluded so a
  feature branch never escalates.
- **`fleet-selfpull.ps1` has no such guard and no test coverage**, so `desktop` —
  the one Windows-native member — can still freeze silently the way desktop-wsl
  did for ~35 hours. Roadmap P6, not fixed.
- **The three periodic-git mechanisms are NOT redundant; do not merge them.**
  `git-autofetch` fetches every repo under `$HOME` and never touches a worktree;
  `fleet-selfpull` ff-pulls the fleet repos and fires post-merge convergence;
  `dotfiles-sync` commits, pushes and merges on the bare repo. Different subject,
  different verb. (An earlier session in the same window flagged their near-
  identical ~10-minute cadence as unreviewed duplication — that reading is wrong.)
- **`agents/settings.json` hardcodes `/home/me/pure/claude-plugins`** (line 27),
  real only on desktop-wsl, and ships verbatim to every agents-role box where it
  resolves to nothing. Still true on 2026-09-11.
- **`windows.ps1`'s `core.symlinks` repair must THROW, not retry.** A retry with
  `git checkout -f` runs the identical checkout under the same `core.symlinks`
  state and can silently rewrite the 9-byte plain `CLAUDE.md` back, while logging
  a message that reads like a successful recovery. Fixed 2026-08-30.
- **Two statusboard defects, both fixed 2026-07-31**: it erased the screen as its
  own write before drawing, leaving a genuinely blank pane that tmux could flush
  downstream as a visible blink every 2–5 s (fixed with a single-write paint,
  `\033[K` before every newline); and it ignored SIGTERM, because
  `trap cleanup EXIT INT TERM` *resumes* the script after the handler returns — so
  every `systemctl stop` sat out the full 90 s timeout before SIGKILL. The fix is
  `trap 'cleanup; exit 0' INT TERM HUP`.
- **The caveman plugin's hooks shell out to a bare `node`**, which no fleet box had
  until 2026-08-02 — so they failed silently (non-blocking) on every session since
  the plugin was installed 2026-07-27. Fixed by adding `node` to `tier_brew_dev`
  and `nodejs` plus a guarded symlink to `tier_apt_dev`. **hub deliberately still
  has none**: its lean profile skips `tier_apt_dev` on a 960 MB VPS, so any plugin
  hook shelling out to `node` still fails there. Accepted tradeoff, not a bug.

### macOS — facts about `air` (its own host memory is on another branch)

- **No `timeout`, no `findmnt`** — both GNU/Linux-only. A script meant to run on
  air and the Linux members needs guarded fallbacks; for the first, ssh's own
  `-o ConnectTimeout`.
- **The built-in BWK awk rejects embedded newlines in `-v`** ("awk: newline in
  string") — pass multi-line data via a file or process substitution.
- **`/var` is a symlink to `/private/var`**, so `mktemp -d` returns
  `/var/folders/…` while a script that resolves paths reports `/private/var/…`; a
  test comparing the two spellings false-negatives on correct behaviour. (BSD
  `wc -l` padding is the same family of trap and is already recorded above.)
- **The `tailscale` CLI may not be on PATH** — fall back to
  `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.
- **ssh silently offers the default `id_ed25519`** for any host with no explicit
  `Host` block pinning `IdentityFile ~/.ssh/id_fleet`, which read as a server-side
  auth bug on desktop until diagnosed with `-o IdentitiesOnly=yes`.

### More parked facts — latitude and hub

- **⚠ latitude's restic repo backs up its own password.** `/home/me/my/vps` is a
  backup source and contains a plaintext copy of that same repo's 12-character
  password at `backup/homeserver/pass.txt`, confirmed present in the 2026-08-30
  snapshot via `restic find`. The repo lives on a removable dock drive slated for
  eventual offsite rotation.
- **⚠ hub held two live REUSABLE, unused Headscale pre-auth keys** as of
  2026-08-30 (id 5 → 2026-10-14, id 9 → 2026-11-25), neither near expiry. With
  ACLs still deferred, either key gives a joiner full fleet reach. A third was
  found untracked on disk at `provision/secrets/authkey` (created 2026-07-27),
  against the fleet's own post-rollout policy to revoke reusable keys; resolution
  was never confirmed in-session.
- **Correcting an earlier record**: latitude's own restic repo and desktop-wsl's
  REST-server repo use DIFFERENT per-client passwords (12-char vs 63-char),
  verified 2026-08-30 — not one password unlocking both.
- **latitude's system clock is UTC+5, not UTC.** A 2026-08 incident review misread
  a UTC log timestamp as local and built a 5-hour error into the fault timeline.
- **`restic/rest-server:latest` is unpinned** — measured digest `d2aff06f` (built
  2025-05-31) on 2026-08-30, so a routine `docker compose pull` would silently
  swap the image under the fleet's backup hub.
- **The NS1066 enclosure reports a hardcoded placeholder bridge serial**
  (`0123456789ABCDE`), so its `usb-*` by-id path is not enclosure-unique — address
  the drive behind it by `wwn-` or `ata-<model>_<serial>`.
- **latitude's immich compose must extend `quicksync`/`openvino` and bind
  `/dev/dri`** for the Intel iGPU — not the `nvenc`/`cuda` variants g513ie used for
  its RTX 3050 Ti. Copying a compose across GPU vendors silently targets the wrong
  hardware.
- **Container DNS is pinned in `daemon.json` to 100.100.100.100 (MagicDNS) then
  1.1.1.1**, because Tailscale rewrites `/etc/resolv.conf` just after `tailscaled`
  starts and any container started before that snapshots the dead `127.0.0.53`
  stub. That was the root cause of the 2026-08-03 fleet-wide indexer DNS outage —
  alongside, and distinct from, the mount-ordering failure from the same reboot.

## Orca on g15 never self-updates: an EXTRACTED AppImage cannot (2026-09-12)

- **Symptom:** g15 sat on 1.4.197 while air/desktop were on 1.4.200, with no
  update prompt. **Cause, from Orca's own log** (`~/.cache/orca-gui.log`):
  `[autoUpdater] APPIMAGE env is not defined, current application is not an
  AppImage`. The updater *checks* fine — the same log shows it resolving
  `…/releases/download/v1.4.198` — it just can never apply. `/proc/<pid>/environ`
  of the running process has no `APPIMAGE`, because `provision/orca-serve.sh`
  installs by `--appimage-extract` and the launcher ran
  `~/.local/opt/orca/squashfs-root/AppRun`. electron-updater's AppImage path is
  gated on `$APPIMAGE`, which only the real AppImage runtime sets.
- **This is the L2368 class on a new box with a different mechanism**: there a
  cache key never missed, here the runtime cannot install at all. Both look like
  "updates are fine" from outside.
- **Fix applied on g15:** the 1.4.200 AppImage lives at
  `~/.local/opt/orca/orca-linux.AppImage` and `~/.local/share/applications/orca-ide.desktop`
  `Exec=` points straight at it (backup `.bak-1.4.197` beside it). **The basename
  is load-bearing** — electron-updater writes the downloaded asset's own name
  (`orca-linux.AppImage`) and unlinks the old file when the current basename
  carries a version triplet and differs, so `orca-1.4.200.AppImage` would have
  self-updated and deleted the file the launcher names.
- FUSE is fine on Ubuntu 26.04 with **fuse3 only** (no libfuse2) — measured, the
  AppImage self-mounts. The `.deb` is NOT the answer: electron-updater's
  DebUpdater shells out to sudo and g15 has no NOPASSWD.
- **Closed the same day:** `orca-serve.sh` now has two shapes —
  `ORCA_INSTALL_MODE` (`auto` → `desktop` off WSL, `serve` on it), pinned by
  `orca_install_mode` / `orca_appimage_name` and 7 mutation-tested assertions.
  Desktop keeps the AppImage whole, writes the `.desktop` entry with
  `Exec=<AppImage>`, installs no CLI wrapper (Orca writes its own shim at first
  launch, and that one IS AppImage-aware — its generator reads `$APPIMAGE` /
  `$APPDIR` because a mount path changes every launch) and needs no tailnet, so
  the tailscale precondition moved under the serve branch. `ORCA_SERVE_AUTOSTART=1`
  still drags the layout back to `serve`, since the unit execs the unpacked CLI.
- Two things that only a live run finds: the version of a desktop install must be
  read **out of the AppImage** (`--appimage-extract orca-ide.desktop`, 3 ms, no
  FUSE) because the app rewrites that file when it self-updates and any sidecar
  note would go stale the first time it worked; and the AppImage root's
  `orca-ide.png` is a **symlink** into `usr/share/icons`, so extracting that name
  alone yields a dangling link — extract the real path.
- The Ubuntu "restart to finish updating" prompt is apt/unattended-upgrades and
  has nothing to do with Orca; apt's `orca` 50.2 is the GNOME screen reader.


## Оффсайт, хаб и зеркало: что измерили 2026-09-12

<!-- src: machines 3816d27 | 2026-09-12 -->

- **Хаб на latitude больше НЕ `--no-auth` и не привязан к tailnet-адресу — проверено
  живьём 2026-09-12.** `HostConfig.PortBindings` = `{"8000/tcp":[{"HostIp":"","HostPort":"8001"}]}`,
  то есть wildcard (`0.0.0.0:8001` и `[::]:8001`), а `OPTIONS` =
  `--private-repos --append-only --prometheus` с htpasswd в `/data/.htpasswd`. Так
  что «достижимость И ЕСТЬ авторизация» описывает снятую позицию, а буллет про
  «`--append-only` намеренно НЕ выставлен, он сломает `forget --prune`» неверен
  дважды: файл сам себе противоречил (`:1093` и `:2649` уже говорили, что хаб
  отдаёт `--append-only`). Ретенция при этом работает: prune крутится на latitude
  через per-client maintenance-профили (`g614jv-maintenance`, `g513ie-maintenance`),
  каждый со своим ключом локально — клиент удалить не может никогда, владелец хаба
  может всегда. Посылка, из-за которой wildcard-бинду НУЖНА аутентификация: на
  latitude нет хостового файрвола вообще (`iptables -P INPUT ACCEPT`, только прыжок
  в `ts-input`; ни ufw, ни nftables, ни firewalld), так что опубликованный
  docker-порт реально открыт каждому устройству в домашнем wifi.
  <!-- conflicts-with: "now bound to **`100.64.0.8:8001`, not `0.0.0.0`**. It runs `--no-auth`, so reachability IS authorisation" -->
  <!-- conflicts-with: "`--append-only` is deliberately NOT set: it would break `forget --prune` and turn retention into a manual chore" -->
  <!-- conflicts-with: "Costs a boot race (docker cannot bind before tailscaled is up) which `restart: unless-stopped` absorbs — check that first if the container is ever dead after a reboot." -->
  <!-- src: machines 3816d27 | 2026-09-12 -->

- **План оффсайта — больше не «возить диск из дока».** Файл дважды говорит, что
  дешёвое закрытие оффсайт-дыры — ротация одного дискового лотка, и назначает
  владельцем Task 19 миграционного плана. Владелец отверг ротацию прямо
  2026-09-11: «езжу я раз в несколько месяцев, но не хочу таскать диски каждый
  раз». Замена — всегда включённая коробка в родительском доме под Карагандой:
  один раз засеивается диском, привезённым в ближайшую поездку, дальше получает
  дельты по домашнему оптоволокну. Логическое имя `offsite`, роль
  `backup-offsite`; дизайн в
  `docs/superpowers/specs/2026-09-12-village-offsite-backup-design.md`, план в
  `docs/superpowers/plans/2026-09-12-village-offsite-backup.md`. Агент, читающий
  старый буллет, предложит ровно то, от чего уже отказались.
  <!-- conflicts-with: "remains cheap (rotate one dock's drive off-site) rather than adding cloud/object storage" -->
  <!-- src: machines 3816d27 | 2026-09-12 -->

- **Мошеннический диск 2026-07-30 ВЕРНУЛИ в магазин — его на latitude нет и не
  будет.** Раздел про приёмку подробно описывает подлог (HGST Ultrastar
  `HUS726060ALE611` под этикеткой WD Purple) и нигде не говорит, что диск уехал
  обратно, — этого достаточно, чтобы агент опознал живой диск как тот самый (в
  этой сессии так и произошло, поправил владелец). HGST на latitude — обычный
  `HGST HTS541010A9E680`, 1 ТБ Travelstar. Смежное: ни один локальный диск нельзя
  увезти в деревню, потому что все четыре 2.5″ в коробке — шпиндели на 1 ТБ и
  меньше (три крупнейших по 931.5 G) против ~950 ГБ оффсайт-полезной нагрузки.
  Ограничение — запас по ёмкости, а не физический размер: доки принимают и 2.5″,
  и 3.5″, так что «он не влезет» здесь никогда не аргумент.
  <!-- src: machines 3816d27 | 2026-09-12 -->

- **480 Мбит на зеркале — ВЫЛЕЧЕНО, и вместе с ним умер план освобождать бэй
  Ugreen.** 2026-09-10 хаб убрали, разъёмы переобжали: NS1066 теперь воткнут
  ПРЯМО в USB3-порт ноутбука без хаба, договаривается на 5000, `Cannot enable` в
  логе больше не появляется. Чтение — 80 МБ/с, то есть потолок самой 2.5″
  пластины, а не шины; полный проход `mirror-refresh` — 31 секунда. Это снимает
  два стоящих в файле утверждения: «настоящее лечение — увести зеркало с этого
  порта» и «ждать освобождения spare320 ради бэя Ugreen, возможно, не нужно
  вовсе». Скорость зеркала была ЕДИНСТВЕННОЙ причиной выселять `/mnt/spare320` из
  бэя Ugreen, так что вопрос про spare320 теперь только «когда закончится
  прижигание 8 ТБ».
  <!-- conflicts-with: "Настоящее лечение — увести" (project.md, раздел «Гейт, который рапортует успех», продолжение строки: «зеркало с этого порта») -->
  <!-- conflicts-with: "ждать освобождения `spare320` ради бэя Ugreen, возможно," (project.md, раздел «Зеркало сидит на 480 Мбит») -->
  <!-- src: machines 3816d27 | 2026-09-12 -->

- **Деградировавшая, но работающая USB-линия — самое опасное состояние, и все три
  скорости дал ОДИН неплотный разъём.** Тот же коннектор `/mnt/immich-mirror`
  выдавал 12 Мбит/с (USB 1.1 full-speed, замерено 923 КБ/с — полный проход занял
  бы около недели), потом 480, потом 5000, при неизменных диске и коробке. Обе
  первые версии были неверны: «шинный хаб не прокормит 2.5″ шпиндель» (NS1066
  заявляет 2 mA, хаб GenesysLogic — 100 mA) и «не контачат SuperSpeed-пары
  NS1066». Дело было в прижиме разъёма. Остаётся правило: rsync на деградировавшей
  линии не падает, он ПОЛЗЁТ сутками под зелёным таймером, так что медленная линия
  прячется лучше отсутствующей — смотреть `cat /sys/bus/usb/devices/*/speed`
  прежде, чем верить любой цифре пропускной способности, и держать
  `UDMA_CRC_Error_Count` (здесь 0) как признак умирающего разъёма, а не разовой
  плохой вставки.
  <!-- src: machines 3816d27 | 2026-09-12 -->

- **Запушить конфиг resticprofile — ЗНАЧИТ его задеплоить, а `initialize: true`
  превращает ранний pull в молча созданный пустой репозиторий.** `resticprofile`
  читает `backup/<identity>/profiles.yaml` прямо из рабочего дерева git, то есть
  отдельного шага деплоя нет: коммит доезжает до каждой коробки на ближайшем тике
  `fleet-selfpull`. У latitude в профиле стоит `initialize: true`, поэтому
  конфиг, называющий `/mnt/wd8`, пока данные ещё на `/mnt/spare320`, СОЗДАСТ там
  пустой репозиторий с нулевой историей и отрапортует успех. Именно поэтому
  `migrate-restic-wd8.sh` делает `git pull` сам, внутри `cutover`, после дельты и
  после `verify`, и отказывается продолжать, если в конфиге осталась хоть одна
  ссылка на старый путь.
  <!-- src: machines 3816d27 | 2026-09-12 -->

- **`restic-hub-selfcheck.sh` держит UUID хабового диска литералом, поэтому
  переезд репозитория обязан двигать и его.** Самопроверка сверяет носитель по
  UUID файловой системы, а не по пути: `DRIVE_UUID="726efd1f-7eb1-45d7-a09e-1e9467c6319f"`
  прописан в скрипте (сверяется с `findmnt -no UUID /mnt/wd8`). Когда оба
  restic-репозитория переехали с `/mnt/spare320` на `/mnt/wd8`, литерал пришлось
  править тем же изменением — иначе самопроверка кричит «не тот диск» на
  совершенно здоровой системе, и этот ложный красный неотличим от настоящего
  отказа хаба. Любой будущий переезд репозиториев несёт ту же обязанность.
  <!-- src: machines 3816d27 | 2026-09-12 -->

- **Коллектор, который остановился, — это не зелёная полоска.** Статусборд читал
  файл строк как `[ -r … ] && cat`, вообще без проверки mtime, — при том что весь
  остальной файл скрупулёзно трактует mtime файла как сигнал его живости.
  Остановленный, замаскированный или никогда не включённый таймер сборщика
  оставлял последние хорошие строки замороженными на диске, и полоса красила их
  зелёным вечно; failed-юнита при этом тоже нет, так что `SB_FAILED` сказать
  нечего. Правило: у файла, который пишет периодический сборщик, его собственный
  mtime — это пульс сборщика. Алерт при этом гейтится на **существование** файла,
  иначе каждая коробка, у которой такой работы нет, светится янтарным навсегда —
  а это и есть способ обесценить предупреждающий цвет.
  <!-- src: machines 3816d27 | 2026-09-12 -->

- **ИБП для latitude: он защищает ДОКИ и роутер, а не ноутбук.** Ноутбук — сам
  себе ИБП и держится часами, так что подключить его за ИБП значит потратить
  ~65 Вт бюджета на повторное страхование уже застрахованного и урезать время
  доков с ~1 ч до ~20 мин. Нагрузка за ИБП — ~60–70 Вт (два дока ~45, роутер ~10,
  5G-модем ~7), поэтому любой линейно-интерактивный аппарат на 600–1200 ВА
  избыточен по мощности: настоящая ось — энергия батареи, и считать надо примерно
  на треть ниже паспортных Вт·ч на глубину разряда и потери инвертора (180 Вт·ч
  паспорта ≈ 1.5–2 ч при 65 Вт). Схема: розетка → ИБП → существующий удлинитель,
  на котором уже висят ноутбук, оба дока и роутер.
  <!-- src: machines 3816d27 | 2026-09-12 -->

- **Связывающее ограничение при выборе ИБП — порт связи, а не ВА и не AVR.**
  Любой кандидат без USB/RS-232 отпадает независимо от ёмкости: без NUT
  (`usbhid-ups` на Debian) ничто не остановит контейнеры и не отмонтирует диски,
  когда батарея сядет, — и доки исчезнут посреди записи, то есть ровно та
  bind-source-гонка, ради закрытия которой ИБП и покупается. Логика обратна
  интуиции: **чем больше батарея, тем важнее порт**, потому что 25-секундное
  моргание пачку не разряжает, а двух-трёхчасовое заканчивается смертью ИБП под
  нагрузкой. Рыночные ловушки, которые это правило отсекает: у SVC суффикс `L`
  против `F` — это И ЕСТЬ порт связи (`V-1200-L-LCD` без него, `V-1200-F-LCD` —
  то же железо с USB), а вся инверторная линейка SVC DI порта не имеет вовсе, так
  что «часы автономии от внешней банки 100 А·ч» покупаются слепотой. И
  «стабилизатор» (например SVC R-1000) — не ИБП: батареи нет, умирает вместе с
  сетью, и лишь дублирует AVR, уже встроенный в любой линейно-интерактивный
  аппарат. Остановились на `SVC V-1200-F-LCD` (1200 ВА / 720 Вт, 12 В 7.5 А·ч ×2,
  AVR 165–275 В, 3× Schuko, USB); на месте проверить одно — часть поставок идёт с
  несменной батареей, что превращает трёх-четырёхлетнюю банку в мёртвую коробку
  вместо дешёвой замены.
  <!-- src: machines 3816d27 | 2026-09-12 -->

- **5G как резервный WAN делает «правильное выключение» штатным путём, а не
  редким.** Ставить его стоит: 5G — единственный класс линии, переживающий
  бытовое отключение, потому что проводной интернет умирает на ONT/терминале в
  той же розетке, а не у провайдера, тогда как базовая станция держит часы
  собственного резерва. Но требование к ИБП это УЖЕСТОЧАЕТ, а не ослабляет: когда
  сеть и сервер живут сквозь отключение, типичным концом длинного отключения
  становится «ИБП сел → доки умерли → ноутбук продолжает работать от своей
  батареи и писать в исчезнувшие диски». Низкобатарейное выключение по NUT
  превращается из редкого в штатный путь кода. Две вещи померить ДО покупки
  железа: прогнать переключение WAN руками и засечь, за сколько возвращается
  tailnet (ping-пробы дуального WAN часто думают десятки секунд и нередко не
  возвращаются обратно), и ограничить трафик qbittorrent/servarr, чтобы
  переключение не съело сотовую квоту за час.
  <!-- src: machines 3816d27 | 2026-09-12 -->

## Orca, the provisioner and the harness — measured 2026-09-12

<!-- src: machines 3816d27 | 2026-09-12 -->

### Orca's project model

- **Orca on Windows has a per-project agent runtime — Windows, or a named WSL
  distro — and desktop's `machines` is set to `desktop-wsl`**, so worktrees,
  terminals and the `claude` process all run inside the distro. That supersedes
  this file's "In Orca, the registered PATH *is* the environment — there is no
  environment / runtime / distro field" (probed 2026-07-26); the field exists now.
  And a repo cannot be registered twice, once per runtime: **Orca keys projects by
  git remote** (`github:<owner>/<repo>`) and refuses the second path with "such a
  project already exists".
  <!-- conflicts-with: "In Orca, the registered PATH *is* the environment — there is no environment / runtime / distro field" -->
  <!-- src: machines 3816d27 | 2026-09-12 -->
- **Deleting an Orca project on one host deletes every host's setup.** Measured
  2026-09-12: removing the `machines` project on desktop also dropped g15's
  registration — `orca repo list` went 7 → 6 and the `project setups` row vanished
  — on a box nobody touched. Projects are keyed by git remote while
  `projectHostSetup` rows carry a `hostId`, so one delete reaches every host.
  `orca repo add --path <path>` restores the repo but comes back with
  `hookSettings.scripts = {setup: "", archive: ""}`, so the `wt-setup` /
  `wt-teardown` wiring is lost with it. Upstream bug, not reported.
  <!-- src: machines 3816d27 | 2026-09-12 -->
- **The Orca CLI has no writer for `hookSettings`.** `orca repo` exposes `add`,
  `show`, `list`, `set-base-ref`, `search-refs` and nothing that sets them, so
  per-repo Setup/Archive hooks can only be pasted into Orca's UI or edited in
  `orca-data.json` behind an Orca-closed guard (the `/orca-repair` precedent). The
  paste-it-once step is already drifting: of 7 repos registered on g15
  (2026-09-12), 6 carried `setup: wt-setup` / `archive: wt-teardown` and one
  carried empty strings.
  <!-- src: machines 3816d27 | 2026-09-12 -->
- **There is a third class of ghost workspace `/orca-repair` does not know.**
  `orca-data.json` can hold TWO entries for the SAME path under different
  repo-ids, with the stale one's repo-id absent from `repos` — which is why Orca
  cannot clean it up itself and why that skill misses it: it only knows the two
  classes where the worktree or the environment is gone. Right-click → Remove does
  not apply either, because a live checkout sits behind the ghost rather than an
  empty path. Removing it means editing `orca-data.json` with Orca fully quit, and
  `activeWorkspaceKey` must be repointed at the surviving entry or Orca reopens
  into nothing.
  <!-- src: machines 3816d27 | 2026-09-12 -->

### Provisioning

- **`orca_skills` sits in the workstation `TIERS` list immediately after
  `agents_config` and `agent_clis`, and that is not cosmetic.** The skills CLI
  picks its install targets by looking for agent config directories, so
  `~/.claude` must already exist. Nor may the tier be *appended*: that lands it
  after `dotfiles`, which stays last for the reason its own comment gives. The
  tier is deliberately not portable — it reaches exactly the two boxes where a
  `claude` process actually runs under Orca (g15 and desktop-wsl, both on
  `workstation`), and darwin is a deliberate skip-with-a-message. **Skills follow
  the agent runtime, not the app**: flip desktop's runtime to Windows and the live
  store becomes `%USERPROFILE%` with nothing in the distro consulted — that is a
  `windows.ps1` step, not a branch in the tier.
  <!-- src: machines 3816d27 | 2026-09-12 -->
- **`npx` belongs to the `npm` package, not to `nodejs`.** On Debian/Ubuntu it is
  a separate package and `/usr/bin/npx` is registered to it (`dpkg -S`, g15
  2026-09-12), so a layer installing only `nodejs` leaves `tier_orca_skills`
  warning about a missing npx on every box that same layer has just provisioned.
  Same shape as `just`: a tier whose own prerequisite nothing that runs first
  installs. Measured separately on desktop-wsl over ssh: no node, no npx, and the
  Windows node under `/mnt/c` unreachable — **sshd does not inherit the interop
  PATH**, so no non-interactive run (converge, `/ship`, a provisioning run) sees
  any Windows path at all. The fix is a Linux node inside the distro, never a
  reach across the 9P boundary.
  <!-- src: machines 3816d27 | 2026-09-12 -->
- **`provision/lib/tiers.sh` has a call contract, and `orca-serve.sh` does not
  satisfy it.** The header declares the globals every tier body needs — `REPO
  SUDO PRIV WARNINGS APT_UPDATED` — plus the driver helpers `info/ok/warn/die/have`;
  `TIERS_LIB_ONLY=1 source` loads the file with no side effects, which is what the
  suites rely on. `provision/orca-serve.sh` sets `SUDO` alone and its own `warn()`
  never touches `WARNINGS`, so under `set -u` the first warning inside any tier
  body kills the script. Calling a tier from there looks like a one-line change
  and wires in an abort; the globals init has to come with it.
  <!-- src: machines 3816d27 | 2026-09-12 -->
- **`just test` on the Windows checkout fails at `cygpath`, not on an empty suite
  list.** It exits 1 with `could not find ``cygpath`` executable to translate
  recipe ``test`` shebang interpreter path`: every recipe body is a
  `#!/usr/bin/env bash` shebang recipe, and `just` needs `cygpath` from Git for
  Windows' `usr\bin`, which is not on PATH there. So the gate is one PATH entry
  away from *starting* on Windows — what stays unmeasured is whether bash suites
  written for Linux paths would then pass under Git Bash. WSL runs them natively,
  which is the whole argument for keeping development there.
  <!-- src: machines 3816d27 | 2026-09-12 -->
- **`wsl -d <distro>` through a Windows parent has a small argument ceiling.**
  `ssh desktop.gg.ez "wsl -d desktop-wsl -- bash -lc '<base64 payload>'"` fails
  with "Argument list too long" when a whole file is inlined. Route the payload as
  a file instead — `scp -P 2222 <file> desktop-wsl.gg.ez:/tmp/…` then
  `ssh -p 2222 desktop-wsl.gg.ez`, the direct path, which has no such limit.
  <!-- src: machines 3816d27 | 2026-09-12 -->

### The harness and the memory machinery

- **The cyphy skills are live from the MAIN checkout's working tree.**
  `~/.claude/skills/cyphy` is a whole-directory symlink to
  `~/machines/agents/plugin`, so the live text of every cyphy skill is whatever
  the main checkout currently has checked out. Editing a skill on a branch or in a
  worktree changes nothing: while `~/machines` sat on `offsite-backup`,
  `/memory-review` kept running the pre-fix rules even though the fix was merged —
  silently, with no version anywhere to compare. The useful converse: once the
  change is merged and the checkout is back on `main`, the new skill text is live
  immediately, with no bootstrap or install step.
  <!-- src: machines 3816d27 | 2026-09-12 -->
- **`just test` gives zero signal on a skill edit.** No suite in the gate reads
  the markdown under `agents/plugin/skills/`, measured while rewriting three
  SKILL files: the gate ran green and said nothing about any of them. A green
  `just test` after a skill-text change is not evidence; the evidence has to be
  the measurement itself.
  <!-- src: machines 3816d27 | 2026-09-12 -->
- **Memory-store drift is merge-base, not size.** A machine branch's copy of a
  SHARED store can be *smaller* than main's and still be the only copy of real
  content: measured 2026-09-11, `desktop-wsl`'s `personality/practices.md` was
  735 B smaller than main's while holding 126 lines that exist on no other box.
  `consolidate-phase.md` states the opposite as a rule, so a run following the
  brief discards exactly the memory the pass exists to find. Compare per path by
  merge-base or blob hash against `origin/main`, never by file size.
  <!-- conflicts-with: "A branch *smaller* than main's is just lagging its next sync tick; that is not a finding" -->
  <!-- src: machines 3816d27 | 2026-09-12 -->
- **Phase B's invariant check blames a concurrent session's writes on itself.** It
  attributes ANY mid-run change in `~/machines` to the run doing the checking, so
  a second agent editing the repo produces a wrong diagnosis rather than a
  collision warning. On 2026-09-11 three agent sessions were writing `~/machines`
  at once with none aware of the others, and that is what tripped it. Before
  concluding a harvest run corrupted its own tree, check for other live sessions
  on the box.
  <!-- src: machines 3816d27 | 2026-09-12 -->
- **Widening a stable-hash id from three fields to four must not append a
  separator for the absent field.** `"a\037b\037c\037"` is a different string
  from `"a\037b\037c"`, so a bare `${4:-}` silently rehashes every id already
  written into the queue and the ledger (measured 2026-09-12: `857b229a` became
  `91bb8eda`). Branch on emptiness instead, which reproduces the old hash byte for
  byte. General form: a content-addressed id's schema migration has to be verified
  against values *already recorded*, never only against new ones.
  <!-- src: machines 3816d27 | 2026-09-12 -->
- **Do not put a vector index over the curated memory corpus.** It is ~570 KB
  across ~10 stores with ~74 `##` headings — small enough to enumerate, and
  enumerable things do not need semantic search. Worse, vector search returns one
  plausible neighbour and stays silent about the rest, which is precisely the
  failure to avoid here: a duplicated section was found only because the headings
  of both stores were listed in full, and an embedding query would have returned
  one and hidden the other. Where embeddings do belong is over the raw transcripts
  — hundreds of sessions, no headings, not enumerable.
  <!-- src: machines 3816d27 | 2026-09-12 -->
