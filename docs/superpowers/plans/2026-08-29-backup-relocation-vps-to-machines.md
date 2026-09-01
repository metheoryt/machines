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
- [x] **4.7** Both apply arms verified live on latitude, not just dry-run.
      `role_backup_hub apply` → 10/10 ok, rc=0 (as `me`, through the new sudo
      wrapper). `role_backup_client apply` → rc=0, and **Invariant 1 re-checked
      after it**: exactly 4 timers, unit names unchanged
      (`resticprofile-{backup,check}@profile-latitude`,
      `resticprofile-{forget,check}@profile-g614jv-maintenance`), every
      `WorkingDirectory=/home/me/machines/backup/latitude`.

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

## Task 5 (rewritten 2026-09-01) — every box backs itself up, Windows and WSL alike

**The original Task 5 asked the wrong question.** It tried to make one
`fleet.json` entry stand for a backup running on a different machine. The answer
is not to dispatch across the boundary — it is that **Windows and each WSL distro
on it are separate boxes with separate things to lose, so each gets its own
client.** Requested explicitly, 2026-09-01.

### The one idea

**The profile dir is keyed on WHO THE BOX IS, not on which `fleet.json` entry
owns the hardware.** `backup/<identity>/`, where identity is:

- a `fleet.json` machine name — `latitude`, `desktop`, `g15`
- a `fleet.local.json` nickname — `desktop-wsl`, `g15-wsl`

One flat namespace; the names are already unique. Each box then provisions its
own backup from the chain that already provisions it, so **nothing has to reach
across a machine boundary** — no `fd_wsl_hosts`, no `.ps1` driving `wsl.exe`, and
none of the `self_alias()` breakage option (b) would have unmasked.

### THE TRAP, and it must be closed before anything else

**`fleet_detect` returns the WRONG machine on a WSL box, differently wrong on
each one.** On desktop-wsl, `hostname` is `g614jv` — which is `desktop`'s
`detect.hostname` — so detection returns **`desktop`**, and the WSL client would
schedule *Windows'* profile. On g15-wsl the OS hostname is not `g513ie`, so
detection returns **nothing**. Same code, two different wrong answers.

So the resolver is: **`fleet.local.json`'s nickname wins outright — if it exists,
`fleet_detect` is never consulted.** This is AGENTS.md's documented
`{{ .Hostname }}`-expands-to-the-Windows-hostname trap wearing a different hat.

### Steps

- [x] **5.1** `provision/backup-client.sh` — the one implementation. Takes an
      optional identity; resolves it as above when not given. Runs
      `backup/<id>/install-tasks.sh`; missing dir is a named skip, exit 0.
      `role_backup_client` becomes a wrapper passing an explicit id — which is
      what keeps it testable off-host and keeps `roles.test.sh`'s tripwire honest.
- [x] **5.2** Add it as **step 6 of the WSL chain** in `provision_wsl_steps`. It
      takes no args on the self-resolving path, so it falls through the dispatch
      `case`'s `*)` arm. **Pinned in three places** in
      `provision/tests/provision-wsl.test.sh` (both step-list assertions and the
      existence loop) — all three must move together.
- [x] **5.3** `provision/roles/backup-client.ps1` → `Invoke-RoleBackupClient`,
      **plus its `$RoleExecutors` map entry in `provision.ps1`** — without the
      entry the role prints "not yet implemented (skipped)" and exits 0.
      Per-dir contract is `install-tasks.ps1`, for the same reason latitude and
      desktop-wsl ship different `.sh` files: Windows scheduling writes Task
      Scheduler entries and wants elevation, and that decision belongs next to
      the config, not in the executor.
- [x] **5.4** **NO new profile dirs shipped — the deliberate non-action.** The ask was the capability. Deciding
      what is irreplaceable on a box nobody has inventoried is real work —
      `backup/latitude/profiles.yaml`'s header is a long argument for how much.
      `desktop` and `g15` are **still absent** from `fleet.json`'s backup roles,
      by decision — they gain the role when they gain a profile dir, not before.
      Checked off as "decided and left alone", not as "shipped".
- [ ] **5.5** The Windows apply arm is **UNVERIFIED** until it runs on `desktop`
      or `g15`. The retired `install-tasks.bat` ends in `pause`, which says it was
      run by hand in a console, never by a provisioner. Do not report it as done.

### Verified

- **The trap is live and closed.** On desktop-wsl, `hostname` is `g614jv` and
  `fleet_detect` returns **`desktop`** — measured, not argued. The resolver
  returns `desktop-wsl`. `provision/tests/backup-client.test.sh` reproduces it
  synthetically (a manifest whose `detect.hostname` is whatever box runs the
  suite), so it fails on any machine if the precedence ever inverts.
- **End to end on this box:** `bash provision/backup-client.sh` with no argument
  resolved `desktop-wsl`, ran its `install-tasks.sh`, and left **one** user timer
  under its unchanged name (`resticprofile-backup@profile-wsl`) with
  `WorkingDirectory=/home/me/machines/backup/desktop-wsl`. Invariant 1 intact.
- **Suite:** 47 suites, 45 pass, the same two environmental failures and no
  others.

### Found on the way, NOT fixed here

`provision.ps1` has **no `PLANNED_ROLES` equivalent**. Its fallback prints
"not yet implemented (skipped)" and leaves `$rc` at 0 — the identical hole
`49497bd` closed on the posix side. Adding the map entry in 5.3 fixes this
change's case; the missing guard is a pre-existing defect and its own piece of
work. → `docs/fleet-roadmap.md`.

## Task 6 — remove `backup/` from `vps` ✅ 2026-09-01 (`vps` f70b9cb)

- [x] **6.1** `git rm -r backup` — nine tracked files. Gated on a full comparison
      first: every tracked file has a counterpart in `machines`, and the two that
      differ (`latitude/profiles.yaml`, `wsl/install-tasks.sh`) differ only in
      header prose and the password path. **Invariant 1 re-proved by set equality**
      — the profile-name list and the `repository:` list are byte-identical on both
      sides, which is the check that actually matters, not a whole-file diff.
- [x] **6.2** Both docs repointed. They now say what `vps` keeps — the REST
      **server** container — and why the split falls there: the daemon that stores
      backups is a service, what a machine backs up is a machine fact.
- [x] **6.3** Done, but **not with the grep this box specified.** That grep was
      scoped `-- '*.md'` over `base.yaml|latitude|wsl|homeserver`, which misses
      `backup/restic-install.{sh,bat}` — the install command both READMEs name —
      and every non-markdown hit. Ran bare `git grep -n 'backup/'` instead: it
      found a live reference in `homeserver/servarr/README.md` that the specified
      grep would have left behind, and a comment in `restic-server/compose.yml`.
      Both fixed. What remains are historical records (a 2026-07 plan) and this
      move's own account of what was deleted.
- [x] **6.4** `homeserver/restic-server/` is functionally untouched — the only
      change is one comment qualifying `backup/latitude/profiles.yaml` as
      `machines/backup/...`. A deliberate one-byte deviation from "unchanged".
- [x] **6.5** Pulled on latitude, and verified by **firing the unit**, not by
      reading config: `resticprofile-backup@profile-latitude.service` →
      `Result=success`, `ExecMainStatus=0`, new snapshot `8b5e476e` at 17:41:58.
      The source path `/home/me/my/vps` survives with its 16 `.env` files; only
      `backup/` left it. Untracked leftovers survive as predicted, including the
      `backup/homeserver/pass.txt` symlink into `~/g513ie-prod-config/` — `git rm`
      does not touch untracked paths. That symlink is now unreferenced;
      `machines/backup/latitude/pass.txt` points at the same tracked file directly.
- [x] **6.6** `~/my/vps` deleted on desktop-wsl. `~/my` is now empty.

      **The escrow this box demanded had already failed, and nobody knew.**
      `~/my/vps/backup/wsl/pass.txt` was gone when Task 6 reached it — present in
      the restic snapshot of 2026-08-27 10:13, absent from the one of 2026-08-29
      18:38. It was swept along by the personal-projects move to `g15` two days
      after this plan wrote down that it must be decided deliberately. That is the
      exact failure the instruction existed to prevent, and writing the
      instruction did not prevent it.

      **Recovered and escrowed 2026-09-01.** `restic restore f7f978d7` — the repo
      held it only because `.resticignore` excludes `.config/restic/` and not
      `my/`, i.e. by luck, not by design. Confirmed to be what this box described:
      12 bytes, mtime 2026-04-27, differing from the live password at byte 1, so a
      second secret rather than a stale duplicate. Now tracked in dotfiles on the
      `desktop-wsl` branch as `~/.config/restic/pass-legacy-wsl-2026-04.txt`
      (commit `be81e44`), beside a new `README.md` in that directory saying which
      file is live, which is dead, and what retiring the dead one would take —
      because an unlabelled 12-byte password file is how this one nearly went in
      the first place.

      Not deleted despite almost certainly opening nothing: the repo it unlocked
      was `rest://server.gg.ez:8001/wsl`, whose drives were reformatted into
      `immich-mirror` / `spare320` / `immich-2024`. "Almost certainly" is not the
      standard for destroying the last copy of a secret.

## Task 7 — fix the two documentation claims that sent this work to the wrong repo

- [x] **7.1** Done. `machines/AGENTS.md` now says `machines` owns the profiles
      and schedules and `vps` keeps the REST **server** container — the daemon is a
      service, what a box chooses to back up is a machine fact. The contradiction
      itself is written up in place, because a file asserting two incompatible
      things is worse than one that is merely wrong: the reader picks the half that
      suits the task, which is exactly how this work started in the wrong repo.
      Dropped **Forgejo** from that sentence's service list too — wiped 2026-08-01.
- [x] **7.2** Done, and it was in **three** places, not the two this box named.
      `machines/README.md:96` carried the false claim verbatim ("`ssh-server`,
      `base` and `backup-client` are stubs that print a plan") and was not in the
      plan; `docs/fleet-roadmap.md` P3 had already been corrected on 2026-08-05 and
      updated again when the backup roles landed, so line 329 needed nothing.
      All now say the same thing: no stub file exists, the printed plan comes from
      `provision.sh`'s absent-function arm, and only `base` + `ssh-server` remain.
- [x] **7.3** (added) `backup/` had no row in AGENTS.md's top-level-directory
      table or in README's layout line — the tree moved in under Task 1 and no doc
      admitted it existed. Both now carry it, with the one non-obvious rule: each
      profile dir ships its OWN `install-tasks.sh` / `.ps1` because scope is not
      derivable by the caller (latitude is `schedule-permission: system` and needs
      sudo; a WSL client is user-scope and must NOT be root, or its units land in
      the system manager and the timer that backs the box up is never installed).
- [x] **7.4** (added) Recorded in AGENTS.md that `provision.ps1` has no
      `PLANNED_ROLES` equivalent, so a Windows role missing from `$RoleExecutors`
      reports success having done nothing. Roadmap P3 carries the same item. NOT
      fixed here — it is a guard, not a doc fix.

---

## Final verification

- [x] `machines/backup/` matches the pre-move `vps/backup/` — dir names excepted,
      plus two deliberately rewritten headers and the password path. Profile names
      and repository URLs proved identical **as sets**, which is the invariant.
- [x] No `pass.txt` and no `.env` is tracked in `machines`; `git check-ignore` proves it.
- [x] Latitude: four timers under their original unit names, all four with
      `Result=success`; the backup unit hand-fired again after the `vps` deletion
      produced snapshot `8b5e476e`, and the daily chain is unbroken through
      2026-09-01 04:30.
- [x] desktop-wsl: one user timer, `WorkingDirectory` into `machines/`,
      `Linger=yes`, snapshot `6137acc2` at 2026-09-01 06:00.
- [x] `just provision --machine latitude --dry-run` runs both new roles and mutates
      nothing (tripwire-asserted, not read off the output); `just test` green.
- [x] `vps` has no `backup/`, its docs point at `machines`, `restic-server`
      functionally untouched (one comment).

**Open, and deliberately so:**

- **5.5 — the Windows apply arm is UNVERIFIED.** `backup-client.ps1` has never
  run: no `backup/desktop/` or `backup/g15/` exists to run it against. Do not
  report it as working.
- **No profile dirs for `desktop` or `g15`.** The ask was the *capability*.
  Choosing what is irreplaceable on a box whose 416 GB nobody has reviewed is
  separate work, and those two stay out of `fleet.json`'s backup roles until they
  have a directory.
- **`provision.ps1` has no `PLANNED_ROLES` equivalent** — roadmap P3.

## Rollback

Nothing here is destructive until Task 6. Through Task 5 the old tree is still in
`vps` and the only host-side change is which directory a unit points at — reinstall
from `~/my/vps/backup/<dir>` and the previous state is back. After Task 6, recovery
is a `git revert` in `vps` plus the same reinstall. **No restic repository is
created, moved, renamed or deleted at any point in this plan** — that is the
property that makes it safe to run.
