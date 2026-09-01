# Backup relocation — move the restic system from `vps` into `machines`

> **Supersedes `docs/superpowers/plans/2026-07-05-machines-fleet-layout-B-backup.md`**,
> which was never executed and whose every path is now dead: it names `~/gh/vps`,
> `g16-wsl`, `rest:http://server.lan:8001/wsl`, and treats `homeserver/` as a live
> Windows Immich host. All four are gone. Read this file, not that one.

**Goal:** `machines` owns machine backup, in fact and not only in its README.
`vps/backup/` moves to `machines/backup/` with machine-named profile dirs, and the
two roles `fleet.json` already declares — `backup-hub`, `backup-client` — stop being
names with no executor behind them.

**Why now:** `vps` is the services repo for cyphy.kz, and its `backup/` subtree
carries profiles for **latitude**, the retired Windows Immich host, and
**desktop-wsl** — not one of them is the VPS. The VPS itself (`hub`) carries the
`backup-client` role in `fleet.json` and has no profile anywhere.

---

## Current state (probed 2026-08-29, not assumed)

| Where | What | Status |
|---|---|---|
| `vps/backup/base.yaml` | shared `base-job`, `initialize` opt-in, no global init | live, inherited by all |
| `vps/backup/latitude/profiles.yaml` | profiles `latitude` + `g614jv-maintenance` | **live**, 4 root-scope timers on latitude |
| `vps/backup/wsl/profiles.yaml` | profile `wsl` → REST hub | **live**, user timer on desktop-wsl, 06:00 |
| `vps/backup/homeserver/profiles.yaml` | 3 profiles targeting `G:\`, `H:\`, `D:\`, `E:\` | **dead** — those drives were reformatted during the migration |
| `vps/backup/homeserver/pass.txt` | latitude's restic password | **live and load-bearing** (see Invariant 3) |
| `machines/provision/roles/backup-{hub,client}.sh` | — | **do not exist**; `provision.sh` degrades to a printed plan |
| `fleet.json` | `backup-hub` + `backup-client` on latitude, `backup-client` on hub | desktop is **not** declared, yet runs a client |

Latitude's live timers, for the "did I break it" check later:

```
resticprofile-backup@profile-latitude              04:30 daily
resticprofile-check@profile-latitude               Sun 06:00
resticprofile-forget@profile-g614jv-maintenance    07:30 daily
resticprofile-check@profile-g614jv-maintenance     Sun 08:30
```

---

## Invariants — a step that changes one of these is a bug, not a refactor

1. **Repository URLs/paths and profile names are frozen.** They name stateful
   backends and installed unit names (`resticprofile-backup@profile-<name>`).
   Renaming `wsl` orphans its snapshots *and* leaves a stray timer behind.
   Directory names change; nothing inside does.
2. **`initialize` stays opt-in and must never move to `global:`.** resticprofile
   0.33.1 lets a profile's `true` override a global `false` but **not** the
   reverse, so a global `true` can never be switched off again. That asymmetry is
   what silently defeated the `wsl` guard once already. `base.yaml` says so at
   length — carry the comment across verbatim.
3. **`backup/homeserver/pass.txt` is latitude's live password**, referenced by
   absolute path from a root-scope unit:
   `password-file: /home/me/my/vps/backup/homeserver/pass.txt`, which on latitude
   is a symlink to `~/g513ie-prod-config/vps/backup/homeserver/pass.txt`
   (dotfiles-tracked). The directory is named after a machine that no longer
   exists; the file is not optional. Moving it is a step with its own
   verification, never a `cp`.
4. **`check-before` belongs under `backup:`, not beside it.** At profile level
   resticprofile parses it, echoes it back from `show`, and never runs it — four
   scheduled runs issued zero `restic check`. Do not "tidy" it upward.
5. **Never delete from `vps` before the `machines` copy is committed and the
   installers have been re-run and verified on both hosts.**

## Out of scope, deliberately

**No monitoring, no alerting, no statusboard page.** Roadmap P0 defers that by
explicit decision ("we shouldn't focus on backups that much… let's defer proper
backups and monitoring to future"), and the design that was worked out is recorded
there. This plan moves code and writes two executors. It does not close that gap,
and the gap is not an oversight.

---

## Task 1 — land the tree in `machines/backup/`

**Files:** create `machines/backup/{base.yaml,restic-install.sh,restic-install.bat}`,
`machines/backup/latitude/`, `machines/backup/desktop-wsl/` (was `wsl/`),
`machines/backup/_retired-homeserver/`; modify `machines/.gitignore`.

- [x] **1.1** Copy the subtree byte-for-byte, then rename the dirs:

```bash
cd ~/machines
cp -r ~/my/vps/backup ./backup
git add -A backup && git mv backup/wsl backup/desktop-wsl
git mv backup/homeserver backup/_retired-homeserver
```

**Do 1.4 first** — as originally ordered, `git add -A` ran before the
`**/pass.txt` glob existed and would have staged the secret. Use plain `mv`, not
`git mv`: nothing is committed yet, so `git mv` only adds a "source not tracked"
failure mode.

Two files are deliberately left behind, so the copy is not literally byte-for-byte:
`wsl/resticprofile-wsl.backup.log` (runtime output) and `wsl/pass.txt` (see 6.6 —
unreferenced, and *not* the live password).

- [x] **1.2** Prove the content is identical; only directory names may differ:

```bash
diff    ~/my/vps/backup/base.yaml       backup/base.yaml
diff -r ~/my/vps/backup/latitude        backup/latitude
diff -r -x '*.log' -x pass.txt \
        ~/my/vps/backup/wsl             backup/desktop-wsl
diff -r ~/my/vps/backup/homeserver      backup/_retired-homeserver
```

Every diff empty. This is the frozen-URL guarantee, verified rather than asserted.
The two `-x` exclusions are named up front on purpose: a gate you have to explain
away each time stops catching the diff that matters.

- [x] **1.3** Confirm the frozen strings survived. Profile-name lists must be
      identical between old and new, and no repository line may have moved:

```bash
grep -hE '^[a-z0-9-]+:$' ~/my/vps/backup/*/profiles.yaml | sort > /tmp/names.old
grep -hE '^[a-z0-9-]+:$' backup/*/profiles.yaml           | sort > /tmp/names.new
diff /tmp/names.old /tmp/names.new    # must be empty
git grep -n 'repository:' backup/
```

- [x] **1.4** Carry the secret gitignore globs and prove they bite:

```bash
grep -q 'pass.txt' .gitignore || printf '\n# restic backup secrets\n**/pass.txt\n**/.env\n' >> .gitignore
git check-ignore -v backup/_retired-homeserver/pass.txt   # must print a rule
git status --porcelain backup/ | grep -i 'pass.txt' && echo "STOP — secret staged"
```

- [x] **1.5** Commit the `machines` side. Nothing on any host has changed yet.

## Task 2 — repoint latitude, the risky one

Latitude reads its password by **absolute path** from a root-scope unit, and its
profile also carries the `g614jv-maintenance` prune/check for desktop-wsl's repo.
Both break silently if the path is wrong — `run-before` asserts the *repo*, not
the password.

- [x] **2.1** Move the password to a name that says what it is, keeping the
      dotfiles-tracked file as the single byte-source. On latitude:

```bash
mkdir -p ~/machines/backup/latitude
ln -s ~/g513ie-prod-config/vps/backup/homeserver/pass.txt \
      ~/machines/backup/latitude/pass.txt
readlink -f ~/machines/backup/latitude/pass.txt   # must resolve to the tracked file
cmp ~/machines/backup/latitude/pass.txt ~/my/vps/backup/homeserver/pass.txt
```

Rename the tracked path under `~/g513ie-prod-config/` **later or never** — it is a
dotfiles change on latitude's branch and is not worth coupling to this move.

- [x] **2.2** Update both `password-file:` and `env.RESTIC_PASSWORD_FILE` in
      `backup/latitude/profiles.yaml` to the new absolute path. Both, not one —
      the file already warns that leaving a stale env var set is how someone later
      fixes the wrong thing.

- [x] **2.3** Reinstall latitude's schedules from the new directory:

```bash
cd ~/machines/backup/latitude
sudo resticprofile schedule --all            # ONE invocation; see below
systemctl list-timers --all | grep -c resticprofile   # exactly 4
grep -H -E 'WorkingDirectory|RESTIC_PASSWORD_FILE' /etc/systemd/system/resticprofile-*.service
```

Three things this step turned out to depend on:

- **`schedule --all` ignores `-n` and schedules every profile in the config**, so
  the two `-n` invocations the plan first carried were the same command run twice.
- **`sudo` is required** — these are root-owned units in `/etc/systemd/system`,
  installed with `HOME=/root` and `SUDO_USER=me` baked in.
- **The unit bakes `Environment="RESTIC_PASSWORD_FILE=…"` at install time.**
  Editing `profiles.yaml` therefore changes nothing until the schedule is
  reinstalled — and it is why 2.2 had to move *both* keys: the env var is not a
  fallback, it is copied verbatim into the unit.

The duplicate-timer hazard does not materialise here: unit names derive from the
profile name (`resticprofile-backup@profile-latitude`), not the directory, so
reinstalling overwrites the same eight files. It would bite if a profile were ever
renamed — which is why Invariant 1 freezes the names. Verify the count anyway.

- [x] **2.4** **Verify by firing the schedule, not the script.** This repo has
      been burned by exactly this: `mirror-refresh.sh -go` passed by hand for weeks
      while every timer run reported `Failed`.

```bash
sudo systemctl start resticprofile-backup@profile-latitude.service
systemctl show -p Result resticprofile-backup@profile-latitude.service   # Result=success
sudo systemctl start resticprofile-forget@profile-g614jv-maintenance.service
systemctl show -p Result resticprofile-forget@profile-g614jv-maintenance.service
sudo restic -r /mnt/spare320/restic/latitude \
  --password-file /home/me/machines/backup/latitude/pass.txt snapshots --latest 3
```

A `repository does not exist` here means the spare320 drive is absent — that is the
mount guard working, not a reason to touch `initialize`.

**Verified 2026-08-29** — all four reinstalled units exercised, not just the two
this step first named:

- `backup@latitude` and `forget@g614jv-maintenance` and `check@latitude` all
  `Result=success`; snapshot `2d7cc63e` written at 15:47.
- All four timers present under the unchanged names, every `WorkingDirectory` now
  `/home/me/machines/backup/latitude`, no unit left referencing `~/my/vps`.
- **Invariant 4 proved live, not by indentation.** The backup log shows
  `restic check --read-data-subset=5% --password-file=/home/me/machines/backup/latitude/pass.txt`
  actually issued, ending `no errors were found`. Reading the YAML cannot
  distinguish a working `check-before` from an inert one — that is the whole trap —
  so grep the log, never the config.
- **`schedule-log` in `base.yaml` is a RELATIVE path**, so the run logs now land
  inside the repo at `backup/latitude/{resticprofile-latitude.backup,latitude.check}.log`.
  The `backup/**/*.log` glob added in 1.4 already covers them and
  `git status --short backup/` is clean. Do not "fix" this by making the path
  absolute without checking what else reads it.
- `check@g614jv-maintenance` is the one unit not hand-fired; it runs Sun 08:30 and
  its sibling `forget` on the same repo and password already passed.

## Task 3 — repoint desktop-wsl's client

Its unit carries `WorkingDirectory=/home/me/my/vps/backup/wsl`, so the tree cannot
move out from under it without a reinstall.

- [x] **3.1** On desktop-wsl, from `~/machines/backup/desktop-wsl`:
      `bash install-tasks.sh` (it is `cd "$(dirname "$0")"` + `resticprofile schedule --all`).
- [x] **3.2** Confirm the unit now points at the new dir and that linger is still on
      — without linger the user timer stops firing silently:

```bash
systemctl --user cat resticprofile-backup@profile-wsl.service | grep WorkingDirectory
loginctl show-user "$USER" | grep Linger      # Linger=yes
systemctl --user start resticprofile-backup@profile-wsl.service
systemctl --user show -p Result resticprofile-backup@profile-wsl.service
```

- [x] **3.3** Confirm from **latitude**, not from the client — the box that failed
      cannot hide the failure. Newest snapshot mtime under the hub repo:

```bash
ssh latitude 'sudo ls -lt /mnt/spare320/restic-rest/g614jv/snapshots | head -3'
```

**Verified 2026-08-29:** `WorkingDirectory=/home/me/machines/backup/desktop-wsl`,
`Linger=yes`, exactly one user timer, no user unit left referencing `~/my/vps`,
`Result=success`, and snapshot `5f8d263c` visible from latitude at 18:39.

### This step uncovered a live incident that had nothing to do with the move

The first hand-fire returned **401 Unauthorized**, and so did a bare `restic
snapshots` with the unchanged absolute env paths — which is what proved the move
innocent before anything was changed back. The old log dated it: last good backup
**2026-08-27 10:15**, then 401 on 08-28 and 08-29. **desktop-wsl had not been
backed up for two days and nothing said so.**

Cause: `restic-server` started at 2026-08-27 13:11 while `/mnt/spare320` was not
mounted. `${RESTIC_DATA_PATH}:/data` therefore bound the *underlying* directory of
the mountpoint, rest-server created an empty `.htpasswd` there, and when the drive
came back the container stayed pinned to the shadowed directory. Every client got
401 against a server that looked healthy. This is the third appearance of the
empty-bind-mount hazard on latitude — the same one `profiles.yaml` warns about for
`initialize`, and the same one behind the 2026-08-23 USB-drop incident.

- **Fix:** `docker compose up -d --force-recreate` from
  `~/my/vps/homeserver/restic-server`. Not `docker restart`, which reuses the
  existing mount configuration.
- **The discriminator is one line**, and it is not a successful backup:
  `docker exec restic-server ls -la /data` must show the 68-byte `.htpasswd` and
  the `g614jv/` directory. Broken, it showed a 0-byte `.htpasswd` stamped with the
  container's own start time.
- **Leave the shadowed directory alone.** It holds only that 0-byte file, and
  unmounting a live `/mnt/spare320` to clean it would take down the repo that
  `backup@latitude` and `forget@g614jv-maintenance` both use.
- **`selfcheck.sh` caught this and ran from nothing** — it failed `newest
  snapshot age: 56h > 26h` while its other eight checks passed, because they
  inspect the host filesystem and the container's flags, not whether the two are
  the same directory. **Now scheduled, by his explicit decision** (see Task 3b).

## Task 3b — put the hub selfcheck on a timer (added mid-plan, on request)

Not in the original plan: the incident above made the case, and he asked for it
directly. Done 2026-08-29.

- [x] **3b.1** Move `vps/homeserver/restic-server/selfcheck.sh` to
      `machines/hosts/latitude/debian/restic-hub-selfcheck.sh`. The REST *server*
      stays in `vps` because it is a service; verifying that latitude's backup hub
      works is machine-backup work. It also lands with latitude's other ops
      scripts and reuses `install-timers.sh` — one mechanism for this box's system
      timers, same copy-not-symlink review boundary. Deleted from `vps` rather
      than copied: two copies drift, and a pointer in `compose.yml` says where it
      went and how to recover the failure it detects.
- [x] **3b.2** Add **check 3, the real empty-bind-mount guard.** Check 2 claimed
      to be it while reading the HOST path, where the mount always looks fine —
      which is exactly how eight checks stayed green through a two-day outage.
      Check 3 compares the `.htpasswd` **inode** the container sees against the
      host's: size only says "a file of the same length", inode says "the same
      file". Positive control run with a bogus container name: it fails.
- [x] **3b.3** `restic-hub-selfcheck.{service,timer}` — `OnBootSec=15min`
      (every failure so far was a bind race at container start), `OnCalendar=09:00`
      after the client's 06:00 run, `Persistent=true`. Wire into `install-timers.sh`:
      `UNITS`, `TIMERS` **and** the executable pre-flight loop — missing the last
      one enables a timer that fails every fire.
- [x] **3b.4** Verified by the timer firing itself, not by running the script:
      `Result=success`, all ten checks `ok`, next trigger 09:03, `systemctl
      --failed` empty.

**Notification is a failed systemd unit and nothing more**, which `just health`
already reports. Alerting proper stays deferred (roadmap P0).

**Known false positive, left in place deliberately.** Check 8 reads snapshot
freshness, which is really a *client* liveness check: desktop-wsl is a laptop, and
a weekend off fails it with nothing wrong on the hub. Check 3 is the one that
fires only on real hub breakage. The 26h threshold is left exactly as found — see
it misfire before changing it.

## Task 4 — write the two role executors  ✅ done 2026-09-01

Convention: `provision/roles/<role>.sh` is **sourced** by `provision.sh` and defines
`role_<role with - as _>`, taking `(mode, platform, machine)` and honouring
`dry-run`. Copy the shape from `roles/repos.sh`.

**Two deviations from this plan as written — both because the tree that landed in
Task 1 contradicted it:**

1. **`backup-hub` schedules nothing.** 4.2 said it "installs latitude's own
   schedules". It cannot: one `backup/latitude/profiles.yaml` holds *both* the
   `latitude` and `g614jv-maintenance` profiles, and `schedule --all` installs
   both from one place. Giving hub a second scheduler makes two roles race to
   write the same four unit files. So `backup-client` owns all scheduling and
   `backup-hub` is purely **verification** — it runs
   `hosts/latitude/debian/restic-hub-selfcheck.sh`, the one implementation of
   "is the hub healthy", rather than growing a second that drifts from it.
   It also installs no server: the REST container is a `vps` service (machines
   here, services there), and it never creates a repository.
2. **`backup/latitude/install-tasks.sh` had to be written.** 4.1 keyed the skip on
   the *directory* but the action on a *script*, and latitude shipped the dir with
   no script. The script is where the scope decision belongs: latitude's profiles
   are `schedule-permission: system` and need `sudo`; desktop-wsl's client is
   user-scope and must **not** be root, or the units land in the system manager
   and the timer that actually backs the box up is never installed. That is not
   derivable from the role executor, so each profile dir declares it.

- [x] **4.1** `provision/roles/backup-client.sh` → `role_backup_client`.
      Installs restic + resticprofile if absent (apt path only — on darwin/nixos it
      stops rather than guessing), then runs `backup/<machine>/install-tasks.sh`.
      Missing dir → `no profile dir for <machine> (skipped)`, returns 0. Dir present
      but no script → returns 1: that is a misconfiguration, not an absence.
      Platform `windows` reaches the fallthrough — see Task 5, which is blocked.
- [x] **4.2** `provision/roles/backup-hub.sh` → `role_backup_hub`. Debian arm runs
      the selfcheck on apply; every other platform hits the skip arm **on purpose**
      (a USB drive by UUID, a container and a port on one box do not generalise).
      Dry-run asserts nothing, so the suite is green off-latitude.
- [x] **4.3** `provision/tests/roles.test.sh` extended. Three things it now does
      that it did not:
      - **Sources `roles/*.sh` by glob, not a hardcoded three-file list.** The old
        list was a false-green generator: a forgotten role leaves its function
        undefined, `role_backup_client …` emits "command not found" into `2>&1`,
        that does not match the skip pattern, and `not_skipped` **passes**. A
        `defined` helper now turns a missing function into a failure.
      - **Tripwire for the dry run.** `resticprofile schedule` writes systemd units
        and has no dry-run of its own, so the preview can only print the command.
        Shims for `resticprofile`/`sudo`/`systemctl` record being executed; the
        test asserts the marker is absent. Reading the output proves the message,
        only the tripwire proves the silence.
      - **Pins both skip arms as decisions** — `windows` for the client (a known
        hole, so Task 5 must edit this line deliberately), `darwin` for the hub.
- [x] **4.4** `provision/provision.sh`: `backup-hub` and `backup-client` **deleted
      from `PLANNED_ROLES`** — implementing a role means deleting its name, and
      leaving it in means the executor is never demanded. That half is pinned in
      `provision/tests/fleet-profile.test.sh`, whose old assertions ("declared, not
      silently skipped") were inverted to "reaches a real executor, not the
      declaration". `ssh-server` now carries the declared-stub branch.
- [x] **4.6** **A defect found by verifying on latitude, not by testing here.**
      `role_backup_hub apply debian latitude`, run as `me`, reported 2 FAIL / 8 ok
      — "repo config present: MISSING" and "newest snapshot: none found". The hub
      was fine: `/mnt/spare320/restic-rest/g614jv` is `drwx------ root:root`, so
      those two checks were hitting EACCES and printing it as absence. As root, 10
      ok in the same second. Two fixes: `restic-hub-selfcheck.sh` now refuses to
      run as non-root with **exit 2** (distinct from the 1 a real failure gives, so
      "could not check" is never "check failed"), and `role_backup_hub` runs it
      under `sudo` when it is not already root. Pinned in `roles.test.sh`, skipped
      when the suite itself runs as root. Same defect class as the check-2 comment
      the script already carries a correction for.

- [x] **4.5** Suite re-measured this session, on desktop-wsl, with the same `find`
      `just _test-suites` uses. **46 suites, 44 pass, the same 2 environmental
      failures and no others** — `expansion-multibyte.test.sh` (its bash-behaviour
      self-test; the repo scan passes) and `fleet-ssh-config-ps.test.sh`
      (`UnauthorizedAccess` from `powershell.exe` under WSL). Both re-run
      individually first, so the baseline is from this session rather than
      inherited. **The "37 suites" written in this plan earlier was wrong** — which
      is exactly why AGENTS.md says not to write the count down.

## Task 5 — make `fleet.json` describe reality  ⛔ BLOCKED — needs a decision

**5.1 as written would install a green lie, and Task 4 is what proved it.**

`desktop` is `platform: windows`. Its backup client does not run on Windows — it
runs inside the WSL distro `desktop-wsl`, which is a *self-declared* host with no
`fleet.json` entry, and `provision/linux.sh` (the tier driver that provisions such
a host) **dispatches no roles at all**. So adding `backup-client` to `desktop`
gives:

```
role_backup_client apply windows desktop  →  "no posix executor for platform 'windows'" → exit 0
```

…for ever, on the one client with a live verified snapshot. That is precisely the
*provisioned nothing, reported success* failure `PLANNED_ROLES` exists to kill,
wearing a different hat — and worse than the current state, where `desktop`
simply does not claim the role.

`hub`'s skip is the honest version of the same shape: it genuinely has no client,
and `role_backup_client` says so by name on every run.

Two ways out, and it is a real choice, not a detail:

- **(a) Leave `desktop` out of the manifest.** The WSL client stays a
  `just provision-wsl` / tier concern, provisioned by the chain that already owns
  self-declared hosts. Cheapest, and honest. Cost: `fleet.json` still does not
  describe who is backed up, which is what Task 5 set out to fix.
- **(b) Teach the windows arm to dispatch into the distro.** The primitive exists
  — `agents/plugin/skills/lib/fleet-dispatch.sh` already reaches a parent's distros
  (`fd_wsl_hosts`) and runs commands in them. Cost: a `.ps1` side, and
  `fd_wsl_hosts` is still on ssh, which AGENTS.md records would unmask
  `self_alias()`'s `self: unknown` bug for self-declared hosts.

- [ ] **5.1** DECIDE (a) or (b). Do not write a `.ps1` that cannot work.
- [x] **5.2** Leave `hub`'s `backup-client` declared and unconfigured. Task 4.1
      makes that print `no profile dir for hub (skipped)` and return 0 — pinned in
      `roles.test.sh`. Giving hub a real profile is the offsite copy, its own piece
      of work needing capacity that does not exist yet (roadmap P0, deferred).
- [ ] **5.3** `fleet.json` is a `_touches_driver` trigger in `scripts/converge.sh`,
      so this edit reprovisions every box on the next tick. Land it with the
      executors, never before them.

## Task 6 — remove `backup/` from `vps`

Only after Tasks 2 and 3 have both been verified green on their hosts.

- [ ] **6.1** `cd ~/my/vps && git rm -r backup`
- [ ] **6.2** Replace the `## Backups` section in `vps/CLAUDE.md` and `README.md`
      with a pointer to `machines/backup/`, keeping the note that this repo still
      runs the restic REST **server** (`homeserver/restic-server/`) as a service.
- [ ] **6.3** `git grep -nE 'backup/(base\.yaml|latitude|wsl|homeserver)' -- '*.md'`
      → empty.
- [ ] **6.4** `git status --short homeserver/restic-server/` → unchanged.
- [ ] **6.5** The copy on **latitude** is a backup *source*
      (`/home/me/my/vps` is in the `latitude` profile's `source:` list, for the
      seven gitignored `.env` files). Pull the deletion there and confirm the next
      04:30 run still succeeds — the source path still exists, only `backup/` left it.
- [ ] **6.6** **Escrow `~/my/vps/backup/wsl/pass.txt` first, then** delete `~/my/vps`
      on **desktop-wsl** — the last personal-project directory still there;
      everything else moved to g15 on 2026-08-29.

      That file is **not** a redundant copy of the live password, which is what a
      quick look suggests. Measured 2026-08-29: 12 bytes, mtime 2026-04-27, versus
      the live `/home/me/.config/restic/pass.txt` at 64 bytes, mtime 2026-08-04 —
      they differ at byte 1. It predates the 2026-08-01 repoint, so it is the key
      to the pre-migration `rest://server.gg.ez:8001/wsl` repo whose drives were
      reformatted. Almost certainly it unlocks nothing. **`git log` in `vps` shows
      it was never tracked and it is in no dotfiles branch, so this is its last
      copy** — decide deliberately (escrow on the desktop-wsl branch, or confirm
      it is dead), never as a side effect of `rm -rf`.

## Task 7 — fix the two documentation claims that sent this work to the wrong repo

- [ ] **7.1** `machines/AGENTS.md` says in one paragraph that `machines` owns
      "provisioning **and data backup**" and that `vps` owns "the restic profiles".
      Both cannot be true. Keep the first, drop the second, and say what `vps` does
      keep: the REST **server** as a service.
- [ ] **7.2** `machines/AGENTS.md` and `docs/fleet-roadmap.md:329` both claim the
      `base`, `ssh-server` and `backup-client` executors are "unimplemented stubs
      that print not yet implemented (skipped)". **None of those files exist.** The
      printed-plan behaviour comes from `provision.sh`'s absent-function path. Say
      that instead, and mark `backup-{hub,client}` done once Task 4 lands.

---

## Final verification

- [ ] `machines/backup/` is `diff`-identical to the pre-move `vps/backup/`, dir
      names excepted; profile names and repository URLs byte-for-byte unchanged.
- [ ] No `pass.txt` and no `.env` is tracked in `machines`; `git check-ignore` proves it.
- [ ] Latitude: four restic timers present under the same unit names, and both
      hand-fired units report `Result=success`.
- [ ] desktop-wsl: `WorkingDirectory` points into `machines/`, `Linger=yes`, a new
      snapshot visible **from latitude**.
- [ ] `just provision --machine latitude --dry-run` runs both new roles and mutates
      nothing; `just test` green.
- [ ] `vps` has no `backup/`, its docs point at `machines`, `restic-server` untouched.

## Rollback

Nothing here is destructive until Task 6. Through Task 5 the old tree is still in
`vps` and the only host-side change is which directory a unit points at — reinstall
from `~/my/vps/backup/<dir>` and the previous state is back. After Task 6, recovery
is a `git revert` in `vps` plus the same reinstall. **No restic repository is
created, moved, renamed or deleted at any point in this plan** — that is the
property that makes it safe to run.
