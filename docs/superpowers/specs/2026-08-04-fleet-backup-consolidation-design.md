# Fleet backup consolidation — design

**Status: OPEN** — designed 2026-08-04, nothing implemented. Supersedes nothing;
the mechanisms it consolidates are all live.

Evidence base: `docs/2026-08-03-repo-review.md` §§A–F (the backups pass, re-run
and three-way verified) plus live probes on latitude, hub, air and desktop-wsl on
2026-08-03/04. Where this document states a measurement, that is where it came
from.

---

## The problem, stated as the user stated it

> "I don't want to remember all of the ways in which my fleet is being backed up.
> There should be one way, transparent, monitored, flexible for all our use
> cases. Maybe we can leave 2 or 3 tools, but let's just make all of it simpler.
> It shouldn't be that hard to support a fleet of 4 machines"

Seven mechanisms back up this fleet. Three of them — `mirror-refresh.sh`,
`archive-mirror.sh` and the resticprofile `latitude` profile — were designed
together on 2026-08-01, argue for each other by name and clock, and are the
best-documented thing in either repo. The other four arrived from a retired
machine, from inside a container, from a config-sync tool doing backup work by
accident, and from a migration nobody closed out.

**The load-bearing fact is not the number seven. It is that no file, in either
repo, lists what is backed up.** Reconstructing that list took both repos plus
four live boxes. Every fault below is a consequence of that absence.

### What is actually broken (measured, not inferred)

| Fault | Evidence |
|---|---|
| `archive-mirror.timer` has **never fired once** | Enabled 2026-08-01 18:07:38 +05, after that month's trigger point; `Persistent=yes` stamps at enable time so there is no catch-up. `journalctl -u archive-mirror.service` → `-- No entries --` (reproduces only under `sudo`). First real fire **2026-09-01 05:01:54**. It guards the 663 G 1970–2024 archive, onto a target that is **95 % full with 36 G free** and is **partition 3 of a Ventoy installer stick** (`/dev/sda3 LABEL="xs700"`). |
| The `g614jv` repo has **never been integrity-checked** | `check-before: true` was declared at `base.yaml:14`, inherited, and resolved by `resticprofile show`. `grep -c -i check` over the 3,284-line backup log spanning 2026-04-27 → 2026-08-02 returns **0**. **Cause found 2026-08-05: the placement hypothesis was right all along** — see open question 1, which is now closed. Fixed for `latitude`; `g614jv` is still unchecked, because its client could not be reached to test the change. |
| hub declares `backup-client` and has **no backup of any kind** | No restic/borg/rclone/kopia binary, no unit, no timer, empty crontab for both users, no `hub` profile in `vps`. It holds `/var/lib/headscale/db.sqlite` — the only copy of the tailnet control plane. |
| immich's `pg_dump` is an **undeclared producer** two mechanisms depend on | It is an immich web-UI setting, in no file in either repo. `mirror-refresh.sh:53` copies its output; `profiles.yaml:63` makes it restic source #1. Toggle it off and both downstream mechanisms keep reporting success over a directory that stopped gaining files. The *retired* `homeserver/profiles.yaml:8-18` declared it explicitly as a `stdin-command`; the 2026-08-01 redesign replaced a declared producer with an undeclared one and recorded only the drive-space reason for the change. |
| One 11-character password opens **both** repos, and lives **inside** the snapshot it unlocks | Three plaintext copies differ by line terminator, so `sha256sum` and `cmp` call them three files — restic trims the terminator and the same 11 characters are underneath. `.resticignore` does not exclude `~/.config`, so `restic ls 41a19b13 /home/me/.config/restic` returns `pass.txt`. Encrypted at rest, so not a leak — but restoring the wsl snapshot re-materialises the key to both repos. |
| The REST hub was down 23 min short of a full day, silently | Host crashed 2026-08-02 15:30:18 +05 (`last -x` → `crash`); the container's restart 8 s after boot failed to bind `100.64.0.8:8001` because tailscaled had not brought the address up. `RestartCount=0` ten hours later: a restart policy retries containers that **exit**, and this one never entered `running`. The compose file predicted the symptom and asserted a mitigation that `RestartCount=0` refutes. |
| **No backup data leaves latitude** | Only the two dotfiles mechanisms cross a machine boundary in a working state; between them they carry 45 paths and 26 files. The single machine-crossing *data* path is desktop-wsl → the REST hub. A latitude-level loss destroys the immich library, both mirrors, the archive, both restic repos and 129 G of migration data — and leaves you holding the password to all of it. |
| **Nothing verifies anything** | No `OnFailure=` on any unit, no alert, no statusboard row, no test in `provision/tests/` touching a backup. `--prometheus` is set on the hub and nothing scrapes it. `schedule-ignore-on-battery: true` on a laptop with no UPS makes a mains cut at 04:30 an exit-0 no-op — and it applies to the weekly `check` too. |
| **No restore has ever been tested** from either repository | Snapshot listing, `stats --mode raw-data` and one `cat config` succeeded read-only. That proves the repos are readable; it does not prove a restore yields a working immich DB. |

Note the shape they share. Only one of these is a job reporting an *error*. The
rest are **jobs reporting success while doing nothing**, which is why the design
below monitors freshness rather than exit status.

---

## Goals

1. **One place to look.** A single declaration listing every source, target,
   schedule and producer across the fleet.
2. **One report.** A command that renders live truth against that declaration,
   from any box, verifiable by hand.
3. **Cannot drift.** What is declared and what runs are the same artifact, because
   the second is generated from the first.
4. **Close the measured holes** in the table above.
5. **Fewer tools where it is free** — not as the primary objective.

## Non-goals

- **General fleet monitoring.** Deferred by decision and stays deferred.
  `fleet-notify` is a primitive with two consumers, not a monitoring system.
- **Offsite for the photo libraries.** 905 G against a home uplink; decided
  against, and the decision is *recorded in the manifest* rather than left
  implicit. See "the restore-story rule".
- **Rewriting `mirror-refresh.sh` / `archive-mirror.sh`.** Their headers carry
  hardware reasoning that is not re-derivable: why live PGDATA is excluded (an
  rsync of a running postgres dir is a torn copy that *looks* like a backup), why
  `-H` is mandatory, why `--delete` is off, why the source dock is the flaky one,
  why `--partial-dir` rather than `--append-verify`. Generated units, hand-written
  bodies.
- **Reducing to literally one tool.** No drive in the fleet has 815 G free, so a
  single-tool answer means buying hardware or dropping versioned history on the
  photos. Both rejected.

---

## Decisions

Each of these was put to the user and answered on 2026-08-03/04.

| # | Decision | Rationale |
|---|---|---|
| D1 | **One manifest + one report; tool count follows** | The stated pain is comprehension, not tool count. Seven mechanisms with one manifest are easy to hold; two mechanisms with no manifest are not. |
| D2 | **`machines` owns the backup system; `vps` owns declared producers** | Today the boundary cuts a mechanism in half: latitude runs **root-scope systemd units with `WorkingDirectory=/home/me/my/vps/backup/latitude`** — a `machines`-provisioned box running root timers out of the sibling repo's work tree. That is also how a tailnet IP ended up in a services repo. Backup is a machine property; an app dumping its own database is a service property. |
| D3 | **Manifest is a `backup` block in `fleet.json`, and it generates** | The only option where declaration and reality cannot diverge — and every fault above is such a divergence. It also gives `backup-client` / `backup-hub` something to read, so they stop being decorative stubs. |
| D4 | **Cross-backup the small set; photos stay single-site, declared** | latitude ↔ hub, both directions. hub has 20 G total / 12 G free / 960 MB RAM — enough for the small set, nowhere near the photos. |
| D5 | **`rest-server` + htpasswd + `--private-repos` + `--append-only`, bound `0.0.0.0`** | Auth turns LAN reachability from an open door into a credential check. A wildcard bind needs no address to pre-exist, so it kills the boot race **and** removes the tailnet IP from every repo. Three problems, one change. |
| D6 | **Report + statusboard row + push on stale** | Pull-based truth so the reporter is not the thing that failed, plus one active channel so discovery does not require looking. 13 days went unnoticed once, then 29 hours. |
| D7 | **The immich DB rides with the photos, not with the offsite set** | User's call, and correct: restoring albums/faces/people/stacks that point at files which no longer exist protects nothing. Generalised as the restore-story rule below. |
| D8 | **Promote tugtainer's Telegram bot to the fleet bot** | One fleet notification channel instead of per-service bots — the same consolidation instinct as the rest of this. |

### D5's cost, stated plainly

`--append-only` breaks `forget --prune`. The compose file rejected it for exactly
that reason: retention would become "a server-side chore on latitude" with no
home. Under D3 it has a home — a declared prune timer per repo, generated from
the manifest's retention block. This is a case where the consolidation makes a
previously-unaffordable protection affordable.

**But it collides with the per-client credential design, and the collision has to
be resolved rather than noticed later.** `rest-server --append-only` refuses
deletes over HTTP, so the prune must run on latitude against
`/mnt/spare320/restic-rest/<client>/` on the filesystem, bypassing the server.
That part works. What does not follow automatically: **`forget --prune` needs the
client's repo *encryption* password**, and per-client passwords escrowed on each
machine's own dotfiles branch are unreadable from latitude.

So the resolution is explicit: **a repo password is escrowed twice — on the
client's branch, for the client's own restore, and on latitude's branch, for the
prune of the repo latitude hosts.** The manifest records which host prunes which
target, so the requirement is declared rather than discovered when a prune timer
first fails.

That is a real trust statement and it belongs in writing: **`--append-only`
protects against a compromised or confused *client*, not against the backup
host.** latitude holds the data and the keys of every repo it maintains, so a
latitude compromise reads everything. That is not a regression — today one
11-character password on latitude opens both repos — but it is the boundary this
design keeps rather than closes, and the offsite copy on hub is what limits its
blast radius.

**`--private-repos` changes the on-disk path of a repo that already has history.**
It scopes each client to `/<htpasswd-user>/`, so `g614jv` moves from `/data/g614jv`
to `/data/<user>/g614jv`. Phase 1 **moves the directory server-side** and does not
re-init: those two snapshots (2026-08-01 and 2026-08-02) are the only history that
repository has, and re-initialising discards it to save a filesystem `mv`.

`0.0.0.0` was explicitly argued against in `restic-server/compose.yml:6-12`, and
that argument was correct **while `--no-auth` was set**: on g513ie it "exposed it
to every device on the wifi, guests included," and latitude has **no host
firewall** (`iptables -P INPUT ACCEPT` with only a `ts-input` jump; no ufw,
nftables or firewalld). Docker's published ports bypass `ufw`/`INPUT` via DNAT
anyway, so a later firewall would be a `DOCKER-USER` rule, not a `ufw allow`.
Auth is what inverts that argument, and it must land in the *same change* as the
bind. **Neither half is correct alone.** Update the compose comment rather than
deleting it — the reasoning is right about its own premise.

---

## Architecture

### The restore-story rule

A source declares what it is **useless without**, and it cannot reach a tier its
dependency has not reached.

```jsonc
{ "id": "immich-db", "useless-without": "immich-library" }
```

Two things this buys. The immich DB stops being offsited pointlessly (it is 2.9 G
of a 3.5 G set, so the offsite tier drops to **~600 M** and hub's 12 G stops being
a constraint). And if the photos ever *do* get an offsite target, the DB follows
automatically instead of being remembered.

The asymmetric case survives untouched: DB corrupt, photos fine, restore
yesterday's dump. That is precisely what `profiles.yaml:20-24` argues restic earns
its keep for, and it is a **local versioned** concern, not an offsite one.

### Manifest shape

Targets and producers are fleet-level; a target is shared infrastructure, not one
machine's private business. Sources are per-machine and reference them by id.

```jsonc
"backup": {
  "targets": {
    "spare320-restic": { "host": "latitude", "kind": "restic-local",
                         "path": "/mnt/spare320/restic/latitude",
                         "drive-uuid": "3a78fd88-deb0-4c1a-a576-14abd0631d57",
                         "offsite": false,
                         "retention": { "keep-daily": 30, "keep-weekly": 12,
                                        "keep-monthly": 24, "keep-yearly": 10 },
                         "check": { "every": "weekly", "read-data-subset": "5%" } },
    "latitude-rest":   { "host": "latitude", "kind": "restic-rest",
                         "url": "http://latitude.gg.ez:8001",
                         "append-only": true, "offsite": false,
                         "retention": { "keep-daily": 14, "keep-weekly": 8,
                                        "keep-monthly": 12, "keep-yearly": 5 },
                         "check": { "every": "weekly", "read-data-subset": "5%" } },
    "hub-rest":        { "host": "hub", "kind": "restic-rest",
                         "url": "http://hub.gg.ez:8001",
                         "append-only": true, "offsite": true,
                         "retention": { "keep-daily": 14, "keep-weekly": 8,
                                        "keep-monthly": 12, "keep-yearly": 5 },
                         "check": { "every": "weekly", "read-data-subset": "5%" } },
    "immich-mirror":   { "host": "latitude", "kind": "rsync",
                         "path": "/mnt/immich-mirror",
                         "drive-uuid": "a7d7b61e-…", "offsite": false,
                         "how": "hosts/latitude/debian/mirror-refresh.sh" }
  },
  "producers": {
    "immich-pgdump":   { "host": "latitude", "declared-in": "vps",
                         "output": "/var/backups/immich-db", "fresh-within": "26h" },
    "headscale-db":    { "host": "hub", "declared-in": "machines",
                         "how": "sqlite3 .backup", "output": "/var/backups/headscale",
                         "fresh-within": "26h" }
  }
}
```

`retention` lives on the **target**, not the source: it is a property of the
repository, it is what the append-only prune timer reads, and the two live
profiles already override the shared base with different values
(`latitude:86-89` 30/12/24/10, `wsl:74-77` 14/8/12/5) — which is why the base's
documented retention currently applies to no running profile. Drive UUIDs are
abbreviated in these examples only where the full value appears in the review;
the manifest carries them in full, because a truncated UUID cannot be matched
against `blkid`.

Per machine:

```jsonc
"latitude": {
  "roles": [ "…", "backup-hub", "backup-client" ],
  "backup": {
    "sources": [
      { "id": "immich-library", "path": "/mnt/immich",
        "targets": ["immich-mirror"], "at": "03:30" },
      { "id": "immich-db", "path": "/var/backups/immich-db",
        "producer": "immich-pgdump", "useless-without": "immich-library",
        "targets": ["spare320-restic", "immich-mirror"], "at": "04:30" },
      { "id": "telegrind-db", "docker-volume": "telegrind_pgdata",
        "targets": ["spare320-restic", "hub-rest"], "at": "04:30" }
    ]
  }
}
```

**Every fleet member carries a `backup` key, and `none` is a value with a
reason:**

```jsonc
"desktop": { "backup": { "none": "OneDrive, unassessed — decided 2026-08-04" } }
```

Today desktop and air are *role-consistent*: they declare no backup role and have
no backup, so nothing looks wrong anywhere — while air is the primary dev box
holding the only copy of work in progress. Consistency is not correctness.
Requiring an explicit decision per machine is what makes an absence visible.

### What each declared field buys the report

- **`producer` + `fresh-within`** — makes the undeclared immich dump checkable.
  Switch it off in the web UI and the report goes red instead of two mechanisms
  staying green over a static directory.
- **`drive-uuid`** — the repo's never-by-`/dev/sdX` rule made machine-readable, so
  the report distinguishes **stale** from **target not mounted**. An rsync to an
  unmounted path with `--delete` off looks exactly like success.
- **`append-only`** — tells the report which repos need a *server-side* prune
  timer, so enabling the protection cannot silently disable retention.
- **`how`** — the escape hatch that keeps the two rsync scripts hand-written.

### Where the seven mechanisms go

| Today | After |
|---|---|
| immich internal `pg_dump` (undeclared) | Declared in `vps`; manifest checks output freshness |
| `mirror-refresh.sh` | Survives as the *how*; manifest declares what/when |
| `archive-mirror.sh` | Same, plus its target moves off the Ventoy stick |
| resticprofile `latitude` | Config generated from the manifest |
| resticprofile `wsl` | Generated; gains per-client auth |
| dotfiles bare repo, latitude | **Stops being a backup.** What it uniquely protects (the restic password, every prod `.env`) becomes properly covered; it returns to config sync, and the manifest records that it is not a backup |
| dotfiles bare repo, air | Same — and **air becomes a real client**, which it has never been |

Added, all measured holes: **hub → latitude** (headscale DB, DERP and noise keys,
`/etc/wireguard/wg0.conf`), **latitude → hub** for the ~600 M irreplaceable set,
and `telegrind_pgdata` / `embedthat_redis_data` / `tugtainer_tugtainer_data`,
which are live state in no source at all today.

---

## Credentials

**`metheoryt/machines` is a public repo** (`vps` and `dotfiles` are private).
Verified: `gh api repos/metheoryt/machines --jq .private` → `false`. This is a
hard constraint on the design, not a footnote: the manifest declares *which*
credentials exist and *where they come from*, never a value.

Two kinds, conflated today into one 11-character string:

**Transport auth (htpasswd, per client).** Generated on the client, registered to
latitude over the SSH trust the fleet already provisions (`tier_ssh_trust`,
`provision/fleet-authorized-keys`). The htpasswd file is `me`-owned and
bind-mounted into the container, so no sudo is involved and no secret enters any
repo. Rotating one client touches one line.

**Repo encryption (per client).** Generated on the client and never leaves it —
except it must, or a total client loss makes the backup unrestorable. **The escrow
is the private dotfiles repo, declared.** That is already the sole off-box copy of
the current password; today by accident, with nothing saying so. Making it
explicit is most of the fix.

Escrow specifics, because "the dotfiles repo" is not precise enough to implement
against. A repo password is host-specific, so it goes on **that machine's branch,
never `main`** — `$HOME/CLAUDE.md`'s rule that a path is shared or host-local but
never both, and its "default to host-local" guidance, both apply. Adding the file
is the two-step: a `!`-line in `~/.gitignore` **anchored with a leading slash**
(unanchored patterns also un-ignore a stray match inside any project checkout
under `$HOME`) plus an explicit `dotfiles add`, because the sync timer runs
`add -u` and never stages an untracked path. Verify with `check-ignore -v` before
staging: the trailing deny block re-ignores key material last, and a password file
must not be named such that it lands there silently.

And `.resticignore` gains `~/.config/restic`, so the key stops living inside the
repository it unlocks.

**The headscale DB cannot be file-copied.** 86,016 B with a 4,120,032 B WAL; a
naive copy is torn — the same trap `mirror-refresh.sh:39` already avoids for
immich's live PGDATA. It needs `sqlite3 .backup` as a declared producer, which is
the producer concept earning its keep on a second case. Whether a consistent copy
is possible without stopping headscale is **unverified** (see open questions).

**The fleet bot token is in the one volume nothing backs up.** It is not in any
config file — `homeserver/tugtainer/.env` carries only `AGENT_SECRET` and
`DOCKER_HOST`. It lives in `tugtainer.db` (45,056 B, root-owned) inside
`tugtainer_tugtainer_data`, which the review found is in no source. D8 therefore
means: extract once, escrow in private dotfiles as a fleet credential, and make
that volume a declared source. Tugtainer keeps its own copy in its DB — that is
its config store — so the escrow is what makes the token survivable rather than a
BotFather re-issue.

---

## Monitoring

**Freshness, not exit status.** Every fault in the table above except one is a job
reporting success while doing nothing. A job can lie about succeeding; it cannot
lie about a snapshot that is not there. One check — snapshot age against the
manifest's declared schedule — catches all of: hub down with a green client timer,
a timer that never fired, a battery skip, a dirty-tree skip, a producer switched
off, an unmounted target.

The check runs on latitude (always-on, and it holds what it needs) and is
runnable from any box through the existing `fleet-dispatch.sh` primitives
(`fd_probe` / `fd_run` / `fd_wsl_hosts`).

Three properties worth stating because they are not obvious:

- **A repo's freshness is readable without its password.** rest-server stores
  snapshot files on latitude's filesystem, so `snapshots/` mtimes answer "when did
  `g614jv` last land" with no decryption and no cooperation from the client. **The
  box that failed cannot hide the failure.**
- **`schedule-ignore-on-battery` stops being a silent hazard.** It is the right
  flag for a laptop with no UPS, and the wrong one for a host with the sleep
  targets masked. **Set false on `latitude` 2026-08-05**, after it fired for real
  at 2026-08-04 18:35 and returned exit 0 for a run that produced nothing; the
  `run-before` mount assertion is what makes that safe, converting an outage into
  a loud failure rather than a silent success. It stays `true` in `base.yaml` for
  genuine laptops. Generation must therefore key it off the host, not the base —
  and the report still covers the case, because a battery skip and a dead timer
  are indistinguishable by exit status and identical by snapshot age.
  **This supersedes `docs/superpowers/plans/2026-07-27-fleet-migration-mac-primary-latitude-server.md`
  Step 3 ("Do not remove it"), whose premise is measurably wrong**: it argued that
  "a power cut should not start a multi-hour restic run on battery," but this
  profile's run is *six seconds* — 3 s of backup plus 4 s of check against a 2.6 G
  repo. The cost it was protecting against does not exist, and `statusboard.sh`
  already takes the opposite position in code: "on an always-on box wired to the
  wall, running on battery IS the alert."
- **`check-before: true` is fixed, and the scheduled `check` still earns its
  keep.** The cause was placement (open question 1, closed 2026-08-05): the key
  belongs under `backup:`, and `latitude` now runs `init → check → backup`. That
  does not make the per-repo scheduled `check` redundant — a pre-backup check only
  runs when a backup runs, so the repo that most needs verifying (the one whose
  client has stopped) is exactly the one it stops covering. Generation should emit
  both, and the report shows the age of the scheduled one.

Surfaces: `just backup-report` (source, target, last snapshot age, last check age,
verdict), a statusboard row carrying worst-case age and red count, and a
`fleet-notify` push when an entry goes stale.

---

## Phases

Ordered so the instrument arrives before the machinery it verifies. Each phase is
independently worth shipping.

**This spec is deliberately larger than one implementation plan.** Plan and build
one phase at a time, each with its own plan document, and re-read the report's
output before planning the next — phases 3 and 4 are shaped by what phase 2
actually surfaces. Planning all five at once would commit to a picture of the
system drawn before the instrument that measures it exists.

**Phase 1 — stop the bleeding, in the target shape.** htpasswd,
`--private-repos`, `--append-only`, `0.0.0.0`, per-client credentials,
`.resticignore` excludes `~/.config/restic`, the declared prune timer append-only
requires. This **is** the hub durable fix — not a throwaway patch. No manifest
needed. Until it lands, the next reboot can still take the hub down.

**Phase 1 exit criteria, because it rewrites the fleet's only machine-crossing
data path before the report exists to watch it.** Its client is a
`systemd --user` timer on a box this review already found silently frozen for ~35
hours under a green unit, so a half-landed Phase 1 is a silent outage with no
instrument yet built to catch it. Therefore, in the same session as the change:

1. `docker inspect` shows a published port and `ss -lntp` shows something
   listening — the `up -d` trap is that a reused container returns with
   `HostConfig.PortBindings` intact and `NetworkSettings.Ports` empty, running and
   reachable by nobody. `--force-recreate` is required.
2. From desktop-wsl, `resticprofile ... -n wsl snapshots` lists **both**
   pre-existing snapshots at their new path — proving the directory move preserved
   history and the new credential works.
3. One `restic restore` of a single file to a temp dir, diffed. This is also the
   first restore ever performed from this repository.
4. **Reboot latitude and re-check 1–2.** The failure being fixed is a boot race,
   and this repo's own rule is to verify a scheduled job by firing its schedule,
   not by running the script. A `docker compose up` that works proves nothing
   about the next boot.

**Phase 2 — manifest + report, read-only.** The `fleet.json` backup block
describing what exists *today*; `just backup-report` verifying it; nothing
generated. This is where "one place to look" lands, and it immediately turns four
known-but-invisible faults into red rows.

**Phase 3 — close the measured holes.** hub ↔ latitude cross-backup; the three
docker volumes as declared sources; headscale via `sqlite3 .backup`; immich's dump
declared in `vps`; the archive target off the Ventoy stick; air becomes a client.

**Phase 4 — generation.** `tier_backup` plus real `backup-client.sh` /
`backup-hub.sh` executors emitting resticprofile configs and units from the
manifest. Last, because everything before it is already verifiable by the report —
generation without a report is unverifiable machinery.

**Phase 5 — `fleet-notify` + the statusboard row.**

---

## Testing

Red-first, in `provision/tests/`. `just test` is the gate and reaches every
`*.test.sh` in the repo as of `49497bd`, so a new suite needs no wiring.

- **Manifest schema** — every fleet member carries a `backup` key (`none` counts,
  bare absence does not); every `targets` / `producer` id resolves; the
  `useless-without` coupling holds, so no source reaches an offsite tier its
  dependency has not. That last assertion is D7 as executable code rather than a
  paragraph.
- **No secrets in the manifest** — every credential field is a path; no value is
  secret-shaped. This suite exists specifically because the repo it guards is
  world-readable.
- **Report verdicts** — fixture manifest × fixture live state, asserting the three
  cases that all read as success today: stale-but-green, target-unmounted,
  producer-stopped.
- **Generation** — golden resticprofile YAML from a fixture manifest.
- **`just backup-verify-restore`** — restore one file from each repo to a temp dir
  and diff it. **No restore has ever been tested from either repository.** This is
  the cheapest possible closure of the largest untested assumption in the system.

Follow the repo's own precedent for platform-dependent assertions:
`provision/tests/fleet-ssh-config-ps.test.sh` runs a module's `-SelfTest` when
`pwsh` is present and asserts platform-independent invariants unconditionally.
Prefer behavioural assertions; where a static one is the honest choice, say why —
`provision/tests/git-autofetch.test.sh` Case 8 is the precedent.

---

## Open questions

These are unresolved, not deferred — each needs an answer during implementation.

1. ~~**Why `check-before: true` never executes.**~~ **CLOSED 2026-08-05 — it was
   the placement, and the earlier test was disproved by the wrong instrument.**
   `check-before` belongs under `backup:`. At profile level resticprofile 0.33.1
   parses it, stores it, and echoes it back from `show` — and never runs it. So
   `show` cannot distinguish correct placement from inert placement, and using it
   as the oracle is what "disproved" the right hypothesis. **The instrument that
   works is counting issued `restic` commands**, which is falsifiable where `show`
   is not: 4 scheduled runs of `latitude` issued 4 `init`, 4 `backup`, 4 `forget`
   and 0 `check`; moving the key under `backup:` in the same harness produced
   `init → check → backup`, confirmed live at 01:55:19.
   No other inherited key is implicated — the failure is specific to a key
   declared at the wrong level, not to inheritance.
   **The lesson generalises past this key:** `resticprofile show` reports what was
   *parsed*, never what will *run*. Any guard verified only by `show` is unverified.
2. **Whether the headscale DB can be copied consistently without stopping
   headscale.** The 4.1 MB WAL was observed, not checkpointed or copied.
3. **Whether OneDrive on desktop-native protects anything.** Its updater tasks
   run; the synced set was never enumerated. If it covers `C:\Users\methe` it is
   an eighth mechanism, in neither repo. `desktop`'s `none` value should record
   the answer, not the question.
4. **Where the archive target goes.** `/mnt/xs` is 95 % full on a Ventoy stick
   partition. Phase 3 needs a real drive named, and `archive-mirror.sh:26-28`
   stakes its 37 GiB of slack on 1970–2024 being a closed set — a correct bet, but
   the free space is now inside the noise of one large import.
5. **The 129 G of hand-made migration copies** (`~/staging/music` +
   `/mnt/spare320/music-from-g513ie`, `~/staging/Настя Стас GoPro` +
   `/mnt/immich-mirror/staging`) need a verdict: declared source, or deliberately
   dropped. They were matched by size only (89 G each), not by checksum, so
   "duplicate" is an inference from the migration logs.
6. **Both restic repos share one spindle.** `spare320-restic` and the REST hub's
   data live on sdg1, UUID `3a78fd88-…`. `profiles.yaml:31-34` argues that drive
   on contention grounds and is right about that; it never considers that the
   fleet's only two repositories then share one enclosure. Cross-backup (D4)
   mitigates for the small set only.

## Deliberately settled — do not re-raise

Headscale ACLs, general monitoring, rotating the leaked telegrind credentials,
rotating the `fFZU…` desktop key, latitude's unencrypted root, and pointing
navidrome at `PicardedMusic`. The `C:` filesystem review on `server` is the
user's.

---

## References

- `docs/2026-08-03-repo-review.md` §§A–F — the backups pass; every measurement
  above traces there or to a live probe on 2026-08-03/04
- `review/2026-08-03-path-ledger.md` — per-path verdicts
- `~/my/vps/backup/{base.yaml,latitude/profiles.yaml,wsl/profiles.yaml}` — the
  configs this replaces; `latitude/profiles.yaml:5-11,20-24,31-34,77-80` carry the
  reasoning worth preserving
- `~/my/vps/homeserver/restic-server/compose.yml` — the hub, and the corrected
  account of the boot race
- `hosts/latitude/debian/{mirror-refresh.sh,archive-mirror.sh,install-timers.sh}`
  — the hand-written bodies that survive
- `docs/2026-08-01-nixos-harvest.md` §1 — the `ssh-server` firewall shape, needed
  if latitude ever gains a host firewall
- `agents/plugin/skills/lib/fleet-dispatch.sh` — the dispatch primitives the
  report reuses
