# Village Offsite Backup Site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put a second, independent copy of the fleet's irreplaceable data — 956 GB of photos and 124 GB of restic repositories — on an always-on box 900 km away, seeded once by hand and fed deltas over a residential fibre link forever.

**Architecture:** The photo libraries move from plain rsync mirrors into a new restic repository, which is created on the very drive that travels; that drive then becomes the village box's internal data disk. latitude pushes to it over the tailnet with `restic backup` against a `rest-server` running `--append-only`, so Almaty can add history and can never remove it. The two existing restic repositories ride along as a plain no-delete `rsync`, which is append-only by construction because restic pack files are immutable. The village box holds **no encryption password**: a pack file's name is the SHA-256 of its own stored bytes (measured, see Global Constraints), so a full data-integrity sweep needs no key and no restic binary — the box proves its own bytes are intact while holding nothing but ciphertext.

**Tech Stack:** bash, restic 0.18.x + resticprofile 0.33.1, `rest-server` 0.14.0 (native binary + systemd unit), systemd timers, rsync over ssh, Headscale tailnet, Debian 13.

**Spec:** `docs/superpowers/specs/2026-09-12-village-offsite-backup-design.md`

---

## Corrections to the spec — read before Task 1

Four of the spec's statements were falsified while writing this plan. The plan
implements the corrected version; the spec is left as the record of the design
conversation.

1. **The hub does NOT run `--no-auth`, and has not since 2026-09-08.**
   `~/my/vps/homeserver/restic-server/compose.yml` runs
   `--private-repos --append-only --prometheus` with an htpasswd file at
   `/data/.htpasswd`, on a **wildcard** bind (`8001:8000`). The spec's
   "reachability IS authorisation" describes a posture that was already retired.
   So the village box does not have to depart from the hub — it copies it.

2. **Do NOT bind the village `rest-server` to its tailnet address.** The spec
   asks for "tailnet address only AND auth". latitude tried exactly that and it
   cost 29 hours of lost backups on 2026-08-02 and 3 days on 2026-08-04: a
   service cannot bind `100.64.x.x` before `tailscaled` is up, the bind fails
   during network setup so the process never reaches a running state and never
   exits, and nothing that only retries *exited* services will ever recover it.
   On a box nobody can touch, that is the worst failure available. **Wildcard
   bind, credentials carry the security argument** — which is the conclusion
   latitude already reached. A native systemd unit can also order itself
   `After=tailscaled.service`, but a bind with no address to wait for has no
   race left to lose, and self-recovery is the whole premise of this site.

3. **No encryption password on the village box, and no `prune` there.** The
   spec put `prune` on the village box "with its own key". It is not needed:
   the keyless SHA-256 sweep (Global Constraints) verifies data integrity
   completely, and `forget`/`prune` are what would need a key. Dropping both
   means physical theft of the box yields ciphertext only. **Cost, stated
   plainly:** the offsite repo never reclaims space, so a photo deleted in
   Almaty is kept offsite forever. Against ~1 TB on an 8 TB disk with restic's
   deduplication and a payload that is 663 GB frozen archive, that is decades
   of headroom — and for a backup of last resort, never forgetting is closer to
   a feature than a defect.

4. **`backup-offsite` is not in `PLANNED_ROLES`, so there is nothing to
   delete.** `provision.sh:72` is `PLANNED_ROLES="${MACHINES_PLANNED_ROLES-base
   ssh-server}"`. The real constraint is **ordering**, and it is stricter than
   the spec's version: the executor and its `roles.test.sh` assertion must land
   **before or with** the `fleet.json` entry, or `just provision --machine
   offsite --apply` exits 1 with "no executor, and not declared in
   PLANNED_ROLES". Precedent: `backup-hub` and `backup-client` landed with
   their `PLANNED_ROLES` deletion in the same commit on 2026-09-01.

---

## Global Constraints

Copy these into every task's mental checklist. Each one is a trap this repo has
already paid for.

- **A restic pack file's name IS the SHA-256 of its stored bytes.** Measured on
  latitude 2026-09-12: `/mnt/wd8/restic/latitude/data/8a/8a1f4cce…cc75`,
  `sha256sum` → `8a1f4cce…cc75`. This is what makes a keyless integrity sweep
  possible. It covers `data/`, `index/` and `snapshots/` (all content-addressed);
  it does **not** cover `config` and `keys/*`, which are compared by hash against
  a recorded baseline instead.
- **`initialize` is opt-in per profile, never global.** Measured on
  resticprofile 0.33.1: a profile's `initialize: false` is Go's zero value and is
  indistinguishable from unset, so a global `true` can never be switched off. See
  `backup/base.yaml`.
- **`check-before` goes under `backup:`, never at profile level.** At profile
  level it parses, is echoed back by `resticprofile show`, and never runs — four
  scheduled runs of the `latitude` profile issued zero `restic check`.
- **Every profile carries a `run-before: test -f <repo>/config` mount
  assertion.** `/mnt/*` is mounted `nofail`, so an absent drive leaves an
  ordinary empty directory that every path still "exists" under.
- **`schedule-ignore-on-battery: false` on any mains-bound box.** On a box that
  never sleeps, "running on battery" does not mean portability, it means the
  power went out — and the default skip exits 0, reporting success for a night
  that produced nothing.
- **Mount every external drive by UUID, never by `/dev/sdX`.** Letters reshuffle
  on every boot on latitude.
- **A failed `Condition*` is `Result=success`.** Never gate a backup destination
  on one; check the mount by UUID inside the script.
- **Two failures must not share one exit status.** The convention on latitude's
  mirror lock is 75 = lock held, 78 = wrong filesystem, everything else rsync's.
- **`platform: debian` in `fleet.json` whatever apt distro ships.** The token is
  a platform *class*; `ubuntu` makes every posix role executor print "no posix
  executor (skipped)" and return 0 while `--apply` reports success.
- **A non-interactive ssh PATH on Debian excludes `/usr/sbin` and `/sbin`.** Any
  script calling `findmnt`, `blkid`, `smartctl` or `badblocks` must
  `export PATH=/usr/sbin:/sbin:/usr/bin:/bin`.
- **The nightly slot must be picked against the existing ledger on `/mnt/wd8`:**
  04:30 latitude backup, 05:00 g15 client, 06:00 desktop-wsl client, 07:30
  g614jv forget, 09:30 g513ie forget, Sun 06:00 latitude check, Sun 08:30
  g614jv check, Sun 10:30 g513ie check. State the contention reasoning in the
  profile comment the way the neighbouring profiles do.
- **Measured payload, 2026-09-12** (cite the date; `profiles.yaml` and the
  roadmap still carry the older 242 G figure for `/mnt/immich`):
  `/mnt/immich` 293 GB · `/mnt/immich-2024` 663 GB · `/mnt/wd8/restic-rest`
  112 GB · `/mnt/wd8/restic` 12 GB.

### Named assumption: `rest-server` runs as a native systemd unit, not a container

The spec does not say which. This plan picks **native binary + systemd unit**,
for three reasons:

1. The `machines`/`vps` boundary gives `vps` "the restic REST server *container*
   latitude's hub runs" — that container is part of the cyphy.kz stack. The
   village box has no stack; being a backup sink is the machine's entire
   purpose, so it is a machine fact.
2. Docker on the appliance drags in `tier_docker` (workstation-profile only, and
   deliberately never upgrades) **and** the bind-source race — Docker silently
   creating an empty bind source is this repo's most expensive failure class,
   with two dated incidents. A native binary reading a directory cannot
   reproduce it, and it retires the hub selfcheck's "container and host see ONE
   `.htpasswd`" guard as unnecessary rather than as something to port.
3. The spec already says appliance: no `agents`, no `repos`.

**If the owner prefers the container instead:** the compose file moves to `vps`,
`tier_docker` joins the offsite profile, `install-docker-ordering.sh` gains an
`offsite` variant, and the `.htpasswd` bind guard comes along. Nothing else in
this plan changes.

---

## Scope check

One plan document, six phases. Phases 2 (visibility) and 3 (the box) are
independently shippable and Phase 2 is useful to the fleet even if the trip
never happens — but they are one trip-bound deliverable and splitting the
document would fragment the dependency chain that makes the drive-purchase date
the only hard external deadline.

**The critical path is the drive, not the box.** `badblocks -w` on 8 TB is
multiple days and it runs *after* the identity gate, which runs on the shop's
return clock. Everything else is downstream of Task 2 finishing.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `hosts/latitude/debian/restic-pack-verify.sh` | Keyless integrity sweep over a restic repository tree. One job: hash every content-addressed file and compare with its name. Used on both ends. |
| `hosts/latitude/debian/backup-status.sh` | The collector. Emits one row per backup job (`name\|age\|period\|state\|detail`) plus `--json`. Reads snapshot-dir mtimes and the pulled offsite status; needs no restic binary and no password. |
| `hosts/latitude/debian/systemd/backup-status.{service,timer}` | Runs the collector every 15 min. |
| `provision/statusboard/backup-jobs.latitude5520.conf` | Declared expected period per job — the thing that separates "late" from "merely not periodic". |
| `provision/roles/backup-offsite.sh` | The `backup-offsite` role executor. |
| `provision/tests/backup-offsite.test.sh` | Suite for the executor and the collector's pure helpers. |
| `hosts/offsite/debian/install-rest-server.sh` | Installs the pinned `rest-server` binary, its user, its htpasswd and its unit. |
| `hosts/offsite/debian/offsite-selfcheck.sh` | The village box's own health: mount by UUID, free space, SMART, newest snapshot age, last sweep result. Writes `/var/lib/offsite/status.json`. |
| `hosts/offsite/debian/systemd/*.{service,timer}` | `offsite-selfcheck` (hourly), `offsite-verify` (weekly sweep). |
| `hosts/offsite/debian/install-timers.sh` | Copies units into `/etc/systemd/system` — copies, never symlinks, so a `git pull` cannot change what root runs on a timer. |
| `hosts/offsite/debian/README.md` | Why this box exists, what it must never be given (a key), and the recovery runbook. |
| `backup/latitude/pass-photos.txt` | Symlink to the host-local password file. Gitignored (`**/pass.txt` pattern extended). |

**Modified:**

| Path | Change |
|---|---|
| `backup/latitude/profiles.yaml` | New `photos` profile; later re-pointed from the local seed path to `rest:`. |
| `provision/statusboard/statusboard.sh` | `sb_backup_alerts` (pure) + a rows read in `sb_sample_slow` + a call in `sb_alerts`. |
| `provision/tests/statusboard.test.sh` | Severity fixtures for `sb_backup_alerts`, in the `FA=`/`DA=` idiom at lines 1018–1052. |
| `provision/tests/roles.test.sh` | `defined role_backup_offsite`. |
| `fleet.json` | The `offsite` member. |
| `provision/statusboard/disks.latitude5520.conf` | dockA0 occupant changes twice (seed drive in, ST1000LM024 in after it leaves). |
| `hosts/latitude/debian/install-timers.sh` | Installs `backup-status.timer`. |
| `docs/fleet-roadmap.md` | P0's deferred backup-report item becomes done. |

---

# Phase 0 — Free the bay, buy the drive

## Task 1: Retire spare320 on proof and free dockA0

`/mnt/spare320` (ST320LT020, 36k power-on hours) holds 123 G: the pre-migration
copies of all three restic repositories, now living on `/mnt/wd8`. It is the
only one of the four dock bays that can be freed. **The bay is lent, not
released** — `disks.latitude5520.conf` already records that the ST1000LM024 on
the flaky NS1066 bridge is waiting for it. The seed drive borrows it first;
Task 16 hands it over.

The retirement gate is proof by content hash, never elapsed days. The Global
Constraints entry makes that cheap: for `data/`, `index/` and `snapshots/`
files the **name is the hash**, so equality of the relative path set is equality
of content. Only `config` and `keys/*` need actual hashing.

**Files:**
- Create: `/var/tmp/spare320-retirement.txt` (evidence, not tracked)

- [ ] **Step 1: Prove the file sets are identical**

```bash
ssh latitude.gg.ez 'sudo bash -s' <<'EOF'
set -u
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
out=/var/tmp/spare320-retirement.txt
: > "$out"
for pair in \
  "/mnt/spare320/restic/latitude:/mnt/wd8/restic/latitude" \
  "/mnt/spare320/restic-rest/g614jv:/mnt/wd8/restic-rest/g614jv" \
  "/mnt/spare320/restic-rest/g513ie:/mnt/wd8/restic-rest/g513ie"
do
  old="${pair%%:*}"; new="${pair##*:}"
  echo "== $old -> $new" | tee -a "$out"
  # Content-addressed trees: the relative path IS the content hash.
  diff <(cd "$old" && find data index snapshots -type f | sort) \
       <(cd "$new" && find data index snapshots -type f | sort) \
    >>"$out" 2>&1 && echo "  content-addressed set: IDENTICAL" | tee -a "$out" \
                  || echo "  content-addressed set: DIFFERS — STOP" | tee -a "$out"
  # config and keys/* are not content-addressed; hash them.
  for f in config $(cd "$old" && find keys -type f); do
    a=$(sha256sum "$old/$f" | cut -d' ' -f1)
    b=$(sha256sum "$new/$f" 2>/dev/null | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then echo "  $f: match" | tee -a "$out"
    else echo "  $f: MISMATCH — STOP" | tee -a "$out"; fi
  done
done
EOF
```

Expected: every line reads `IDENTICAL` or `match`. **A single `DIFFERS` or
`MISMATCH` stops this task** — it means the migration left something behind, and
that is a finding, not an obstacle to route around.

- [ ] **Step 2: Prove the new copies are internally sound**

```bash
ssh latitude.gg.ez 'sudo bash -c "cd /home/me/machines && \
  resticprofile -n latitude check --read-data-subset 5% && \
  resticprofile -n g614jv-maintenance check --read-data-subset 5% && \
  resticprofile -n g513ie-maintenance check --read-data-subset 5%"'
```

Expected: three `no errors were found`.

- [ ] **Step 3: Unmount, remove from fstab, pull the drive**

```bash
ssh latitude.gg.ez 'sudo bash -s' <<'EOF'
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
findmnt -no SOURCE,UUID /mnt/spare320          # record the UUID in the commit message
sudo umount /mnt/spare320
sudo sed -i 's#^\([^#].*/mnt/spare320.*\)$#\# retired 2026-09-12: \1#' /etc/fstab
sudo findmnt --verify                           # must not introduce a NEW finding
EOF
```

Then physically remove the ST320LT020 from dockA0 (`u4-1:0`, the **front** bay
of the dock holding the 320 G). Label it and shelve it — do not wipe it; it is
free redundancy until the offsite copy exists.

- [ ] **Step 4: Retire the mountpoint from the docker-ordering guard**

`/mnt/spare320` is not in `MOUNTS` (the repos moved to `/mnt/wd8`), so verify
rather than assume, and unfreeze the mountpoint if it is frozen:

```bash
ssh latitude.gg.ez 'grep -n "MOUNTS" -A12 ~/machines/hosts/latitude/debian/install-docker-ordering.sh | head -20; lsattr -d /mnt/spare320'
# If /mnt/spare320 appears in MOUNTS: delete the line, then run the script with `add`
# — since 2026-09-10 `add` unfreezes any /mnt/* dir not in the array. NEVER chattr -i by hand.
```

- [ ] **Step 5: Commit the evidence**

```bash
cd ~/machines
git add provision/statusboard/disks.latitude5520.conf
git commit -m "latitude: retire spare320, dockA0 free (lent to the offsite seed)

Proof, not elapsed days: the three repos' content-addressed trees (data/,
index/, snapshots/ — where the filename IS the SHA-256) are identical on
/mnt/wd8, and config + keys/* hash-match. All three pass check --read-data-subset 5%.

The drive is shelved, not wiped. dockA0 is LENT to the offsite seed drive;
the ST1000LM024 moves off the NS1066 bridge into it once the seed travels.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

## Task 2: Buy and accept the 8 TB drive

This is the same physical drive that will live inside the village box. It is
seeded in Almaty and carried; there is no separate "travel drive".

**Buy with weeks of margin.** The identity gate runs on the shop's return-window
clock and must happen the hour the drive is unpacked. The surface gate is
multiple days.

**Files:**
- Uses: `hosts/latitude/debian/disk-acceptance.sh`

- [ ] **Step 1: Photograph before first power-on**

Box label, drive label, invoice serial. The 2026-07-30 fraud was a label that
disagreed with the platter, and a return claim needs both sides.

- [ ] **Step 2: Identity gate — the hour it is unpacked**

Plug into dockA0 (`u4-1:0`, freed by Task 1).

```bash
ssh latitude.gg.ez 'export PATH=/usr/sbin:/sbin:/usr/bin:/bin; ls -l /dev/disk/by-id/ | grep -i ata-'
ssh latitude.gg.ez 'cd ~/machines/hosts/latitude/debian && sudo ./disk-acceptance.sh identity \
  /dev/disk/by-id/ata-<MODEL>_<SERIAL> --serial <SERIAL> --model <MODEL> --wwn <WWN>'
```

Expected: verdict `NEW` — power-on hours ≤ 10, start/stop cycles ≤ 50, capacity
exactly 8001563222016 bytes. Anything else is `RETURN`, today, before any
burn-in.

Then verify CMR vs SMR **against the vendor's own CMR/SMR table** for the exact
part number the identity phase printed. No SMART field reports it and no write
pass discriminates device-managed SMR. Never from recall.

- [ ] **Step 3: Surface gate — detached, multiple days**

```bash
ssh latitude.gg.ez 'cd ~/machines/hosts/latitude/debian && sudo ./disk-acceptance.sh surface \
  /dev/disk/by-id/ata-<MODEL>_<SERIAL> --serial <SERIAL> -go --detach'
```

`--detach` is not optional: `badblocks` is not resumable and a dead ssh session
takes the whole pass with it. Check progress with
`journalctl -u run-*.service -f`.

- [ ] **Step 4: Verdict**

```bash
ssh latitude.gg.ez 'cd ~/machines/hosts/latitude/debian && sudo ./disk-acceptance.sh verdict \
  /dev/disk/by-id/ata-<MODEL>_<SERIAL> --serial <SERIAL>'
```

Expected: `PASS`. A `BUS` verdict means reseat and re-run — check
`journalctl -k` for usb reset/disconnect and SMART attribute 199 before
condemning the platter. A `FAIL` means return.

- [ ] **Step 5: Partition, format, mount by UUID**

```bash
ssh latitude.gg.ez 'sudo bash -s' <<'EOF'
set -eu
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
DEV=/dev/disk/by-id/ata-<MODEL>_<SERIAL>
sgdisk --zap-all "$DEV"
sgdisk -n1:0:0 -t1:8300 -c1:vault "$DEV"
udevadm settle
mkfs.ext4 -L vault -m 0 "${DEV}-part1"
UUID=$(blkid -s UUID -o value "${DEV}-part1"); echo "UUID=$UUID"
mkdir -p /mnt/vault
echo "UUID=$UUID /mnt/vault ext4 defaults,nofail,x-systemd.device-timeout=30 0 2" >> /etc/fstab
findmnt --verify
systemctl daemon-reload && mount /mnt/vault
df -h /mnt/vault
EOF
```

`-m 0` because no root-reserved blocks are wanted on a data-only disk: that is
400 GB on 8 TB.

- [ ] **Step 6: Commit the acceptance record**

```bash
cd ~/machines
git add hosts/latitude/debian/   # only if the acceptance script needed a fix
git commit --allow-empty -m "offsite: 8 TB drive accepted — identity NEW, surface PASS

Model <MODEL>, serial <SERIAL>, UUID <UUID>, CMR confirmed against <vendor table URL>.
Mounted /mnt/vault on latitude for seeding; becomes the village box's internal disk.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Phase 1 — Photos into restic, on the drive that travels

## Task 3: The keyless integrity sweep

Written first because Task 4's baseline uses it, and because it is the tool that
keeps the encryption password out of the village.

**Files:**
- Create: `hosts/latitude/debian/restic-pack-verify.sh`
- Test: `provision/tests/backup-offsite.test.sh`

**Interfaces:**
- Produces: `restic-pack-verify.sh <repo-dir> [--baseline <file>]` → prints one
  line per bad file to stdout, writes a summary line
  `files=<n> bad=<n> bytes=<n> secs=<n>` to stdout, exits **0** clean, **1** on
  a hash mismatch, **2** on a usage/precondition error (repo not found, not a
  restic repo). Sourceable: `RESTIC_PACK_VERIFY_LIB_ONLY=1` defines the pure
  helpers without running.
- Pure helpers later tasks consume: `rpv_is_content_addressed <relpath>` →
  `yes`/`no`; `rpv_check_line <relpath> <sha>` → empty if the name matches the
  hash, else a `BAD <relpath>` line.

- [ ] **Step 1: Write the failing test**

Append to a new `provision/tests/backup-offsite.test.sh`:

```bash
#!/usr/bin/env bash
# provision/tests/backup-offsite.test.sh — the offsite site's pure helpers.
#
# No disks, no network: every judgement here is a function of its arguments, so
# the severity policy and the content-addressing rule are testable on any box.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAIL=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (want '$2', got '$1')"; fi; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2' in '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail "$3 (unexpected '$2')" ;; *) pass "$3" ;; esac; }

export RESTIC_PACK_VERIFY_LIB_ONLY=1
# shellcheck source=hosts/latitude/debian/restic-pack-verify.sh
source "$REPO/hosts/latitude/debian/restic-pack-verify.sh"

# ── rpv_is_content_addressed ──────────────────────────────────────────────────
# The whole keyless design rests on this split. data/, index/ and snapshots/ are
# named by the SHA-256 of their own stored bytes; config and keys/* are not, and
# hashing them against their names would report every healthy repo as corrupt.
eq "$(rpv_is_content_addressed data/8a/8a1f4cce)" yes 'data/ is content-addressed'
eq "$(rpv_is_content_addressed index/ab12)"       yes 'index/ is content-addressed'
eq "$(rpv_is_content_addressed snapshots/cd34)"   yes 'snapshots/ is content-addressed'
eq "$(rpv_is_content_addressed config)"           no  'config is NOT content-addressed'
eq "$(rpv_is_content_addressed keys/ef56)"        no  'keys/ is NOT content-addressed'
eq "$(rpv_is_content_addressed locks/aa)"         no  'locks/ is NOT content-addressed'

# ── rpv_check_line ────────────────────────────────────────────────────────────
# The name is the hash, so a match is silence and a mismatch names the file. The
# comparison is on the BASENAME: data files sit one directory deep under a
# two-hex-char prefix, and comparing the whole relative path would never match.
eq "$(rpv_check_line data/8a/8a1f4ccec0325b33 8a1f4ccec0325b33)" '' \
  'a pack whose name equals its hash is silent'
has "$(rpv_check_line data/8a/8a1f4ccec0325b33 deadbeefdeadbeef)" 'BAD data/8a/8a1f4ccec0325b33' \
  'a pack whose bytes changed is named'

# Every suite in this repo prints ALL PASS and exits nonzero on failure — that is
# what `just test` reads. Keep this block LAST in the file; later tasks append
# above it.
[ "$FAIL" -eq 0 ] && echo "ALL PASS" || echo "$FAIL FAILED" >&2
exit $((FAIL > 0))
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash provision/tests/backup-offsite.test.sh`
Expected: FAIL — `No such file or directory` for the sourced script.

- [ ] **Step 3: Write the implementation**

Create `hosts/latitude/debian/restic-pack-verify.sh`:

```bash
#!/usr/bin/env bash
# restic-pack-verify.sh — prove a restic repository's bytes are intact, with NO
# password and NO restic binary.
#
# WHY THIS EXISTS AND WHAT IT REPLACES. The offsite box must be able to catch
# bitrot on its own disk. The obvious tool, `restic check --read-data`, needs the
# repository password — which would put the key next to the ciphertext in a house
# nobody occupies, so a stolen box would hand over every photo. It also needs to
# read the data, and doing that from Almaty over a residential uplink means
# pulling 5% of a terabyte on every run.
#
# It is unnecessary. MEASURED ON LATITUDE 2026-09-12: a restic pack file's NAME
# is the SHA-256 of its own stored bytes.
#
#   /mnt/wd8/restic/latitude/data/8a/8a1f4ccec0325b33172aa7b558604f4b8e5990f6c87c7cce88bf9f8b5030cc75
#   sha256sum                        8a1f4ccec0325b33172aa7b558604f4b8e5990f6c87c7cce88bf9f8b5030cc75
#
# So hashing every file under data/, index/ and snapshots/ and comparing with its
# own name is a 100% read-data check that needs no key at all — stronger coverage
# than `--read-data-subset 5%`, on a box that holds nothing but ciphertext.
#
# WHAT IT DOES NOT COVER, and nobody should later claim it did:
#   * That blobs DECRYPT. A pack can be byte-perfect and the key wrong.
#   * That the index agrees with the packs, or that a snapshot's tree resolves.
# Those are structural, they live in metadata, and metadata is small — so they
# are checked from Almaty with a keyed, metadata-only `restic check` over the
# link. The split is deliberate: bytes here, structure there, and neither end can
# hide the other's failure.
#
#   ./restic-pack-verify.sh /mnt/vault/restic/latitude
#   ./restic-pack-verify.sh /mnt/vault/restic/latitude --baseline /var/lib/offsite/baseline.sha
#
# EXIT: 0 clean · 1 a hash mismatch · 2 usage or precondition (not a repo).
# Distinct on purpose — see AGENTS.md, two failures must not share one status.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

# ── pure helpers (unit-tested by provision/tests/backup-offsite.test.sh) ──────

# Is this relative path named by the hash of its own contents?
rpv_is_content_addressed() {
    case "$1" in data/* | index/* | snapshots/*) echo yes ;; *) echo no ;; esac
}

# Empty when the basename equals the hash; a BAD line naming the file otherwise.
rpv_check_line() {
    local rel="$1" sha="$2"
    [ "${rel##*/}" = "$sha" ] || printf 'BAD %s\n' "$rel"
}

# ── main ─────────────────────────────────────────────────────────────────────

rpv_main() {
    local repo="${1:-}" baseline="" rel sha files=0 bad=0 bytes=0 t0
    [ -n "$repo" ] || { echo "usage: $0 <repo-dir> [--baseline <file>]" >&2; return 2; }
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --baseline) baseline="${2:-}"; shift 2 ;;
            *) echo "unknown argument: $1" >&2; return 2 ;;
        esac
    done
    # A missing drive leaves an ordinary empty directory under a `nofail` mount,
    # so "the path exists" proves nothing. Test the repo's own config object.
    [ -f "$repo/config" ] || { echo "not a restic repository: $repo" >&2; return 2; }

    t0=$SECONDS
    while IFS= read -r rel; do
        [ "$(rpv_is_content_addressed "$rel")" = yes ] || continue
        files=$((files + 1))
        bytes=$((bytes + $(stat -c %s "$repo/$rel")))
        sha="$(sha256sum "$repo/$rel" | cut -d' ' -f1)"
        if [ -n "$(rpv_check_line "$rel" "$sha")" ]; then
            bad=$((bad + 1)); rpv_check_line "$rel" "$sha"
        fi
    done < <(cd "$repo" && find data index snapshots -type f 2>/dev/null | sort)

    # config and keys/* are NOT content-addressed, so they are compared against a
    # recorded baseline instead of against their own names. Without a baseline
    # they are reported and not judged — silence would read as "verified".
    if [ -n "$baseline" ] && [ -f "$baseline" ]; then
        while read -r want rel; do
            sha="$(sha256sum "$repo/$rel" 2>/dev/null | cut -d' ' -f1)"
            [ "$sha" = "$want" ] || { bad=$((bad + 1)); printf 'BAD %s (baseline)\n' "$rel"; }
        done < "$baseline"
    else
        printf 'NOTE config and keys/* not judged (no --baseline)\n'
    fi

    printf 'files=%s bad=%s bytes=%s secs=%s\n' "$files" "$bad" "$bytes" "$((SECONDS - t0))"
    [ "$bad" -eq 0 ]
}

# Sourceable: the suite sources this file to drive the pure helpers above.
[ -n "${RESTIC_PACK_VERIFY_LIB_ONLY:-}" ] || { rpv_main "$@"; exit $?; }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash provision/tests/backup-offsite.test.sh`
Expected: `PASS` on all eight assertions.

- [ ] **Step 5: Prove it against a real repository**

```bash
ssh latitude.gg.ez 'cd ~/machines && sudo bash hosts/latitude/debian/restic-pack-verify.sh /mnt/wd8/restic/latitude'
```

Expected: `files=<n> bad=0 …`, exit 0. A nonzero `bad` on latitude's own repo
that `restic check` calls healthy would mean the content-addressing premise is
wrong — stop and re-measure before going further.

- [ ] **Step 6: Commit**

```bash
git add hosts/latitude/debian/restic-pack-verify.sh provision/tests/backup-offsite.test.sh
git commit -m "backup: keyless integrity sweep for a restic repository

A pack file's name IS the SHA-256 of its stored bytes (measured on latitude
2026-09-12), so hashing data/, index/ and snapshots/ against their own names is
a 100% read-data check with no password. That is what keeps the encryption key
off the offsite box: it can prove its bytes while holding only ciphertext.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

## Task 4: The `photos` profile and the seed backup

**Files:**
- Modify: `backup/latitude/profiles.yaml`
- Create: `backup/latitude/pass-photos.txt` (symlink, gitignored)

- [ ] **Step 1: Create the password and escrow it**

The password is generated once and stored on **latitude's dotfiles branch
only**. It is never copied to the village box.

```bash
ssh latitude.gg.ez 'bash -s' <<'EOF'
set -eu
umask 077
test -f ~/.config/restic/photos.pass.txt && { echo "exists — do NOT regenerate"; exit 1; }
mkdir -p ~/.config/restic
head -c 32 /dev/urandom | base64 > ~/.config/restic/photos.pass.txt
chmod 600 ~/.config/restic/photos.pass.txt
ln -sfn ~/.config/restic/photos.pass.txt ~/machines/backup/latitude/pass-photos.txt
git --git-dir=$HOME/.dotfiles --work-tree=$HOME check-ignore -v ~/.config/restic/photos.pass.txt
EOF
```

**Never regenerate this file** once the repository exists — it is the last copy
of a secret, and losing it makes the whole offsite repository unreadable. Track
it on latitude's branch the same way `g614jv.pass.txt` is tracked (an allow-line
in `~/.gitignore` plus an explicit `dotfiles add`), after confirming
`check-ignore` does not put it under the key-material deny block.

- [ ] **Step 2: Add the profile**

Append to `backup/latitude/profiles.yaml`:

```yaml
# The photo libraries, and this is the change the offsite site is built on.
#
# THE CONSTRAINT THAT BLOCKED THIS IS DEAD. The header of this file still says
# "there is no drive left in the fleet with 815 G free for a restic repo" — true
# when it was written, false since /mnt/wd8 arrived with 6.4 T free. The mirrors
# stay: a mirror is directly BROWSABLE and a repo needs a restore, so local
# recovery stays fast. This is additive.
#
# A SEPARATE REPOSITORY FROM `latitude`, deliberately. Merging would make the
# Sunday `check --read-data-subset 5%` and the prune on the 12 G critical set
# cost roughly 80x what they cost now — the small irreplaceable set would be
# hostage to a terabyte of photos on every maintenance run.
#
# THE REPOSITORY PATH BELOW IS TEMPORARY. /mnt/vault is the drive that travels;
# once it is installed in the village box this becomes
# `rest:http://offsite.gg.ez:8001/latitude/`. There is no `restic copy` and no
# second local repo: seeding IS the first backup, and the drive carries it.
#
# 663 of the 956 GB is the closed 1970-2024 archive. It packs once, travels once,
# and never uploads again — which is the whole reason a residential uplink is
# enough. Steady state is only new photos.
photos:
  inherit: base-job
  # Explicit, for the reason base.yaml spells out: a global `initialize` can
  # never be switched off by a profile. True here because the repository has to
  # be creatable on the seed drive; the run-before below is what stops it firing
  # against an empty mountpoint.
  initialize: true

  # MOUNT ASSERTION. /mnt/vault is `nofail`, so when the drive is absent the
  # mountpoint is an ordinary empty directory and every path under it still
  # "exists". Testing the repo's own config object covers drive-absent and
  # repo-absent in one check.
  #
  # WHEN THIS PROFILE MOVES TO rest:, REPLACE THIS LINE — a `test -f` against a
  # URL is meaningless. The equivalent there is a reachability probe; see the
  # cutover task in docs/superpowers/plans/2026-09-12-village-offsite-backup.md.
  run-before:
    - test -f /mnt/vault/restic/latitude/config

  repository: "/mnt/vault/restic/latitude"
  password-file: "/home/me/machines/backup/latitude/pass-photos.txt"
  env:
    RESTIC_PASSWORD_FILE: "/home/me/machines/backup/latitude/pass-photos.txt"
  # OFF, unlike the `latitude` profile above. JPEG, HEIC and H.264 do not
  # compress, so this would spend CPU on a terabyte for nothing.
  compression: off

  backup:
    # HERE, not at profile level — at profile level resticprofile 0.33.1 parses
    # it, echoes it back from `show`, and never runs it.
    #
    # NOTE WHAT IT INHERITS: it is built from the `check:` section below, so it
    # picks up read-data-subset. 0.1% is deliberate and is NOT the 5% the other
    # profiles use — 5% of a terabyte every night is 50 GB of reads, and after
    # the cutover it would be 50 GB pulled over a residential uplink. The weekly
    # check below is where real coverage lives.
    check-before: true
    source:
      - "/mnt/immich"
      - "/mnt/immich-2024"
    exclude:
      # LIVE PGDATA — COPY THE PATH FROM mirror-refresh.sh, DO NOT RETYPE IT FROM
      # HERE. An rsync or a restic walk of a running postgres directory is a torn
      # copy that LOOKS like a backup, which is why that script excludes it; this
      # profile walks the same filesystem and needs the identical exclusion.
      # Step 2a below reads the live list. The database itself is covered by
      # immich's own nightly pg_dumpall, which the `latitude` profile backs up.
      - "<the PGDATA exclude, verbatim from mirror-refresh.sh>"
      - "/mnt/immich/ServarrConfig/"   # already in the `latitude` profile
      - "/mnt/immich/xs-keepers/"      # already in the `latitude` profile
      - "**/.DS_Store"
      - "**/*.tmp"
    exclude-caches: true
    # System scope: /mnt/immich is container-owned and a user unit would read
    # some of it today by luck of the 644 bits.
    schedule: "02:00"
    schedule-permission: system
    # 02:00 is the only hour clear of the /mnt/wd8 ledger — 03:30 mirror-refresh,
    # 04:30 latitude, 05:00 g15, 06:00 desktop-wsl, 07:30 and 09:30 the forgets.
    # It is also BEFORE the mirror walks the same filesystem.
    #
    # OVERRIDES base.yaml, for the reason the `latitude` profile states: this box
    # never sleeps, so "on battery" means the power went out, and the default
    # skip exits 0 — reporting success for a night that produced nothing.
    schedule-ignore-on-battery: false

  retention:
    # Photos are not documents: an old version is not superseded, it is a
    # different photo. The long tail is the point, and the payload is 663 GB of
    # frozen archive that dedupes to nothing on every snapshot after the first.
    #
    # AFTER THE CUTOVER THIS BECOMES INERT. The offsite server runs
    # --append-only, so every DELETE but a lock gets 403 — and with
    # `after-backup: true` that 403 would fail the whole run. Turn it off in the
    # same edit that re-points the repository; see the cutover task.
    before-backup: false
    after-backup: true
    keep-daily: 14
    keep-weekly: 12
    keep-monthly: 24
    keep-yearly: 20
    prune: true

  check:
    # SUNDAY 12:00, after g513ie's check at 10:30 — `restic check` takes an
    # EXCLUSIVE lock and this is a different repository, but it is the same
    # physical drive while seeding, and a terabyte-scale check contending with a
    # prune is how a prune waits out its 10m and then fails.
    schedule: "Sun 12:00"
    schedule-permission: system
    read-data-subset: 0.1%
    schedule-ignore-on-battery: false
```

- [ ] **Step 2a: Read the live exclude list and paste it in**

```bash
ssh latitude.gg.ez 'grep -n "exclude\|EXCLUDE" ~/machines/hosts/latitude/debian/mirror-refresh.sh'
```

Replace the `<the PGDATA exclude, verbatim from mirror-refresh.sh>` placeholder
with what that prints. **This step is not optional and the placeholder must not
survive it** — backing up a live postgres data directory produces a torn copy
that restores as a corrupt database while every report says the backup succeeded.

- [ ] **Step 3: Verify resticprofile parses it and the schedule is what it says**

```bash
ssh latitude.gg.ez 'cd ~/machines/backup/latitude && resticprofile -n photos show'
```

Expected: `repository: /mnt/vault/restic/latitude`, and `check-before: true`
appearing **under** `backup`, not beside it. If it shows at profile level it is
inert — that is the failure this repo has already measured.

- [ ] **Step 4: Seed — the first full backup**

```bash
ssh latitude.gg.ez 'cd ~/machines/backup/latitude && sudo -E resticprofile -n photos backup' \
  2>&1 | tee /tmp/photos-seed.log
```

Expect hours, not minutes. ~956 GB from an NVMe and a USB-2-linked disk to a
5 Gbps dock bay. Record the wall-clock time and the resulting repository size in
the commit message — it is the number every later capacity question needs.

- [ ] **Step 5: Baseline check AT THE SOURCE, before travel**

```bash
ssh latitude.gg.ez 'cd ~/machines/backup/latitude && sudo -E resticprofile -n photos check --read-data'
ssh latitude.gg.ez 'cd ~/machines && sudo bash hosts/latitude/debian/restic-pack-verify.sh /mnt/vault/restic/latitude'
# Record the baseline for the two files the sweep cannot judge by name:
ssh latitude.gg.ez 'sudo bash -c "cd /mnt/vault/restic/latitude && \
  sha256sum config keys/* > /var/tmp/offsite-baseline.sha && cat /var/tmp/offsite-baseline.sha"'
```

A full `--read-data` here, not a subset: this is the one time the repository and
the source are on the same desk. A failed check at the destination with no
baseline at the source is unexplainable — you cannot tell a bad drive from a bad
journey.

- [ ] **Step 6: Commit**

```bash
git add backup/latitude/profiles.yaml
git commit -m "backup/latitude: photo libraries into restic (seed on /mnt/vault)

956 GB, separate repo from the 12 GB critical set (merging would cost ~80x on
every check and prune). The 'no drive has 815 G free' constraint died with
/mnt/wd8's 6.4 T. Mirrors stay — a mirror is browsable, a repo needs a restore.

Seed: <N>h wall clock, repo <N> GB. Full --read-data check clean at the source.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Phase 2 — Visibility (independently shippable)

This phase closes the deferred backup-report item in `docs/fleet-roadmap.md`
P0 rather than opening a parallel one, and it is useful to the fleet today even
if the trip slips. Its design is lifted from the roadmap's own worked answer at
lines 68–82, not re-derived.

## Task 5: The collector

**Files:**
- Create: `hosts/latitude/debian/backup-status.sh`
- Create: `provision/statusboard/backup-jobs.latitude5520.conf`
- Test: `provision/tests/backup-offsite.test.sh` (append)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `backup-status.sh [--json]` → writes
  `/var/lib/fleet-backup/rows` and echoes the same rows. One row per job:
  `name|age_secs|period_secs|state|detail`, `state` ∈ `ok|late|stale|bad|unknown`.
  Pure helpers: `bs_age_state <age> <period>` → `ok|late|stale`;
  `bs_newest_mtime <dir>` → epoch seconds or empty.

- [ ] **Step 1: Write the failing test**

Append to `provision/tests/backup-offsite.test.sh`:

```bash
# ── bs_age_state ──────────────────────────────────────────────────────────────
# The severity policy is keyed on each job's DECLARED expected period, not on
# observed periodicity. That is what keeps Debian's nine housekeeping timers off
# the page while catching the four that matter — and it is the only rule that
# makes "late" mean anything for a job that runs weekly.
export BACKUP_STATUS_LIB_ONLY=1
# shellcheck source=hosts/latitude/debian/backup-status.sh
source "$REPO/hosts/latitude/debian/backup-status.sh"

eq "$(bs_age_state 3600 86400)"   ok    'fresh: an hour into a daily job is ok'
eq "$(bs_age_state 86399 86400)"  ok    'fresh: one second inside the period is still ok'
eq "$(bs_age_state 90000 86400)"  late  'late: one missed daily run is late'
eq "$(bs_age_state 172801 86400)" stale 'stale: two missed daily runs is stale'
eq "$(bs_age_state 600000 604800)" ok   'period is per-job: a week-old weekly job is ok'
eq "$(bs_age_state '' 86400)"     unknown 'no age at all is unknown, not ok'
eq "$(bs_age_state abc 86400)"    unknown 'a non-numeric age is unknown, not ok'
```

Append **above** the `ALL PASS` block written in Task 3 Step 1, not after it.

- [ ] **Step 2: Run it to verify it fails**

Run: `bash provision/tests/backup-offsite.test.sh`
Expected: FAIL — `bs_age_state: command not found`.

- [ ] **Step 3: Write the implementation**

Create `hosts/latitude/debian/backup-status.sh`:

```bash
#!/usr/bin/env bash
# backup-status.sh — one row per backup job, for the status board and for agents.
#
# THE ENABLING TRICK, and it is what makes this cheap enough to run every 15
# minutes: a restic repository's newest snapshot age is readable from
# <repo>/snapshots/ FILE MTIMES. No restic binary, no password, no repository
# lock. latitude is the hub, so it can see every pusher's repo — its own,
# desktop-wsl's and g15's — from the filesystem.
#
# WHY IT IS A SEPARATE SCRIPT FROM THE BOARD. The board repaints every second and
# this walks four directories; and an agent, a timer or a human at a terminal all
# want the same rows. One implementation of "is the backup fresh", not two that
# drift — the same argument role_backup_hub makes for the hub selfcheck.
#
# SEVERITY IS KEYED ON A DECLARED PERIOD, NOT ON PERIODICITY. Observed
# periodicity would put Debian's nine housekeeping timers on the page and would
# have nothing to say about a weekly job. Each job declares what it promises in
# provision/statusboard/backup-jobs.<hostname>.conf; missing it once is `late`,
# twice is `stale`.
#
# AND SNAPSHOT AGE IS A CLIENT-LIVENESS SIGNAL TOO. A repo goes stale when the
# repo is broken AND when the box that writes to it is merely switched off. The
# hub selfcheck's check 8 has exactly this property and is documented as unusable
# as a sentinel for that reason. It is kept here anyway because for the OFFSITE
# job the confound is the point — an offsite copy that has stopped receiving is a
# problem whichever end caused it — and because the offsite row is corroborated
# by the box's own pushed status (see the `offsite` job below).
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

STATE_DIR=${BACKUP_STATUS_STATE_DIR:-/var/lib/fleet-backup}
JOBS_CONF=${BACKUP_STATUS_JOBS:-}

# ── pure helpers (unit-tested by provision/tests/backup-offsite.test.sh) ──────

# ok | late | stale | unknown, from an age in seconds and a declared period.
# One missed run is `late` (a warning); two is `stale` (a failure). An age that
# cannot be read is `unknown` — NOT ok, because silence is the failure mode this
# whole script exists to catch.
bs_age_state() {
    local age="${1:-}" period="${2:-}"
    case "$age" in '' | *[!0-9]*) echo unknown; return ;; esac
    case "$period" in '' | *[!0-9]*) echo unknown; return ;; esac
    if [ "$age" -le "$period" ]; then echo ok
    elif [ "$age" -le $((period * 2)) ]; then echo late
    else echo stale; fi
}

# Newest mtime under a directory, epoch seconds. Empty if unreadable or empty —
# an empty snapshots/ dir is a repository that has never received anything, which
# must not read as "age 0, fresh".
bs_newest_mtime() {
    local dir="${1:-}" newest
    [ -d "$dir" ] || return 0
    newest="$(find "$dir" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
    [ -n "$newest" ] || return 0
    printf '%.0f\n' "$newest"
}

# ── main ─────────────────────────────────────────────────────────────────────

bs_main() {
    local json=0 now name path period kind mtime age state detail rows=""
    [ "${1:-}" = "--json" ] && json=1
    now="$(date +%s)"

    if [ -z "$JOBS_CONF" ]; then
        JOBS_CONF="$(dirname "${BASH_SOURCE[0]}")/../../../provision/statusboard/backup-jobs.$(hostname -s).conf"
    fi
    [ -f "$JOBS_CONF" ] || { echo "no jobs conf: $JOBS_CONF" >&2; return 2; }

    while read -r kind name path period; do
        case "$kind" in '' | \#*) continue ;; esac
        detail=""
        case "$kind" in
            repo)
                # A `nofail` mount that is absent leaves an empty directory, so
                # the repo's own config object is the existence test, not the path.
                if [ ! -f "$path/config" ]; then
                    state=bad; age=""; detail="repo missing"
                else
                    mtime="$(bs_newest_mtime "$path/snapshots")"
                    if [ -z "$mtime" ]; then
                        state=bad; age=""; detail="no snapshots"
                    else
                        age=$((now - mtime)); state="$(bs_age_state "$age" "$period")"
                    fi
                fi
                ;;
            status)
                # A status file PULLED from another box. Its own freshness is the
                # liveness signal for that box, and its contents are the verdict —
                # two distinct conditions on one file, so "check failed" stays
                # distinguishable from "link down".
                if [ ! -f "$path" ]; then
                    state=bad; age=""; detail="no status"
                else
                    mtime="$(stat -c %Y "$path")"; age=$((now - mtime))
                    state="$(bs_age_state "$age" "$period")"
                    if [ "$state" = ok ] &&
                       ! grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$path"; then
                        state=bad
                        detail="$(sed -n 's/.*"detail"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$path" | head -1)"
                        [ -n "$detail" ] || detail="reported not ok"
                    fi
                fi
                ;;
            *) state=unknown; age=""; detail="unknown kind '$kind'" ;;
        esac
        rows="$rows$name|${age:-}|$period|$state|$detail
"
    done < "$JOBS_CONF"

    mkdir -p "$STATE_DIR"
    printf '%s' "$rows" > "$STATE_DIR/rows"
    if [ "$json" = 1 ]; then
        printf '%s' "$rows" | awk -F'|' 'BEGIN { print "[" ; sep="" }
            NF { printf "%s  {\"name\":\"%s\",\"age\":\"%s\",\"period\":%s,\"state\":\"%s\",\"detail\":\"%s\"}\n", sep, $1, $2, $3, $4, $5; sep="," }
            END { print "]" }'
    else
        printf '%s' "$rows"
    fi
    return 0
}

[ -n "${BACKUP_STATUS_LIB_ONLY:-}" ] || { bs_main "$@"; exit $?; }
```

- [ ] **Step 4: Write the jobs conf**

Create `provision/statusboard/backup-jobs.latitude5520.conf`:

```
# provision/statusboard/backup-jobs.latitude5520.conf — what each backup job PROMISES.
#
# Read by hosts/latitude/debian/backup-status.sh, found by OS hostname
# (BACKUP_STATUS_JOBS overrides). Severity is keyed on the declared period here,
# never on observed periodicity: observed periodicity would put Debian's nine
# housekeeping timers on the page and would have nothing to say about a weekly
# job. Missing the period once is `late`; twice is `stale`.
#
#   repo   <name> <repo-dir>     <period-seconds>
#   status <name> <status-file>  <period-seconds>
#
# A `repo` row reads the newest mtime under <repo-dir>/snapshots — no restic
# binary, no password, no lock. A `status` row reads a file pulled from another
# box: its own mtime is that box's liveness, its contents are that box's verdict.
#
# 86400 is one day. These are the schedules declared in backup/latitude/profiles.yaml
# and the clients' own profiles — if a schedule moves, move the number here too or
# the board will be confidently wrong.

repo   latitude    /mnt/wd8/restic/latitude          86400
repo   photos      /mnt/vault/restic/latitude        86400
repo   g614jv      /mnt/wd8/restic-rest/g614jv       86400
repo   g513ie      /mnt/wd8/restic-rest/g513ie       86400

# Added by the cutover task, once the village box exists. Period 7200, not 86400:
# the box pushes its own health hourly, so two missed pushes is a real signal
# about the box rather than about the backup schedule.
# status offsite  /var/lib/fleet-backup/offsite.json  7200
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash provision/tests/backup-offsite.test.sh`
Expected: all `PASS`.

- [ ] **Step 6: Run it for real on latitude**

```bash
ssh latitude.gg.ez 'cd ~/machines && sudo bash hosts/latitude/debian/backup-status.sh'
```

Expected: four rows, all `ok`. Then break one deliberately and confirm the row
moves — `sudo touch -d '3 days ago' /mnt/wd8/restic-rest/g614jv/snapshots/*` on a
copy, never on the live repo; or point `BACKUP_STATUS_JOBS` at a fixture conf
naming a nonexistent path and confirm the row reads `bad|repo missing`.

- [ ] **Step 7: Install the timer**

Create `hosts/latitude/debian/systemd/backup-status.service`:

```ini
[Unit]
Description=Collect fleet backup freshness rows
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/home/me/machines/hosts/latitude/debian/backup-status.sh
```

and `backup-status.timer`:

```ini
[Unit]
Description=Collect fleet backup freshness rows every 15 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
```

Add `backup-status` to the unit list in
`hosts/latitude/debian/install-timers.sh` (it **copies** units into
`/etc/systemd/system` rather than symlinking, so a `git pull` cannot change what
root runs on a timer), then:

```bash
ssh latitude.gg.ez 'cd ~/machines/hosts/latitude/debian && sudo ./install-timers.sh'
ssh latitude.gg.ez 'sudo systemctl start backup-status.service && systemctl show -p Result backup-status.service'
```

Expected: `Result=success`. **Verify by firing the schedule, not by running the
script** — `mirror-refresh.sh` passed by hand for weeks while every timer run
reported `Failed`.

- [ ] **Step 8: Commit**

```bash
git add hosts/latitude/debian/backup-status.sh hosts/latitude/debian/systemd/backup-status.* \
        hosts/latitude/debian/install-timers.sh provision/statusboard/backup-jobs.latitude5520.conf \
        provision/tests/backup-offsite.test.sh
git commit -m "latitude: collect backup freshness rows on a timer

Newest snapshot age from <repo>/snapshots mtimes — no restic binary, no
password, no lock. Severity keyed on each job's DECLARED period, which is what
keeps the housekeeping timers off the page and gives a weekly job a meaning for
'late'. Closes the enabling half of the deferred roadmap P0 backup report.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

## Task 6: `sb_backup_alerts` on the status board

**Files:**
- Modify: `provision/statusboard/statusboard.sh`
- Modify: `provision/tests/statusboard.test.sh`

**Interfaces:**
- Consumes: the rows written by `backup-status.sh` (Task 5).
- Produces: `sb_backup_alerts <rows>` → zero or more `bad:`/`warn:` lines on
  stdout, exit 0. Sets `SB_BACKUP` in `sb_sample_slow`.

- [ ] **Step 1: Write the failing test**

Append to `provision/tests/statusboard.test.sh`, immediately after the
`sb_docker_alerts` fixtures at line 1052, in the same idiom:

```bash
# ── Severity policy (sb_backup_alerts) ────────────────────────────────────────
# Takes one argument for the same reason the two above do: this is a judgement
# about what is worth waking someone for, and a judgement that reads a dozen
# globals cannot be tested.
#
# `stale` outranks `late` the way `missing` outranks `offline` on the fleet
# strip: one missed run is a schedule that slipped, two is a backup that has
# stopped. `bad` is the repo itself — gone, empty, or a box reporting a failed
# integrity sweep — and that never degrades to a warning.
BA="$(sb_backup_alerts "$(printf '%s\n' \
  'latitude|3600|86400|ok|' \
  'photos|90000|86400|late|' \
  'g614jv|200000|86400|stale|' \
  'g513ie||86400|bad|no snapshots' \
  'offsite|1800|7200|bad|sweep found 3 bad packs')")"
has "$BA" 'warn:photos late'                     'severity: one missed run is a warning'
has "$BA" 'bad:g614jv stale'                     'severity: two missed runs is a failure'
has "$BA" 'bad:g513ie no snapshots'              'severity: an empty repo is bad, with its reason'
has "$BA" 'bad:offsite sweep found 3 bad packs'  'severity: a fresh row can still be bad'
hasnt "$BA" 'latitude'                           'severity: a fresh backup is not an alert'
eq "$(sb_backup_alerts '')" ''                   'severity: no backup rows, no alerts'
# An unreadable age must not read as healthy: silence is the failure this catches.
has "$(sb_backup_alerts 'x||86400|unknown|')" 'warn:x age unknown' \
  'severity: an unreadable age is a warning, never silence'
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash provision/tests/statusboard.test.sh`
Expected: FAIL — `sb_backup_alerts: command not found`.

- [ ] **Step 3: Add the pure function**

Insert into `provision/statusboard/statusboard.sh` immediately after
`sb_docker_alerts` (it ends at line 1473, before `sb_alert_line` at 1476), so
the three severity policies sit together:

```bash
# sb_backup_alerts <backup-rows>: an offsite copy nobody verifies is a BELIEF in a
# second copy. These rows come from backup-status.sh, which reads snapshot-dir
# mtimes and the status file the offsite box pushes.
#
# `stale` outranks `late` exactly as `missing` outranks `offline` on the fleet
# strip: one missed run is a schedule that slipped, two is a backup that has
# stopped. `bad` is the repository itself and never degrades to a warning.
#
# `unknown` is a WARNING, never silence. The failure this whole feature exists to
# catch is a job that quietly stopped — the `server` immich tasks reported
# `State: Ready` while every run failed for 13 days — so an age that cannot be
# read must reach the strip.
sb_backup_alerts() {
  local name age period state detail
  while IFS='|' read -r name age period state detail; do
    [ -n "$name" ] || continue
    case "$state" in
      bad)   printf 'bad:%s %s\n' "$name" "${detail:-failed}" ;;
      stale) printf 'bad:%s stale%s\n' "$name" "$(sb_dur_short "$age")" ;;
      late)  printf 'warn:%s late%s\n' "$name" "$(sb_dur_short "$age")" ;;
      unknown) printf 'warn:%s age unknown\n' "$name" ;;
    esac
  done <<< "${1:-}"
  return 0
}

# sb_dur_short <secs>: " 3d" / " 5h" / "" — a leading space so the caller can
# concatenate it unconditionally, the way sb_fleet_alerts does with ${age:+ $age}.
sb_dur_short() {
  case "${1:-}" in '' | *[!0-9]*) return 0 ;; esac
  if [ "$1" -ge 86400 ]; then printf ' %sd' $(($1 / 86400))
  elif [ "$1" -ge 3600 ]; then printf ' %sh' $(($1 / 3600))
  else printf ' %sm' $(($1 / 60)); fi
}
```

- [ ] **Step 4: Read the rows in the slow sampler**

In `sb_sample_slow`, immediately after the `SB_FAILED="$(systemctl --failed …)"`
line (~line 2280):

```bash
  # Backup freshness. A FILE READ, not a walk: backup-status.sh does the walking
  # on its own 15-minute timer, and the board repaints every second.
  SB_BACKUP=""
  [ -r /var/lib/fleet-backup/rows ] && SB_BACKUP="$(cat /var/lib/fleet-backup/rows)"
```

Declare `SB_BACKUP` beside the other `SB_*` globals near line 2050.

- [ ] **Step 5: Call it from `sb_alerts`**

In `sb_alerts`, immediately before the docker block at the end:

```bash
  [ -n "${SB_BACKUP:-}" ] && sb_backup_alerts "$SB_BACKUP"
```

- [ ] **Step 6: Run the tests**

Run: `bash provision/tests/statusboard.test.sh`
Expected: all `PASS`, including the seven new assertions.

Run: `just test`
Expected: green, with the count `just test` prints itself — do not write it down.

- [ ] **Step 7: Commit**

```bash
git add provision/statusboard/statusboard.sh provision/tests/statusboard.test.sh
git commit -m "statusboard: sb_backup_alerts — a backup nobody verifies is a belief

Third severity policy beside sb_fleet_alerts and sb_docker_alerts, same shape:
one argument, fixture-tested. stale outranks late; an unreadable age is a
warning, never silence — the failure this catches is a job that quietly stopped.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Phase 3 — The box

## Task 7: Buy the mini-PC against the acceptance criteria

Check before buying, not after. Every item is a rejection criterion.

- [ ] **Step 1: Verify the BIOS restore-on-AC setting in the model's own manual**

The setting must be settable to **`Power On`** — not `Last State`, not absent.
Vendor names: `After Power Failure` (Intel NUC), `State After G3` / `Restore AC
Power Loss` (AMI/Insyde — Beelink, GMKtec, Trigkey, Minisforum), `AC Recovery`
(Dell), `After Power Loss` (HP/Lenovo).

**Read the manual of the specific model.** Homelab write-ups report it defaulting
to off on consumer mini-PCs and sometimes missing entirely on cheap boards; that
is not verified against a vendor manual here. This is the single setting that
makes the site self-recovering, which is the whole premise.

**Wake-on-LAN is not a requirement and does not help** — the box is always on,
and when mains drops the NIC is dead too.

- [ ] **Step 2: Check the rest**

- One internal **3.5"** bay (a 2.5" HDD caps at 2 TB, already rejected for having
  no headroom) **plus** one M.2 slot for the OS, with a second data slot free for
  later growth.
- **8 GB RAM or more.** The SHA-256 sweep and any future maintenance run here. On
  a memory-starved box the kernel OOM killer does not fire — grinding a disk
  swapfile keeps global reclaim reporting progress, so more swap buys a longer
  freeze, not more headroom. That is why `tier_oom_guard` exists.
- **Wired Ethernet.** No Wi-Fi dependency.
- Class: NAS-style mini (Aoostar / Beelink ME / CWWK / Topton), not a fanless
  N100 stick. **Fanless is off the table and that is fine** — the dust objection
  assumed a box nobody visits, and the owner visits every few months, which is
  the right interval to blow out a fan.
- **UPS is optional** given auto-power-on. Worth adding if the village turns out
  to have frequent short dips.

- [ ] **Step 3: Set the BIOS on arrival and prove it**

Set restore-on-AC to `Power On`. Then prove it, in Almaty, before it travels:
pull the plug at the wall, wait 30 s, plug it back, and confirm the box comes up
with no keypress. Do this twice. There is nobody in the village to press
anything, and a setting that reads `Power On` in a menu is not the same as a box
that boots.

## Task 8: The `backup-offsite` role executor

Lands **before** the `fleet.json` entry. Without an executor, `--apply` for a
machine declaring the role exits 1 — `backup-offsite` is not in `PLANNED_ROLES`
and must not be added to it.

**Files:**
- Create: `provision/roles/backup-offsite.sh`
- Create: `hosts/offsite/debian/install-rest-server.sh`
- Modify: `provision/tests/roles.test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `role_backup_offsite <mode> <platform> <machine>`; sourced by
  `provision.sh`, defines nothing else.

- [ ] **Step 1: Write the failing test**

Append to `provision/tests/roles.test.sh`, beside the two backup roles at line 82:

```bash
# ── backup-offsite (landed with its fleet.json entry — see the plan) ──────────
# THE ASSERTION IS THAT IT IS DEFINED. backup-offsite is NOT in PLANNED_ROLES and
# must never be added to it: the whole point of that list is to declare a gap
# loudly, and this role has an executor from the moment the manifest names it.
defined role_backup_offsite
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash provision/tests/roles.test.sh`
Expected: FAIL — `role_backup_offsite is NOT defined — provision.sh would fall
through to PLANNED_ROLES`.

- [ ] **Step 3: Write the executor**

Create `provision/roles/backup-offsite.sh`:

```bash
# provision/roles/backup-offsite.sh — the `backup-offsite` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_backup_offsite.
#
# backup-offsite = this box is a SINK. It receives other machines' backups and can
# never delete them. `offsite` is the only member carrying it.
#
# DISTINCT FROM backup-hub, and the difference is the direction of trust, not the
# software. The hub holds the fleet's repositories AND their passwords, because it
# is in the owner's own flat and it prunes them. This box is 900 km away in a house
# he does not occupy, so it holds NO password at all: it serves --append-only, it
# never prunes, and it proves its own bytes with restic-pack-verify.sh, which needs
# no key (a pack file's name IS the SHA-256 of its stored bytes). A stolen box
# yields ciphertext.
#
# IT ALSO DOES NOT CREATE REPOSITORIES, for the reason backup/base.yaml spells out:
# a role that ran `restic init` would reintroduce the silent-empty-repo failure
# that design closes.
#
# WHY THE SERVER IS NATIVE HERE AND A CONTAINER ON LATITUDE. latitude's rest-server
# is part of the cyphy.kz stack and lives in the `vps` repo — machines here,
# services there. This box has no stack; being a sink is its entire purpose, so it
# is a machine fact. It also keeps Docker off the appliance, and with it the
# bind-source race that has cost this fleet two multi-day outages: a container that
# starts before its disk mounts silently gets an empty auto-created directory and
# reports healthy.
# shellcheck shell=bash

# role_backup_offsite <mode> <platform> <machine>
#   mode: dry-run | apply
role_backup_offsite() {
    local mode="$1" platform="$2" machine="$3"
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local installer="$repo/hosts/$machine/debian/install-rest-server.sh"
    local selfcheck="$repo/hosts/$machine/debian/offsite-selfcheck.sh"

    case "$platform" in
        debian)
            if [ ! -f "$installer" ]; then
                echo "  backup-offsite: no installer for $machine (skipped)"
                echo "                  expected $installer"
                return 0
            fi
            if [ "$mode" != "apply" ]; then
                # A DRY RUN MUST NOT ASSERT — the suite runs on whatever box you
                # happen to be on, and none of them have /mnt/vault. Asserting here
                # would make roles.test.sh red everywhere but the village.
                echo "  backup-offsite: would run (as root) $installer"
                echo "  backup-offsite: installs rest-server $(sed -n 's/^REST_SERVER_VERSION=//p' "$installer" | head -1),"
                echo "                  --append-only --private-repos, htpasswd auth,"
                echo "                  WILDCARD bind (a tailnet-address bind cannot"
                echo "                  survive a reboot — see the unit's header)."
                echo "  backup-offsite: holds NO repository password and never prunes."
                [ -f "$selfcheck" ] && echo "  backup-offsite: would run $selfcheck"
                return 0
            fi
            if [ "$(id -u)" -eq 0 ]; then
                bash "$installer" || return $?
                [ -f "$selfcheck" ] && bash "$selfcheck"
            else
                sudo bash "$installer" || return $?
                [ -f "$selfcheck" ] && sudo bash "$selfcheck"
            fi
            ;;
        *)
            # DELIBERATE, like backup-hub's. This role is a physical disk addressed
            # by UUID, a listening port and a systemd unit on one box. A generic arm
            # here could only pretend. If a second offsite site ever exists, give it
            # its own hosts/<name>/<platform>/ and add the arm then.
            echo "  backup-offsite: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}
```

- [ ] **Step 4: Write the installer**

Create `hosts/offsite/debian/install-rest-server.sh`:

```bash
#!/usr/bin/env bash
# install-rest-server.sh — the village box's restic REST server.
#
# Idempotent; run as root. Installs a PINNED rest-server binary, its user, its
# htpasswd file and its systemd unit.
#
# THE BIND IS A WILDCARD AND THAT IS NOT AN OVERSIGHT. latitude tried binding its
# tailnet address and it cost 29 hours of lost backups on 2026-08-02 and 3 days on
# 2026-08-04: nothing can bind 100.64.x.x before tailscaled is up, and a bind that
# fails during network setup leaves a process that never runs and never exits, so
# nothing that retries exited services recovers it. On a box nobody can touch that
# is the worst failure available. The credentials carry the security argument —
# htpasswd + --private-repos + --append-only is strictly stronger than "reachable
# means authorised", because it also constrains fleet members and it survives a
# device joining the ISP's wifi.
#
# --append-only refuses every DELETE except locks and refuses to delete the config
# at all, so Almaty can add history and can never remove it. The cost is that
# `forget --prune` cannot run from the client. It is not rehomed here: this box
# holds no password, so it COULD not prune, and does not need to — the payload is
# ~1 TB on 8 TB and 663 GB of it is a frozen archive that dedupes to nothing.
# Never forgetting is the correct behaviour for a copy of last resort.
set -euo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

REST_SERVER_VERSION=0.14.0
VAULT=${VAULT:-/mnt/vault}
DATA="$VAULT/restic"
SHA256_LINUX_AMD64=""   # fill from the release's SHA256SUMS before first run

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 2; }

# The disk, by UUID. `nofail` means an absent drive leaves an ordinary empty
# directory, so serving that would publish an empty repository that restic would
# happily accept snapshots into. Refuse instead.
VAULT_UUID=${VAULT_UUID:?set VAULT_UUID to the data disk UUID}
actual="$(findmnt -no UUID "$VAULT" || true)"
[ "$actual" = "$VAULT_UUID" ] || { echo "$VAULT is not UUID=$VAULT_UUID (got '${actual:-nothing}')" >&2; exit 78; }

id -u restic >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin restic
install -d -o restic -g restic -m 0700 "$DATA"

if ! [ -x /usr/local/bin/rest-server ] ||
   ! /usr/local/bin/rest-server --version 2>&1 | grep -q "$REST_SERVER_VERSION"; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    url="https://github.com/restic/rest-server/releases/download/v${REST_SERVER_VERSION}/rest-server_${REST_SERVER_VERSION}_linux_amd64.tar.gz"
    curl -fsSL "$url" -o "$tmp/rs.tgz"
    if [ -n "$SHA256_LINUX_AMD64" ]; then
        echo "$SHA256_LINUX_AMD64  $tmp/rs.tgz" | sha256sum -c -
    else
        echo "WARNING: SHA256_LINUX_AMD64 is empty — the download is unverified" >&2
    fi
    tar -xzf "$tmp/rs.tgz" -C "$tmp"
    install -m 0755 "$tmp"/rest-server_*/rest-server /usr/local/bin/rest-server
fi

# htpasswd lives INSIDE the data directory, so it survives a reinstall of the
# binary and is not in any repository. bcrypt (-B): rest-server supports it and
# the alternative is MD5.
command -v htpasswd >/dev/null 2>&1 || { apt-get update && apt-get install -y apache2-utils; }
if [ ! -f "$DATA/.htpasswd" ]; then
    echo "Create the client credential now:" >&2
    echo "  htpasswd -B -c $DATA/.htpasswd latitude" >&2
    echo "The username MUST be 'latitude': --private-repos maps a username to a" >&2
    echo "TOP-LEVEL directory, so the repo is $DATA/latitude/." >&2
    exit 2
fi
chown restic:restic "$DATA/.htpasswd"; chmod 600 "$DATA/.htpasswd"

cat > /etc/systemd/system/rest-server.service <<EOF
[Unit]
Description=restic REST server (append-only sink)
# The DISK, not the network. A wildcard bind needs nothing from tailscaled, and
# ordering on the mount is what stops the server publishing an empty directory.
After=mnt-vault.mount
Requires=mnt-vault.mount

[Service]
Type=simple
User=restic
Group=restic
ExecStart=/usr/local/bin/rest-server \\
    --path $DATA \\
    --listen :8001 \\
    --private-repos \\
    --append-only \\
    --htpasswd-file $DATA/.htpasswd \\
    --log -
Restart=always
RestartSec=10
# Hardening. The process reads one directory and listens on one port.
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$DATA

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now rest-server.service
systemctl is-active --quiet rest-server.service || { journalctl -u rest-server -n 30 --no-pager; exit 1; }
echo "rest-server $REST_SERVER_VERSION listening on :8001, serving $DATA (append-only)"
```

- [ ] **Step 5: Fill the release checksum**

```bash
curl -fsSL https://github.com/restic/rest-server/releases/download/v0.14.0/SHA256SUMS \
  | grep linux_amd64
# Paste the hash into SHA256_LINUX_AMD64 in the installer.
```

An unverified download installed as root on an unattended box is not acceptable;
the empty-string branch exists only so the script is runnable while the hash is
being fetched, and it warns loudly.

- [ ] **Step 6: Run the tests**

Run: `bash provision/tests/roles.test.sh`
Expected: `ALL PASS`, including `role_backup_offsite`.

Run: `just provision --machine latitude --dry-run`
Expected: unchanged output — the new role file must not perturb an existing
member.

- [ ] **Step 7: Commit**

```bash
git add provision/roles/backup-offsite.sh hosts/offsite/debian/install-rest-server.sh \
        provision/tests/roles.test.sh
git commit -m "provision: the backup-offsite role and its rest-server installer

Lands BEFORE the fleet.json entry: backup-offsite is not in PLANNED_ROLES and
must not be, so a manifest naming it without an executor exits 1.

Wildcard bind, not the tailnet address — that bind cost latitude 29 h and 3 days
of lost backups, because nothing can bind 100.64.x.x before tailscaled is up and
the failed process never exits for a restart policy to catch. Credentials carry
the security argument instead.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

## Task 9: The box's own health, and what it pushes nowhere

**Files:**
- Create: `hosts/offsite/debian/offsite-selfcheck.sh`
- Create: `hosts/offsite/debian/systemd/offsite-{selfcheck,verify}.{service,timer}`
- Create: `hosts/offsite/debian/install-timers.sh`
- Create: `hosts/offsite/debian/README.md`

**Interfaces:**
- Consumes: `restic-pack-verify.sh` (Task 3) — copied to this host's directory or
  referenced from the checkout; reference it, do not copy (two copies drift).
- Produces: `/var/lib/offsite/status.json`, which latitude **pulls**. The
  contract is `{"ts":<epoch>,"ok":true|false,"detail":"<string>", …}` —
  `backup-status.sh` (Task 5) reads exactly `"ok"` and `"detail"`.

- [ ] **Step 1: Write the selfcheck**

Create `hosts/offsite/debian/offsite-selfcheck.sh`:

```bash
#!/usr/bin/env bash
# offsite-selfcheck.sh — is this box still a working copy of the fleet's data?
#
# Hourly. Cheap: mount by UUID, free space, SMART health, newest snapshot age,
# and the result of the last WEEKLY sweep (offsite-verify.timer, which does the
# expensive part). Writes /var/lib/offsite/status.json.
#
# LATITUDE PULLS THIS FILE; THIS BOX PUSHES NOTHING. The direction matters: the
# whole design is that Almaty can add to this box and never take away, and
# granting it an ssh key INTO Almaty would open exactly the hole --append-only
# closes, in the other direction. On the Almaty end the file's own mtime is this
# box's liveness signal and its contents are the verdict — two conditions on one
# file, which is what keeps "the sweep failed" distinguishable from "the link is
# down".
#
# CHECKING FROM ALMATY IS NOT EQUIVALENT AND THAT IS WHY THIS EXISTS. A check run
# over the link cannot tell "repository is fine" from "link is down", and a
# --read-data check from Almaty would pull tens of gigabytes over a residential
# uplink every time.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

VAULT=${VAULT:-/mnt/vault}
VAULT_UUID=${VAULT_UUID:?set VAULT_UUID}
STATE=${OFFSITE_STATE:-/var/lib/offsite}
REPO_DIR="$VAULT/restic/latitude"
MIRROR_DIR="$VAULT/mirror"
now="$(date +%s)"
ok=true; detail=""

note() { ok=false; detail="${detail:+$detail; }$1"; }

# 1. The disk, BY UUID. `findmnt -no SOURCE` only proves something is mounted.
actual="$(findmnt -no UUID "$VAULT" 2>/dev/null || true)"
[ "$actual" = "$VAULT_UUID" ] || note "vault not mounted (got '${actual:-nothing}')"

# 2. Free space. An append-only repo that never prunes must not be allowed to
#    surprise anyone: warn at 85%, fail at 95%.
pct="$(df --output=pcent "$VAULT" 2>/dev/null | tail -1 | tr -dc '0-9')"
[ -n "$pct" ] && [ "$pct" -ge 95 ] && note "vault ${pct}% full"

# 3. SMART. The whole reason this is an HDD: it dies gradually and warns, and
#    weeks of warning is the difference between a planned trip and a lost copy.
dev="$(findmnt -no SOURCE "$VAULT" 2>/dev/null | sed 's/[0-9]*$//')"
if [ -n "$dev" ]; then
    health="$(smartctl -H "$dev" 2>/dev/null | sed -n 's/.*overall-health.*: *//p')"
    case "$health" in PASSED | OK | '') : ;; *) note "SMART $health" ;; esac
    for id in 5 197 198; do
        raw="$(smartctl -A "$dev" 2>/dev/null | awk -v i="$id" '$1==i { print $10; exit }')"
        [ -n "$raw" ] && [ "${raw%%[^0-9]*}" -gt 0 ] 2>/dev/null && note "SMART attr $id = $raw"
    done
fi

# 4. Newest snapshot. Age only — no restic binary, no password.
newest="$(find "$REPO_DIR/snapshots" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
snap_age=""
if [ -n "$newest" ]; then snap_age=$((now - ${newest%.*}))
else note "no snapshots in $REPO_DIR"; fi

# 5. Last sweep result, written by offsite-verify.timer.
sweep_ts=""; sweep_bad=""
if [ -f "$STATE/verify.json" ]; then
    sweep_ts="$(sed -n 's/.*"ts"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATE/verify.json" | head -1)"
    sweep_bad="$(sed -n 's/.*"bad"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATE/verify.json" | head -1)"
    [ "${sweep_bad:-0}" -gt 0 ] 2>/dev/null && note "sweep found $sweep_bad bad packs"
    # A sweep that has not run in three weeks is itself a failure — a weekly job
    # that stopped is exactly the silence this whole design is built against.
    [ -n "$sweep_ts" ] && [ $((now - sweep_ts)) -gt 1814400 ] && note "sweep last ran $(( (now - sweep_ts) / 86400 ))d ago"
else
    note "sweep has never run"
fi

mkdir -p "$STATE"
cat > "$STATE/status.json" <<EOF
{"ts":$now,"ok":$ok,"detail":"$detail","snapshot_age":"${snap_age}","vault_pct":"${pct}","sweep_ts":"${sweep_ts}","sweep_bad":"${sweep_bad}"}
EOF
$ok
```

- [ ] **Step 2: Write the weekly sweep unit**

`hosts/offsite/debian/systemd/offsite-verify.service`:

```ini
[Unit]
Description=Keyless SHA-256 integrity sweep of the offsite repositories
After=mnt-vault.mount
Requires=mnt-vault.mount

[Service]
Type=oneshot
# Nice and idle-class: this reads a terabyte and must never contend with an
# incoming backup. It has all week.
Nice=19
IOSchedulingClass=idle
ExecStart=/bin/bash -c '\
  set -o pipefail; \
  out=$(/home/me/machines/hosts/latitude/debian/restic-pack-verify.sh \
        /mnt/vault/restic/latitude --baseline /var/lib/offsite/baseline.sha); rc=$?; \
  bad=$(printf "%s" "$out" | sed -n "s/.*bad=\\([0-9]*\\).*/\\1/p" | tail -1); \
  mkdir -p /var/lib/offsite; \
  printf "{\\"ts\\":%s,\\"rc\\":%s,\\"bad\\":%s}\\n" "$(date +%%s)" "$rc" "$${bad:-0}" \
    > /var/lib/offsite/verify.json; \
  printf "%s\\n" "$out"; exit $rc'
```

`offsite-verify.timer`:

```ini
[Unit]
Description=Weekly offsite integrity sweep

[Timer]
OnCalendar=Sun 13:00
Persistent=true
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
```

`offsite-selfcheck.service` / `.timer`: `Type=oneshot`, `ExecStart` the
selfcheck, `OnBootSec=2min` / `OnUnitActiveSec=1h`, `Persistent=true`.

- [ ] **Step 3: Write `install-timers.sh`**

Model it on `hosts/latitude/debian/install-timers.sh`: **copy** the units into
`/etc/systemd/system` rather than symlinking, so a `git pull` cannot change what
root runs on a timer. It must also write
`/etc/default/offsite` carrying `VAULT_UUID=<uuid>` and have both units
`EnvironmentFile=-/etc/default/offsite`.

- [ ] **Step 4: Write the README**

`hosts/offsite/debian/README.md` must state, in this order:

1. **This box holds no repository password, and must never be given one.** The
   sweep is keyless because a pack file's name is the SHA-256 of its bytes. A
   key here would mean a stolen box hands over every photo.
2. **It never prunes.** The repository grows forever. That is intended.
3. **It serves `--append-only`.** Almaty can add and cannot remove.
4. **Recovery runbook**: what to do if the box is found off (check the BIOS
   restore-on-AC setting first — that is the single point of the design), if the
   disk is full, if the sweep reports bad packs (do not delete anything: the
   canonical copy is in Almaty, and re-seeding is a trip, not a `rm`).
5. **What to check on each visit**: blow out the fan, `smartctl -t long`, read
   `journalctl -u rest-server --since '3 months ago' | grep -c 403`.

- [ ] **Step 5: Commit**

```bash
git add hosts/offsite/
git commit -m "offsite: the village box's own health, sweep and timers

Hourly selfcheck (mount by UUID, SMART, snapshot age, last sweep) and a weekly
keyless SHA-256 sweep. latitude PULLS the status file; this box pushes nothing —
granting it a key into Almaty would open, in the other direction, exactly the
hole --append-only closes.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

## Task 10: Fleet integration

Lands **after** Task 8, never before.

**Files:**
- Modify: `fleet.json`

- [ ] **Step 1: Add the member**

```json
    "offsite": {
      "platform": "debian",
      "tailnet": { "ip": "100.64.0.11" },
      "roles": ["base", "ssh-server", "backup-offsite"],
      "detect": { "hostname": "<the box's OS hostname>" }
    }
```

**The box needs a `machines` checkout even though it has no `repos` role.** The
role executor and every script it installs are read out of it, and `hub` is the
same shape — roles `base, ssh-server, agents, dotfiles, backup-client`, no
`repos`, provisioned from a clone. Clone it to `~/machines` by hand as part of
bringing the box up; nothing in the manifest does it for you.

`platform: debian` whatever apt distro ships — the token is a platform *class*,
and `ubuntu` makes every posix role executor skip while `--apply` reports
success. No `agents`, no `repos`, no `dotfiles`: this is an appliance.

**Logical name `offsite`, with a recorded risk.** It is role-based, per the
naming rule. `server` was renamed once its role moved, and this name has the same
shape. If a second offsite site ever exists, rename to the place name then — and
a rename moves the tailnet node, the dotfiles branch and `fleet-authorized-keys`
in one change, or it moves nothing.

- [ ] **Step 2: Confirm the tailnet address is free**

```bash
ssh hub 'sudo headscale nodes list'
```

Never infer a tailnet address from a pattern — take the next free one from
Headscale itself and put *that* in the manifest.

- [ ] **Step 3: Verify the manifest**

```bash
just provision --machine offsite --dry-run
```

Expected: three roles, `base` and `ssh-server` printing the planned-stub
warning, `backup-offsite` printing its "would run" block. Exit 0.

```bash
just provision --machine typo --dry-run
```

Expected: exit 2, unknown machine.

```bash
just test
```

Expected: green. `fleet-profile.test.sh`, `repo-groups.test.sh` and
`fleet-logical-name.test.sh` all name specific machines and none of them iterate
the manifest, so adding a member perturbs nothing — verified 2026-09-12, re-check
if that changes.

- [ ] **Step 4: Enrol the node, the key and the branch — together**

```bash
# Headscale (on hub)
ssh hub 'sudo headscale preauthkeys create --user <user> --expiration 1h'
# On the box:
tailscale up --login-server https://cc.cyphy.kz --authkey <key> --hostname offsite
# fleet-authorized-keys: add the box's public key on the boxes it must reach,
# and latitude's on this one (latitude PULLS the status file).
# dotfiles: create the `offsite` branch from main and check it out on the box.
```

A rename later moves all three together or none.

- [ ] **Step 5: Commit**

```bash
git add fleet.json
git commit -m "fleet: the offsite member

platform debian whatever apt distro ships — the token is a class, and 'ubuntu'
makes every posix role executor skip while --apply reports success. Appliance
roles only: base, ssh-server, backup-offsite.

Recorded risk: 'offsite' is role-based, and 'server' was renamed once its role
moved. If a second site appears, rename to the place name — node, dotfiles
branch and fleet-authorized-keys in one change.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Phase 4 — The trip

## Task 11: Install, and measure what cannot be measured from Almaty

- [ ] **Step 1: Install the drive internally**

The seed drive goes in the 3.5" bay. **Never a USB dock** — eight dock drops in
six weeks on latitude were caused by mains dips, and there is nobody in the
village to power-cycle a brick.

- [ ] **Step 2: Prove self-recovery on site, before anything else**

Pull the plug at the wall, wait 30 s, plug it back. The box must come up, mount
`/mnt/vault` by UUID, and start `rest-server` with no keypress. Do it twice. This
is the whole premise; if it fails, nothing else in this plan matters.

- [ ] **Step 3: Measure the uplink — upload specifically**

```bash
speedtest-cli --no-download; speedtest-cli --no-upload
```

"Good speed" is almost certainly the download figure. Upload is what this design
consumes. Record both, with the date.

- [ ] **Step 4: Measure the path to latitude**

```bash
tailscale ping latitude
tailscale status | grep latitude
```

Record **direct or DERP**. A relayed pair goes through hub's DERP on a metered
VPS in Almaty. **Do not accept a relay silently** — this repo lost a migration
design to a stale "expected and accepted" DERP claim, which is why that sentence
is now a warning in `AGENTS.md`.

- [ ] **Step 5: Check for the ISP's TLS-SNI filtering**

Compare against Almaty's behaviour (recorded in global memory, measured
2026-09-09). If the village ISP filters too, the fix is the one already installed
on g15; if it does not, that is a fact worth recording, because it changes what
this site could be used for later.

- [ ] **Step 6: Bring up the server**

```bash
sudo VAULT_UUID=<uuid> bash ~/machines/hosts/offsite/debian/install-rest-server.sh
htpasswd -B -c /mnt/vault/restic/.htpasswd latitude   # username MUST be 'latitude'
sudo systemctl restart rest-server && systemctl is-active rest-server
```

Wait — the repository was seeded at `/mnt/vault/restic/latitude`, which is exactly
where `--private-repos` maps the user `latitude`. No move, no re-init. Confirm:

```bash
ls -la /mnt/vault/restic/latitude/config
```

- [ ] **Step 7: Verify the journey**

```bash
sudo bash ~/machines/hosts/latitude/debian/restic-pack-verify.sh \
  /mnt/vault/restic/latitude --baseline /var/lib/offsite/baseline.sha
```

Copy `/var/tmp/offsite-baseline.sha` from Task 4 Step 5 to
`/var/lib/offsite/baseline.sha` first. Expected: `bad=0`. A nonzero count here,
against a clean baseline taken at the source, means the drive did not survive the
journey — and that is exactly what the baseline exists to prove.

- [ ] **Step 8: Record every measurement in the repo**

```bash
git add hosts/offsite/debian/README.md
git commit -m "offsite: measured on site <date> — upload <N> Mbit, <direct|DERP>, SNI <filtered|clear>

Self-recovery proven twice from a cold mains pull. Seed verified after the
journey against the baseline taken at the source: bad=0.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

## Task 12: Cut latitude over to `rest:`

**Files:**
- Modify: `backup/latitude/profiles.yaml`
- Create: `hosts/latitude/debian/offsite-mirror.sh` + its units

- [ ] **Step 1: Store the server credential on latitude**

```bash
ssh latitude.gg.ez 'bash -s' <<'EOF'
umask 077
mkdir -p ~/.config/restic
printf 'rest:http://latitude:<the htpasswd password>@offsite.gg.ez:8001/\n' \
  > ~/.config/restic/offsite.repo.txt
chmod 600 ~/.config/restic/offsite.repo.txt
git --git-dir=$HOME/.dotfiles --work-tree=$HOME check-ignore -v ~/.config/restic/offsite.repo.txt
EOF
```

This is the **transport** credential, not the repository password, and the two
must not be confused: this one is rotatable — the recovery story for a leak is
`htpasswd` again — while the repository password is the last copy of a secret and
losing it makes the offsite repository unreadable forever.

Track it on latitude's branch the way `.netrc` is, after confirming
`check-ignore` does not put it under the key-material deny block. **Never put the
URL in `profiles.yaml`** — that file is tracked in `machines`, which is a
different repo with a different audience.

- [ ] **Step 2: Re-point the profile**

Three coupled edits in the `photos` profile, and they are one change:

```yaml
  # REPOSITORY-FILE, NOT `repository`. restic carries REST credentials in the URL
  # and there is no RESTIC_REST_USERNAME to escape into — so spelling the URL
  # here would commit a password to a tracked file. The file below is mode 600,
  # host-local on latitude's dotfiles branch, and holds one line:
  #   rest:http://latitude:<password>@offsite.gg.ez:8001/
  repository-file: "/home/me/.config/restic/offsite.repo.txt"
  # The run-before mount assertion is meaningless against a URL. The equivalent
  # is a reachability probe that fails the whole pipeline, so a server that came
  # up serving an empty directory cannot be backed into silently. It reads the
  # same one file — the password is never on a command line, where `ps` would
  # show it to every user on the box.
  run-before:
    - 'curl -sf --url "$(sed "s#^rest:#http:#" /home/me/.config/restic/offsite.repo.txt)latitude/config" -o /dev/null'
  initialize: false
  retention:
    # OFF. The server runs --append-only, so every DELETE but a lock gets 403 —
    # and with after-backup: true that 403 fails the whole run. This is the same
    # arrangement the g614jv and g513ie client profiles carry, for the same
    # reason. Nothing prunes the offsite repo, by design: see the plan.
    before-backup: false
    after-backup: false
    prune: false
  check:
    # METADATA ONLY — no read-data-subset. The bytes are verified on the village
    # box by the keyless weekly sweep, which reads 100% of them for free; pulling
    # 5% of a terabyte over a residential uplink every Sunday would buy less
    # coverage at enormous cost. This check is for STRUCTURE: that the index
    # agrees with the packs and that snapshots resolve.
    schedule: "Sun 12:00"
    schedule-permission: system
```

Delete the `read-data-subset` line from `check:`, and delete `check-before: true`
from `backup:` — a nightly structural check over the link is a round trip that
buys nothing the Sunday one does not.

`initialize: false` because the repository already exists; leaving it true would
mean a server that came up serving an empty directory could be initialised into a
fresh zero-history repo that reports success. That is the exact failure
`base.yaml` documents.

- [ ] **Step 3: Prove the cutover with a real run**

```bash
ssh latitude.gg.ez 'cd ~/machines/backup/latitude && sudo -E resticprofile -n photos backup'
ssh latitude.gg.ez 'cd ~/machines/backup/latitude && sudo -E resticprofile -n photos snapshots | tail -5'
```

Expected: a delta measured in the hundreds of MB, not the hundreds of GB — the
archive is frozen and must not re-upload. **If it re-uploads the archive, stop**:
something about the repository identity changed and a second full seed over a
residential uplink is not an option.

- [ ] **Step 4: Prove append-only is enforced**

```bash
ssh latitude.gg.ez 'cd ~/machines/backup/latitude && sudo -E resticprofile -n photos forget --keep-last 1 --dry-run'
```

Expected: a 403. If a delete succeeds, `--append-only` is not on and the whole
trust direction is fiction.

- [ ] **Step 5: The rsync leg for the two existing repositories**

Create `hosts/latitude/debian/offsite-mirror.sh`:

```bash
#!/usr/bin/env bash
# offsite-mirror.sh — the two EXISTING restic repositories to the village box.
#
# rsync, NOT restic, and NOT --delete.
#
# WHY NOT restic: these repositories are already encrypted, so their blobs are
# random and restic would dedupe exactly nothing — it would be a slower copy that
# also needs a key at the far end.
#
# WHY NO --delete: restic pack files are IMMUTABLE once written, so a no-delete
# rsync is append-only BY CONSTRUCTION. There is no server enforcing it on this
# leg and none is needed; the property comes from the data format.
#
# EXIT: 75 = lock held, 78 = source mount is not the expected filesystem,
# everything else rsync's. Two failures must not share one exit status — a
# routine collision and a vanished backup disk were the same ExecMainStatus on
# the mirror scripts until 2026-09-10.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

WD8_UUID=${WD8_UUID:?set WD8_UUID}
DEST=${DEST:-offsite.gg.ez:/mnt/vault/mirror/}

exec 9>/var/lock/latitude-offsite-mirror.lock
flock -n -E 75 9 || exit 75

# By UUID. `findmnt -no SOURCE` only proves SOMETHING is mounted, and a Condition
# in the unit would SKIP rather than fail — systemd reports a skipped unit as
# Result=success, which is how mirror-refresh reported success for 90 minutes
# with its destination unplugged.
[ "$(findmnt -no UUID /mnt/wd8)" = "$WD8_UUID" ] || exit 78

rsync -aHx --partial --partial-dir=.rsync-partial --info=stats2 \
  /mnt/wd8/restic-rest/ "$DEST/restic-rest/"
rsync -aHx --partial --partial-dir=.rsync-partial --info=stats2 \
  /mnt/wd8/restic/ "$DEST/restic/"
```

Schedule it at **03:00** — after the photo backup at 02:00 and clear of the
04:30/05:00/06:00 writers. Install its unit through
`hosts/latitude/debian/install-timers.sh`.

- [ ] **Step 6: Commit**

```bash
git add backup/latitude/profiles.yaml hosts/latitude/debian/offsite-mirror.sh \
        hosts/latitude/debian/systemd/offsite-mirror.* hosts/latitude/debian/install-timers.sh
git commit -m "backup/latitude: photos push to the offsite rest: repo; repos ride rsync

Three coupled edits and they are one change: repository -> rest:, the mount
assertion becomes a reachability probe, retention off (the server 403s every
DELETE, and after-backup: true would fail the run on it).

The two existing repos go by no-delete rsync: pack files are immutable, so
append-only comes from the data format and needs no server. Encrypting them again
with restic would dedupe nothing.

Delta after cutover: <N> MB. Append-only proven — forget --dry-run returns 403.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

## Task 13: Close the alerting loop

**Files:**
- Create: `hosts/latitude/debian/offsite-status-pull.sh` + units
- Modify: `provision/statusboard/backup-jobs.latitude5520.conf`

- [ ] **Step 1: Pull the status file**

```bash
#!/usr/bin/env bash
# offsite-status-pull.sh — fetch the village box's self-report.
#
# PULL, not push. Granting the offsite box an ssh key into Almaty would open, in
# the other direction, exactly the hole --append-only closes: the sink must not be
# able to write to the source.
#
# A FAILED PULL IS NOT AN ERROR HERE — it leaves the previous file in place and
# the file's own MTIME goes stale, which is precisely the signal backup-status.sh
# reads as "that box or that link is down". Erroring would only turn one silence
# into another.
set -uo pipefail
DEST=${DEST:-/var/lib/fleet-backup/offsite.json}
mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp)"
if timeout 60 scp -q offsite.gg.ez:/var/lib/offsite/status.json "$tmp" 2>/dev/null &&
   [ -s "$tmp" ]; then
    mv "$tmp" "$DEST"
    # The mtime must be OUR fetch time, not the remote file's: it is the freshness
    # of the LINK plus the box, which is what a `status` row is measuring.
    touch "$DEST"
else
    rm -f "$tmp"
fi
exit 0
```

Timer: `OnBootSec=5min`, `OnUnitActiveSec=30min`.

- [ ] **Step 2: Enable the offsite rows**

Uncomment the `status offsite` line in
`provision/statusboard/backup-jobs.latitude5520.conf` and add the repo rows the
village now holds:

```
status offsite  /var/lib/fleet-backup/offsite.json  7200
```

The `photos` repo row already exists from Task 5 but now points at a path that no
longer exists locally — **change its kind**: the offsite `status` row carries the
snapshot age now, so delete the local `repo photos …` line rather than leaving it
to report `bad|repo missing` forever.

- [ ] **Step 3: Prove both alert conditions end to end**

```bash
# 1. Link down: stop the pull and age the file past 2x its period.
ssh latitude.gg.ez 'sudo touch -d "5 hours ago" /var/lib/fleet-backup/offsite.json && \
  sudo bash ~/machines/hosts/latitude/debian/backup-status.sh | grep offsite'
```
Expected: `offsite|18000|7200|stale|`.

```bash
# 2. Box reports a failure: hand-edit a COPY of the status file to ok:false.
ssh latitude.gg.ez 'sudo bash -c "cp /var/lib/fleet-backup/offsite.json /tmp/o.json && \
  sed -i s/\\\"ok\\\":true/\\\"ok\\\":false/ /tmp/o.json && \
  BACKUP_STATUS_JOBS=/tmp/jobs.conf bash ~/machines/hosts/latitude/debian/backup-status.sh"'
```
Expected: `offsite|<age>|7200|bad|<detail>`.

Then restore the real file and confirm the row returns to `ok`. **Two distinct
conditions on one file** is the point — "the sweep failed" and "the link is down"
must never collapse into one alert.

- [ ] **Step 4: Confirm it reaches the strip**

```bash
ssh latitude.gg.ez 'cd ~/machines && STATUSBOARD_ONCE=1 bash provision/statusboard/statusboard.sh'
```

Expected: the alert strip shows the backup alert alongside the fleet and docker
ones.

- [ ] **Step 5: Mark the roadmap item done**

Edit `docs/fleet-roadmap.md` P0: the deferred backup-report item is built. Say
what was built and what is still not — nothing pages anyone; the alert reaches a
screen in the flat, not a phone.

- [ ] **Step 6: Commit**

```bash
git add hosts/latitude/debian/offsite-status-pull.sh hosts/latitude/debian/systemd/ \
        hosts/latitude/debian/install-timers.sh provision/statusboard/backup-jobs.latitude5520.conf \
        docs/fleet-roadmap.md
git commit -m "latitude: pull the offsite self-report, alert on both conditions

The file's mtime is the box-plus-link liveness signal; its contents are the
box's verdict. Two conditions on one file, so 'the sweep failed' never collapses
into 'the link is down'. Closes the deferred roadmap P0 backup report.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Phase 5 — After the trip

## Task 14: Hand dockA0 to the drive that has been waiting for it

`disks.latitude5520.conf` already records the debt: the ST1000LM024 carrying
`/mnt/immich-mirror` sits in a loose NS1066 bridge on the **USB 2.0** half of the
controller — 480 Mbit — because its SuperSpeed pairs do not make contact and the
connector walks. The bay the seed drive borrowed is now free.

- [ ] **Step 1: Move it**

Unmount `/mnt/immich-mirror`, move the drive from the NS1066 bridge into dockA0,
remount by UUID, and confirm the tag:

```bash
ssh latitude.gg.ez 'export PATH=/usr/sbin:/sbin:/usr/bin:/bin; \
  udevadm info -q path -n $(findmnt -no SOURCE /mnt/immich-mirror)'
```

Expected: a path under `usb4/4-1`, tag `u4-1:0`. **Measure topology before
trusting a bay, never capacity.**

- [ ] **Step 2: Confirm the link speed changed**

```bash
ssh latitude.gg.ez 'cat /sys/bus/usb/devices/4-1/speed'
```

Expected: `5000`, not `480`. Then time one `mirror-refresh` run and compare
against the recorded 480 Mbit figure.

- [ ] **Step 3: Update the disk map**

Rewrite the topology table in `provision/statusboard/disks.latitude5520.conf`:
delete the `ns1066` bay line and its whole explanatory block (the slot is gone,
and an exemption for a slot that cannot appear is indistinguishable from one
nobody remembers granting), and record the new occupant of `u4-1:0`.

- [ ] **Step 4: Commit**

```bash
git add provision/statusboard/disks.latitude5520.conf
git commit -m "latitude: immich-mirror off the NS1066 stopgap into dockA0

The bay spare320 freed was LENT to the offsite seed; the seed has travelled and
the debt disksconf recorded is paid. 480 Mbit -> 5 Gbit, and the walking
connector leaves the fleet.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Out of scope, recorded once

Mother's and grandmother's phone photos are backed up nowhere. They do not want
it yet, and when they do, `immich.cyphy.kz` in Almaty serves them — the link is
good. The village box does **not** become a photo target for the household; it
stays a pure backup sink. Giving it a second job would give it a second reason to
be touched, and nobody on site can touch it.

## Self-review notes

- **Spec coverage.** Every section of the spec maps to a task: payload → Task 4;
  photos into restic → Tasks 3–4; direction of trust → Tasks 8, 12; two
  mechanisms → Task 12; storage/HDD → Task 2; capacity → Task 7; hardware
  criteria → Task 7; drive acceptance → Task 2; seeding → Tasks 1, 2, 4;
  measure on the trip → Task 11; alerting → Tasks 5, 6, 9, 13; fleet
  integration → Tasks 8, 10; out of scope → above. The spec's `prune`-on-the-box
  requirement is deliberately **not** implemented; see Correction 3.
- **The only hard external deadline is the drive.** `badblocks -w` on 8 TB is
  multiple days and the identity gate runs on the shop's return clock. Tasks 5
  and 6 are parallel work that needs no hardware.
- **Unresolved, and it needs a real measurement, not a guess:** the seed backup's
  wall-clock time (Task 4 Step 4) and the post-cutover delta (Task 12 Step 3).
  Both are recorded in commit messages because every later capacity and
  bandwidth question depends on them.
