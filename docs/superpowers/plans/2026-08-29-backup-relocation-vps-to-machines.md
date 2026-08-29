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

- [ ] **3.1** On desktop-wsl, from `~/machines/backup/desktop-wsl`:
      `bash install-tasks.sh` (it is `cd "$(dirname "$0")"` + `resticprofile schedule --all`).
- [ ] **3.2** Confirm the unit now points at the new dir and that linger is still on
      — without linger the user timer stops firing silently:

```bash
systemctl --user cat resticprofile-backup@profile-wsl.service | grep WorkingDirectory
loginctl show-user "$USER" | grep Linger      # Linger=yes
systemctl --user start resticprofile-backup@profile-wsl.service
systemctl --user show -p Result resticprofile-backup@profile-wsl.service
```

- [ ] **3.3** Confirm from **latitude**, not from the client — the box that failed
      cannot hide the failure. Newest snapshot mtime under the hub repo:

```bash
ssh latitude 'sudo ls -lt /mnt/spare320/restic-rest/g614jv/snapshots | head -3'
```

## Task 4 — write the two role executors

Convention: `provision/roles/<role>.sh` is **sourced** by `provision.sh` and defines
`role_<role with - as _>`, taking `(mode, platform, machine)` and honouring
`dry-run`. Copy the shape from `roles/repos.sh`.

- [ ] **4.1** `provision/roles/backup-client.sh` → `role_backup_client`.
      Installs restic + resticprofile if absent, then runs
      `backup/<machine>/install-tasks.sh` when that directory exists; prints
      `no profile dir for <machine> (skipped)` and returns 0 when it does not, so a
      declared-but-unconfigured client is a visible skip rather than a failure.
      Platform `windows` dispatches the `.bat` from the `.ps1` side.
- [ ] **4.2** `provision/roles/backup-hub.sh` → `role_backup_hub`.
      Asserts the REST server is up and reachable on the tailnet address, asserts
      `/mnt/spare320` is a real mountpoint, and installs latitude's own schedules.
      It must **not** create repositories — `initialize` stays with the profiles.
- [ ] **4.3** `provision/tests/roles.test.sh` — extend it: both functions defined
      after sourcing, dry-run mutates nothing, a missing profile dir returns 0.
- [ ] **4.4** Run the suite. **`just` is not installed on desktop-wsl**, so use the
      for-loop form from AGENTS.md. The documented "28 suites, 0 failures" is stale
      on two counts: the loop finds **37** suites, and **2 fail for environmental
      reasons unrelated to any of this work** —
      `provision/tests/expansion-multibyte.test.sh` (its bash-behaviour self-test;
      its repo scan passes) and `provision/tests/fleet-ssh-config-ps.test.sh`
      (`UnauthorizedAccess` from `powershell.exe` under WSL). The gate here is
      therefore **no NEW failures beyond those two, and
      `provision/tests/roles.test.sh` green** — not an unreachable zero. A red count
      treated as a baseline is exactly how a real bug sat unread for weeks
      (`docs/fleet-roadmap.md` P4), so re-measure the two before accepting them.

## Task 5 — make `fleet.json` describe reality

- [ ] **5.1** Add `backup-client` to **desktop** — it has been running a client for
      weeks without declaring the role. (The client lives in the WSL distro;
      `desktop` is the manifest entry that owns it, since `desktop-wsl` is
      self-declared and never appears in `fleet.json`.)
- [ ] **5.2** Leave `hub`'s `backup-client` declared and unconfigured. Task 4.1
      makes that print a skip. Giving hub a real profile is the offsite copy, which
      is its own piece of work and needs capacity that does not exist yet
      (roadmap P0, deferred).
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
