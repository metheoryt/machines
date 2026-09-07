# g15 Phase 1 — Staging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move g15's entire 293 GB payload off the box onto latitude and prove by manifest that nothing was lost, so the Debian installer can be booted without a second copy anywhere.

**Architecture:** One tool, `hosts/g15/staging/stage.sh`, run as root **on g15-wsl**, which pushes each of three payloads outbound over the LAN to `latitude:/mnt/immich-mirror/g15-staging/` with rsync. The distro is NATed, so the tailnet path to latitude is DERP-relayed at 3.3 MB/s while the outbound LAN path is 78 MB/s — NAT blocks reaching *in*, not going out, and that asymmetry is the whole transport design. Verification is a path+size manifest taken on both sides and diffed, never a `du` comparison.

**Tech Stack:** bash, rsync 3.4.1 (both ends), OpenSSH, docker (to quiesce postgres), Windows Task Scheduler (to hold the distro up), `find -printf` manifests.

**Spec:** `docs/superpowers/specs/2026-09-07-g15-debian-migration-design.md`

## Global Constraints

These apply to every task below, without being repeated in it.

- **`< /dev/null` (or `-n`) on every `ssh`, `docker` and `wsl` call inside a script fed on stdin.** Those commands read stdin to EOF and will eat the rest of the script. This bit during planning: a probe's last two lines silently never ran. Same class of failure as the `just test` gate skipping 17 suites.
- **Root on g15-wsl comes from Windows, not from `sudo`.** `me` is in the `sudo` group but has **no NOPASSWD**, so `sudo -n` fails. The route is `ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'` with the script on stdin. Never try to `sudo` inside the distro non-interactively.
- **`me` on latitude DOES have NOPASSWD sudo** (checked 2026-09-07). That is why the destination side of every rsync is `--rsync-path='sudo rsync'` — ownership and modes are preserved numerically at copy time instead of being reconstructed on restore.
- **Scripts reach a Windows fleet host as a heredoc on stdin, never as a quoted argument.** PowerShell parses the command line first and eats quotes; a `-printf "%s\t%P\n"` passed as an argument silently returns one line.
- **`pv` and `zstd` are NOT installed on g15-wsl** and installing them needs the password-gated sudo. No step may reach for either. `--info=stats2` is the progress report.
- **`ssh` to a bare IP does not pick up the fleet identity.** The generated config keys on `Host *.gg.ez`, so `ssh me@192.168.8.155` falls through to the default identity and fails in 0.2 s having moved nothing — which reads exactly like having no bandwidth. Always `-i ~/.ssh/id_fleet -o IdentitiesOnly=yes`. This produced three false measurements on 2026-09-07.
- **Do not switch g15 to `networkingMode=mirrored`.** It would probably work, and it would also expose the Windows Tailscale adapter inside the distro while g15 has two tailnet nodes (`100.64.0.3` Windows, `100.64.0.9` distro) to fight over routes. Changing the network mode of the box you are about to read 204 GB out of, to save half an hour on a route that already runs at 78 MB/s, is the wrong trade.
- **Postgres stays stopped once Task 3 stops it.** Any restart rewrites `pgdata` and invalidates the manifest taken in Task 7. The container's restart policy is set to `no` deliberately and is **not** restored — the container dies with the disk.
- **Nothing in this plan wipes, formats, deletes or reinstalls anything.** Phase 1 is additive on both boxes. Rollback until Phase 2 is "delete the staging copy".

---

## Measured facts this plan is built on

All measured 2026-09-07. If a number here disagrees with the box, trust the box and stop.

| Fact | Value |
|---|---|
| `/data/qaz-law/pgdata` | 186 GB, 1268 files, **0 hardlinks** |
| ├ file ownership/mode | uniformly `999:999` mode `600` |
| ├ dir ownership/mode | four combinations: `0:0 755`, `999:0 700`, `999:999 700`, `999:999 755` |
| └ live `PGDATA` | `/data/qaz-law/pgdata/18/docker` (postgres 18.4, `data_checksums on`) |
| `/home/me` | 18 GB, 226 003 files, 39 symlinks, 2 sockets, **0 hardlinks**, uniformly `1000:1000` |
| └ the 2 sockets | `~/.config/orca/o-2126-cc81.sock`, `~/.config/orca/daemon/daemon-v36.sock` |
| `/mnt/c/Users/methe/Music` | 89 GB, 14 878 files, drvfs (synthetic ownership and perms) |
| **Total** | **293 GB → ~63 min at 78 MB/s** |
| latitude `/mnt/immich-mirror` | ext4, 610 GB free, writable by `me`, rsync 3.4.1 |
| g15-wsl | rsync 3.4.1, `tmux`/`screen`/`setsid` present, **`pv`/`zstd` absent** |
| docker container | `qaz-law-db-1`, compose project `qaz-law`, restart policy `always` |
| `wsl-keepalive` task | State `Ready`, **last run 2026-09-05 21:42, result `3221225786`** = `STATUS_CONTROL_C_EXIT` |

**That last row is the sharpest finding of the planning pass.** `State: Ready` means *not running*; the keepalive died two days ago and the distro is currently held up only by stray `wsl.exe` orphans from interactive sessions. A WSL distro lives only while a `wsl.exe` client from Windows is attached to it, so a 40-minute transfer started under those orphans can die when one of them exits — and `setsid nohup` does not save it, because the detached process goes down with the distro. Task 2 re-arms the keepalive and verifies it **by PID inside the distro**, not by task state. This repo already learned that lesson once: *verify a scheduled job by firing its schedule, not by reading its status.*

---

## File Structure

| File | Responsibility |
|---|---|
| `hosts/g15/staging/stage.sh` | **Create.** The one staging tool. Payload table (source, destination, per-payload rsync flags), the postgres guard, the manifest pipeline, and the six modes: `cmd`, `manifest-cmd`, `plan`, `stage`, `verify`, `status`. Runs on g15-wsl as root. |
| `hosts/g15/staging/stage.test.sh` | **Create.** Gate suite. Asserts the guards and the *composed* command lines without moving a byte, so it runs on any box, non-root, inside `just test`. |
| `hosts/g15/staging/identity-snapshot.txt` | **Create in Task 2.** The identity set that must move together, captured from live commands rather than retyped. |

`hosts/g15/` is new — `hosts/server/` was deleted with the 2026-08-01 decommission and `hosts/g15/debian/` will appear in Phase 4. Nothing existing is modified. The tests directory convention in this repo is co-location (`agents/plugin/skills/*/tests/`, `provision/*.test.sh`), and `just _test-suites` is a recursive `find`, so a suite here is picked up by the gate with no wiring.

**Why one script with modes rather than three scripts:** the three payloads differ only in source path and four rsync flags. The parts that are easy to get wrong — the ssh identity, `--partial-dir`, `--rsync-path='sudo rsync'`, the manifest pipeline — are identical, and duplicating them three times is how two of the three end up subtly different. Same shape `hosts/latitude/debian/archive-mirror.sh` uses (`-n` / `-go` / `-verify` in one file).

---

### Task 1: The staging tool and its guard suite

**Files:**
- Create: `hosts/g15/staging/stage.test.sh`
- Create: `hosts/g15/staging/stage.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the CLI every later task drives —
  `stage.sh cmd <payload> [dry]` → prints the rsync command line, runs nothing, needs no root;
  `stage.sh manifest-cmd <payload> {src|dst}` → prints the manifest pipeline, runs nothing;
  `stage.sh plan <payload>` → `rsync -n`, needs root;
  `stage.sh stage <payload>` → the copy, needs root, logs to `/var/log/g15-staging/<payload>.log`;
  `stage.sh verify <payload>` → manifests both sides, diffs, exit 4 on mismatch;
  `stage.sh status` → sizes on both sides plus log tails.
  Payloads: `pgdata`, `home`, `music`. Env overrides: `STAGE_LAT`, `STAGE_DIR`, `STAGE_KEY`, `STAGE_LOGDIR`, `STAGE_PGPID`.
  Exit codes: `0` ok, `1` not root, `2` usage, `3` postgres still running, `4` manifest mismatch.

- [x] **Step 1: Write the failing test suite**

Create `hosts/g15/staging/stage.test.sh`:

```bash
#!/usr/bin/env bash
# hosts/g15/staging/stage.test.sh — guard the staging tool's composed commands.
#
# WHY THIS SUITE EXISTS AND WHAT IT CAN AND CANNOT CHECK. stage.sh moves 293 GB
# in three runs of about 40, 19 and 5 minutes, on a box that is about to be
# wiped. There is no second attempt after the disk is gone, so the flags have to
# be right the FIRST time — but a test cannot move 293 GB, and a test that moved
# a token file would exercise none of the flags that matter.
#
# So stage.sh separates COMPOSING a command from RUNNING it (`cmd` and
# `manifest-cmd` print and exit), and this suite asserts the composition. It
# needs no root, no g15, no latitude and no network, which is what lets it run
# in `just test` on any box in the fleet.
#
# The four things it pins are the four that were actually got wrong by hand
# during planning:
#   - the fleet identity (`-i`, `IdentitiesOnly=yes`) — three false zero-byte
#     "measurements" came from a bare-IP ssh falling through to the default key
#   - `--partial-dir`, never `--append-verify` (archive-mirror.sh's header says
#     why: a torn write is not a strict prefix of the source)
#   - `-a` on the ext4 payloads but NOT on the drvfs one, where it would copy
#     synthetic ownership and then fail setting it
#   - the postgres guard, because a running PGDATA copies torn and the result
#     looks exactly like a backup
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$HERE/stage.sh"
FAIL=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = 0 ]; then pass "$2"; else fail "$2"; fi; }

[ -f "$SH" ] || { echo "FAIL: $SH missing" >&2; exit 1; }
[ -x "$SH" ]
check $? "stage.sh is executable"

# `me` runs the gate, never root — every assertion below must hold non-root.
if [ "$(id -u)" = 0 ]; then
    echo "FAIL: run this suite as a normal user; the non-root assertions need it" >&2
    exit 1
fi

# ── 1. Usage and exit codes ───────────────────────────────────────────────────
# Exit CODES, not messages: a caller (and Task 4's launcher) branches on the
# code, and pinning the prose makes the suite fail on a reworded error.
"$SH" >/dev/null 2>&1; [ "$?" = 2 ]
check $? "no arguments exits 2"

"$SH" frobnicate pgdata >/dev/null 2>&1; [ "$?" = 2 ]
check $? "an unknown mode exits 2"

"$SH" cmd >/dev/null 2>&1; [ "$?" = 2 ]
check $? "cmd with no payload exits 2"

"$SH" cmd nosuchpayload >/dev/null 2>&1; [ "$?" = 2 ]
check $? "an unknown payload exits 2"

# ── 2. cmd/manifest-cmd compose without root and without touching anything ────
"$SH" cmd pgdata >/dev/null 2>&1
check $? "cmd runs as a normal user (it composes, it does not copy)"

# ── 3. The flags that must be on EVERY payload ────────────────────────────────
for p in pgdata home music; do
    c="$("$SH" cmd "$p" 2>/dev/null)"

    printf '%s' "$c" | grep -q -- "--partial-dir=.rsync-partial"
    check $? "$p: --partial-dir=.rsync-partial is present"

    printf '%s' "$c" | grep -q -- "--append-verify"
    if [ $? -eq 0 ]; then
        fail "$p: uses --append-verify, which assumes the destination is a strict prefix of the source"
    else
        pass "$p: does not use --append-verify"
    fi

    printf '%s' "$c" | grep -q -- "IdentitiesOnly=yes"
    check $? "$p: ssh pins the fleet identity (IdentitiesOnly=yes)"

    printf '%s' "$c" | grep -q -- "id_fleet"
    check $? "$p: ssh names id_fleet"

    printf '%s' "$c" | grep -q -- "rsync-path=sudo"
    check $? "$p: destination runs rsync under sudo (ownership preserved at copy time)"

    printf '%s' "$c" | grep -qE -- "(^| )-x( |$)|(^| )'-x'( |$)"
    check $? "$p: -x (one file system), so the copy and the manifest agree"

    printf '%s' "$c" | grep -q -- "192.168.8.155"
    check $? "$p: targets latitude's LAN address, not the relayed tailnet name"

    printf '%s' "$c" | grep -q -- "gg.ez"
    if [ $? -eq 0 ]; then
        fail "$p: targets a .gg.ez name — that path is DERP-relayed at 3.3 MB/s from this distro"
    else
        pass "$p: does not target a .gg.ez name"
    fi
done

# ── 4. Per-payload flags ──────────────────────────────────────────────────────
pg="$("$SH" cmd pgdata 2>/dev/null)"
printf '%s' "$pg" | grep -qE -- "(^| )'?-a'?( |$)"
check $? "pgdata: -a (perms, owners, times)"
printf '%s' "$pg" | grep -q -- "--numeric-ids"
check $? "pgdata: --numeric-ids, so uid 999 is not renamed on the way over"
printf '%s' "$pg" | grep -q "/data/qaz-law/pgdata/"
check $? "pgdata: source is /data/qaz-law/pgdata/"

mu="$("$SH" cmd music 2>/dev/null)"
printf '%s' "$mu" | grep -qE -- "(^| )'?-a'?( |$)"
if [ $? -eq 0 ]; then
    fail "music: uses -a, which copies drvfs's invented ownership and then fails to set it"
else
    pass "music: does not use -a"
fi
printf '%s' "$mu" | grep -q -- "--no-perms"
check $? "music: --no-perms"
printf '%s' "$mu" | grep -q -- "--no-owner"
check $? "music: --no-owner"
printf '%s' "$mu" | grep -q -- "--modify-window=1"
check $? "music: --modify-window=1 (drvfs timestamp granularity)"
printf '%s' "$mu" | grep -q "/mnt/c/Users/methe/Music/"
check $? "music: source is /mnt/c/Users/methe/Music/"

ho="$("$SH" cmd home 2>/dev/null)"
printf '%s' "$ho" | grep -qE -- "exclude=.*\.sock"
check $? "home: excludes *.sock (the two orca sockets; rsync cannot copy a socket)"
printf '%s' "$pg" | grep -qE -- "exclude=.*\.sock"
if [ $? -eq 0 ]; then
    fail "pgdata: carries the home-only *.sock exclude"
else
    pass "pgdata: does not carry the home-only *.sock exclude"
fi

# ── 5. dry mode ───────────────────────────────────────────────────────────────
printf '%s' "$("$SH" cmd pgdata dry 2>/dev/null)" | grep -qE -- "(^| )'?-n'?( |$)"
check $? "cmd <payload> dry composes rsync -n"
printf '%s' "$pg" | grep -qE -- "(^| )'?-n'?( |$)"
if [ $? -eq 0 ]; then
    fail "cmd <payload> without 'dry' composes a DRY RUN — the real copy would move nothing"
else
    pass "cmd <payload> without 'dry' is not a dry run"
fi

# ── 6. The manifest pipeline ──────────────────────────────────────────────────
# Sizes for regular files ONLY. A directory's reported size is a property of the
# filesystem, not of the content, so comparing it yields false diffs — and on
# drvfs -> ext4 it would make every single directory differ. Sockets are dropped
# on both sides: rsync never copies one, so the two orca sockets would otherwise
# read as two missing files forever.
m="$("$SH" manifest-cmd pgdata src 2>/dev/null)"
printf '%s' "$m" | grep -q "LC_ALL=C"
check $? "manifest: LC_ALL=C (sort order must be byte order on both sides)"
printf '%s' "$m" | grep -q "type f -printf"
check $? "manifest: regular files get a size"
printf '%s' "$m" | grep -q "type l -printf"
check $? "manifest: symlinks record their target"
# Path first, or `sort` orders by size-as-a-string and a single changed size
# relocates its line, turning a one-path diff into a spurious block.
bad=$(printf '%s' "$m" | grep -o -- "-printf '[^']*'" | grep -cv "^-printf '%p")
[ "$bad" = 0 ]
check $? "manifest: every -printf starts with %p, so the manifest sorts by PATH ($bad did not)"
printf '%s' "$m" | grep -q "type s"
check $? "manifest: sockets are handled explicitly"
printf '%s' "$m" | grep -q ".rsync-partial"
check $? "manifest: .rsync-partial is pruned (a parked torn file is not content)"
printf '%s' "$m" | grep -q "du -s"
if [ $? -eq 0 ]; then
    fail "manifest: reaches for du — du totals match even when one file is truncated"
else
    pass "manifest: does not use du"
fi

printf '%s' "$("$SH" manifest-cmd pgdata dst 2>/dev/null)" | grep -q "/mnt/immich-mirror/g15-staging/pgdata"
check $? "manifest-cmd dst points at the staging tree"

"$SH" manifest-cmd pgdata >/dev/null 2>&1; [ "$?" = 2 ]
check $? "manifest-cmd without src|dst exits 2"

# ── 7. The postgres guard ─────────────────────────────────────────────────────
# STAGE_PGPID is overridable so this is testable at all — and because a moved
# PGDATA would need it anyway. Without the guard the copy runs against a live
# postgres and produces a torn tree that looks like a backup.
pid="$(mktemp)"; trap 'rm -f "$pid"' EXIT
STAGE_PGPID="$pid" "$SH" stage pgdata >/dev/null 2>&1; [ "$?" = 3 ]
check $? "stage pgdata refuses with exit 3 while postmaster.pid exists"

# Greps for the OVERRIDE path, not the literal string "postmaster.pid": the
# message names the file it actually checked, and STAGE_PGPID has replaced the
# default here. Asserting the literal would only test that the default is
# hard-coded into the prose.
STAGE_PGPID="$pid" "$SH" stage pgdata 2>&1 | grep -qF "$pid"
check $? "the refusal names the pid file it checked"

# die() takes the exit code as its SECOND argument; printing "$*" instead of
# "$1" appends it to the message. Measured while writing this plan: the root
# refusal ended in a stray " 1".
STAGE_PGPID="$pid" "$SH" stage pgdata 2>&1 | tail -1 | grep -qE '(^| )3$'
if [ $? -eq 0 ]; then
    fail "the refusal message leaks its exit code (die prints \$* instead of \$1)"
else
    pass "the refusal message does not leak its exit code"
fi

STAGE_PGPID="$pid" "$SH" stage home >/dev/null 2>&1; [ "$?" = 3 ]
if [ $? -eq 0 ]; then
    fail "the postgres guard fires for the home payload, which does not touch PGDATA"
else
    pass "the postgres guard is scoped to pgdata"
fi

rm -f "$pid"
STAGE_PGPID="$pid" "$SH" stage pgdata >/dev/null 2>&1; [ "$?" = 1 ]
check $? "with no postmaster.pid, a non-root stage exits 1 (root refusal, guard passed)"

STAGE_PGPID="$pid" "$SH" stage pgdata 2>&1 | grep -q "wsl -d Ubuntu-26.04 -u root"
check $? "the root refusal prints the route to root (sudo needs a password on this distro)"

# ── 8. Env overrides ──────────────────────────────────────────────────────────
STAGE_LAT="me@10.0.0.1" "$SH" cmd pgdata 2>/dev/null | grep -q "me@10.0.0.1"
check $? "STAGE_LAT overrides the destination host"

STAGE_DIR="/srv/elsewhere" "$SH" cmd pgdata 2>/dev/null | grep -q "/srv/elsewhere/pgdata"
check $? "STAGE_DIR overrides the staging root"

if [ "$FAIL" = 0 ]; then echo "ALL PASS"; else echo "$FAIL FAILED" >&2; exit 1; fi
```

- [x] **Step 2: Run the suite to verify it fails**

```bash
bash hosts/g15/staging/stage.test.sh
```

Expected: `FAIL: hosts/g15/staging/stage.sh missing`, exit 1.

- [x] **Step 3: Write `stage.sh`**

Create `hosts/g15/staging/stage.sh`, then `chmod +x` it:

```bash
#!/usr/bin/env bash
# hosts/g15/staging/stage.sh — move g15's payload onto latitude before the
# Windows -> Debian 13 wipe. Phase 1 of
# docs/superpowers/specs/2026-09-07-g15-debian-migration-design.md
#
# RUNS ON g15-wsl, AS ROOT. Not on latitude, not on Windows.
#
#   ./stage.sh cmd          <payload> [dry]   print the rsync command, run nothing
#   ./stage.sh manifest-cmd <payload> src|dst print the manifest pipeline, run nothing
#   ./stage.sh plan         <payload>         rsync -n: what would move
#   ./stage.sh stage        <payload>         the copy (logs to $LOGDIR; detach it)
#   ./stage.sh verify       <payload>         manifest both sides and diff
#   ./stage.sh status                         sizes on both sides + log tails
#
#   payload: pgdata | home | music
#   exit:    0 ok · 1 not root · 2 usage · 3 postgres running · 4 manifest mismatch
#
# WHY ROOT, ALWAYS, EVEN TO LOOK. pgdata's directories are mode 700 owned by
# uid 999, so `find` cannot descend as `me` — the manifest, not just the copy,
# needs root. And `me` has no NOPASSWD sudo here, so root comes from Windows:
#   printf '%s\n' 'cd /home/me/machines/hosts/g15/staging' './stage.sh …' \
#     | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
#
# WHY THE LAN ADDRESS AND NOT latitude.gg.ez. This distro runs in NAT
# networking mode, so tailscale cannot punch through to another NATed peer and
# the tailnet path is DERP-relayed via hub in Kazakhstan — 3.3 MB/s, re-measured
# 2026-09-07 with both laptops on a 1201 Mbps WiFi 6 link, so the radio was
# never the problem. NAT permits OUTBOUND, which is why pushing to latitude's
# LAN address gets 78 MB/s. 293 GB is 63 minutes one way and 20 hours the other.
#
# WHY rsync AND NOT THE CHUNKED TAR THE SPEC NAMES — a deliberate deviation.
# scratchpad/xfer2.sh was chunked because that transfer went through Windows
# sshd -> wsl.exe, where a raw tar stream was the only simple fast path. This
# route is the distro pushing outbound over plain ssh; rsync 3.4.1 is on both
# ends; and there are ZERO hardlinks in either ext4 tree (checked 2026-09-07:
# `find -type f -links +1` is empty for pgdata and for /home/me), which was the
# other thing tar bought. rsync then resumes per file with no marker
# bookkeeping AND lands an extracted tree — which is what the spec's own
# manifest check needs, since chunked tar would have to be extracted on arrival
# before it could be verified at all. The spec's requirement was resumability;
# this satisfies it with less to get wrong.
#
# --partial-dir, NOT --append-verify — the settled answer in this repo, see
# hosts/latitude/debian/archive-mirror.sh's header. A drop mid-file leaves a
# truncated file at the destination; --partial-dir parks it under
# .rsync-partial/ so it is never mistaken for a complete one, and rsync uses it
# as the delta basis next run. --append-verify assumes the destination is a
# strict prefix of the source, which a torn write does not guarantee.
#
# --rsync-path='sudo rsync' because `me` on latitude HAS NOPASSWD sudo (checked
# 2026-09-07) and pgdata's metadata is NOT uniform: 999:999 mode 600 files under
# directories that are 0:0 755, 999:0 700, 999:999 700 and 999:999 755. A
# blanket chown+chmod on restore would get it wrong, so ownership and modes are
# preserved numerically at copy time instead.
#
# NO pv, NO zstd — neither is installed and installing needs the password-gated
# sudo. --info=stats2 is the progress report.
set -uo pipefail

KEY="${STAGE_KEY:-/home/me/.ssh/id_fleet}"
LAT="${STAGE_LAT:-me@192.168.8.155}"
STAGE="${STAGE_DIR:-/mnt/immich-mirror/g15-staging}"
LOGDIR="${STAGE_LOGDIR:-/var/log/g15-staging}"
PGPID="${STAGE_PGPID:-/data/qaz-law/pgdata/18/docker/postmaster.pid}"

# -i + IdentitiesOnly: ssh to a bare IP does NOT pick up the fleet identity,
# because the generated config keys on `Host *.gg.ez`. Without these it fails in
# 0.2 s having moved nothing, which reads exactly like no bandwidth — three
# false measurements on 2026-09-07 came from precisely this.
# ServerAlive*: a 40-minute transfer over wifi needs the connection probed, or a
# silent stall is indistinguishable from progress.
SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
SSH_OPTS="$SSH_OPTS -o ServerAliveInterval=30 -o ServerAliveCountMax=6"

usage() {
    # A heredoc, not `sed -n '5,16p' "$0"`: a line-range into this file's own
    # header drifts silently the first time a comment is added above, and no
    # test catches it — the suite can only assert the exit code.
    cat >&2 <<'USAGE'
stage.sh — move g15's payload onto latitude. Runs ON g15-wsl, AS ROOT.

  ./stage.sh cmd          <payload> [dry]   print the rsync command, run nothing
  ./stage.sh manifest-cmd <payload> src|dst print the manifest pipeline, run nothing
  ./stage.sh plan         <payload>         rsync -n: what would move
  ./stage.sh stage        <payload>         the copy (logs to $LOGDIR; detach it)
  ./stage.sh verify       <payload>         manifest both sides and diff
  ./stage.sh status                         sizes on both sides + log tails

  payload: pgdata | home | music
  exit:    0 ok · 1 not root · 2 usage · 3 postgres running · 4 manifest mismatch
USAGE
    exit 2
}
# "$1", NOT "$*": the second argument is the exit code, and $* would print it
# as part of the message — measured, the root refusal ended in a stray " 1".
die()  { printf '%s: %s\n' "${0##*/}" "$1" >&2; exit "${2:-1}"; }
say()  { printf '[%s] %s\n' "$(date +%F_%H:%M:%S)" "$*"; }

require_root() {
    [ "1000 4 24 27 30 46 100 1000 1001id -u)" = 0 ] && return 0
    # $MODE/$P rather than "$@": the caller passes nothing, and the point of the
    # message is to hand back a runnable line.
    die "must run as root (pgdata's dirs are mode 700 owned by uid 999, so even
find cannot descend as $(id -un); and sudo needs a password on this distro).
Route:
  printf '%s\\n' 'cd $(cd "$(dirname "$0")" && pwd)' './${0##*/} $MODE $P' \\
    | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'" 1
}

payload_src() {
    case "$1" in
        pgdata) printf '%s\n' /data/qaz-law/pgdata ;;
        home)   printf '%s\n' /home/me ;;
        music)  printf '%s\n' /mnt/c/Users/methe/Music ;;
        *)      return 1 ;;
    esac
}

payload_dst() {
    case "$1" in
        pgdata) printf '%s\n' "$STAGE/pgdata" ;;
        home)   printf '%s\n' "$STAGE/home-me" ;;
        music)  printf '%s\n' "$STAGE/Music" ;;
        *)      return 1 ;;
    esac
}

payload_flags() {
    # -x on every payload so the copy and the manifest's pruning agree about
    # where the tree ends.
    case "$1" in
        pgdata)
            printf '%s\n' -a -x --numeric-ids ;;
        home)
            # rsync cannot copy a socket; without the exclude it prints
            # "skipping non-regular file" and exits 23, which then has to be
            # distinguished from a real error on every run.
            printf '%s\n' -a -x --numeric-ids '--exclude=*.sock' ;;
        music)
            # drvfs invents ownership and permissions for every NTFS file, so -a
            # would copy fiction and then fail to set it. Same shape
            # archive-mirror.sh uses for exfat, for the same reason. mtimes ARE
            # real, hence -t and --modify-window=1 for the granularity.
            printf '%s\n' -rlt -x --no-perms --no-owner --no-group --modify-window=1 ;;
        *)  return 1 ;;
    esac
}

CMD=()
build_cmd() {   # $1 payload  $2 dry|go
    local src dst
    src="$(payload_src "$1")" || return 1
    dst="$(payload_dst "$1")" || return 1
    local -a f=()
    mapfile -t f < <(payload_flags "$1")
    f+=(--partial --partial-dir=.rsync-partial '--exclude=.rsync-partial/'
        --human-readable --info=stats2)
    [ "$2" = dry ] && f+=(-n)
    CMD=(rsync "${f[@]}" -e "ssh $SSH_OPTS" --rsync-path='sudo rsync'
         "$src/" "$LAT:$dst/")
    return 0
}

# The manifest: PATH, type, size, symlink target — one line per entry, with a
# size for REGULAR FILES ONLY. A directory's reported size is a property of the
# filesystem rather than of its contents, so comparing it produces false diffs,
# and across drvfs -> ext4 it would make every single directory differ. Sockets
# are dropped on both sides because rsync never copies one. .rsync-partial is
# pruned: a parked torn file is not content.
#
# PATH IS THE FIRST FIELD, and that is not cosmetic. With the size first, `sort`
# orders by size as a STRING (5000 before 6), so the manifest is not in path
# order and one file whose size differs moves its line to a different position
# entirely — the diff then reports a large spurious block instead of pointing at
# the one path that is wrong. Caught while writing this plan, on exactly that
# tree of test entries.
#
# Compared on both sides with `diff`, and NEVER with `du`: du totals match even
# when one file is truncated, which is exactly what a killed transfer leaves.
manifest_find() {
    cat <<'MF'
LC_ALL=C find . -mindepth 1 -name .rsync-partial -prune -o \
  \( -type f -printf '%p\tf\t%s\n' \) -o \
  \( -type l -printf '%p\tl\t-\t%l\n' \) -o \
  \( -type s \) -o \
  \( -printf '%p\t%y\t-\n' \) | LC_ALL=C sort
MF
}

manifest_cmd() {   # $1 payload  $2 src|dst
    local d
    case "$2" in
        src) d="$(payload_src "$1")" || return 1 ;;
        dst) d="$(payload_dst "$1")" || return 1 ;;
        *)   return 1 ;;
    esac
    printf 'cd %q && \\\n' "$d"
    manifest_find
}

MODE="${1:-}"; P="${2:-}"; ARG="${3:-}"

case "$MODE" in
    cmd)
        [ -n "$P" ] || usage
        build_cmd "$P" "${ARG:-go}" || die "unknown payload: $P" 2
        printf '%q ' "${CMD[@]}"; printf '\n'
        ;;

    manifest-cmd)
        [ -n "$P" ] || usage
        case "$ARG" in src|dst) ;; *) usage ;; esac
        manifest_cmd "$P" "$ARG" || die "unknown payload: $P" 2
        ;;

    plan)
        [ -n "$P" ] || usage
        build_cmd "$P" dry || die "unknown payload: $P" 2
        require_root
        say "dry run: $P"
        "${CMD[@]}"
        ;;

    stage)
        [ -n "$P" ] || usage
        payload_src "$P" >/dev/null || die "unknown payload: $P" 2
        # The guard comes BEFORE the root check so it is reachable in the gate,
        # and because "postgres is still running" is the more useful message of
        # the two when both are true.
        if [ "$P" = pgdata ] && [ -e "$PGPID" ]; then
            die "postgres is still running — $PGPID exists.
A live PGDATA copies torn, and the result looks exactly like a backup; see
hosts/latitude/debian/mirror-refresh.sh's header. Stop it first:
  docker update --restart=no qaz-law-db-1 && docker stop qaz-law-db-1" 3
        fi
        require_root
        build_cmd "$P" go || die "unknown payload: $P" 2
        mkdir -p "$LOGDIR" && chmod 755 "$LOGDIR"
        # 755 so the log is tailable over the DIRECT ssh into the distro as
        # `me`, instead of every progress check having to go back through
        # Windows for root.
        exec >>"$LOGDIR/$P.log" 2>&1
        say "=== stage $P"
        say "src=$(payload_src "$P")  dst=$LAT:$(payload_dst "$P")"
        ssh $SSH_OPTS "$LAT" "sudo mkdir -p $(payload_dst "$P") && sudo chown me:me $(payload_dst "$P")" </dev/null \
            || die "could not create the destination directory"
        "${CMD[@]}"; rc=$?
        case "$rc" in
            0)  say "rsync clean" ;;
            24) say "rsync exit 24 (source files vanished mid-run) — benign here, treating as done"; rc=0 ;;
            *)  say "rsync exit $rc — re-run 'stage $P', it resumes from .rsync-partial" ;;
        esac
        say "=== done rc=$rc"
        exit $rc
        ;;

    verify)
        [ -n "$P" ] || usage
        payload_src "$P" >/dev/null || die "unknown payload: $P" 2
        require_root
        mkdir -p "$LOGDIR" && chmod 755 "$LOGDIR"
        s="$LOGDIR/$P.src.manifest"; d="$LOGDIR/$P.dst.manifest"
        say "manifest: source $(payload_src "$P")"
        manifest_cmd "$P" src | bash > "$s" || die "source manifest failed"
        say "manifest: destination $LAT:$(payload_dst "$P")"
        manifest_cmd "$P" dst | ssh $SSH_OPTS "$LAT" 'sudo bash -s' > "$d" \
            || die "destination manifest failed"
        sn=$(wc -l < "$s"); dn=$(wc -l < "$d")
        say "entries: src=$sn dst=$dn"
        if cmp -s "$s" "$d"; then
            say "MANIFEST MATCH — $sn entries, path+size+symlink-target identical"
        else
            say "MANIFEST MISMATCH — first 40 differing lines:"
            diff -u "$s" "$d" | head -40
            say "full manifests: $s and $d"
            exit 4
        fi
        ;;

    status)
        require_root
        for p in pgdata home music; do
            printf '%-7s %8s  %s\n' "$p" \
                "$(du -sh "$(payload_src "$p")" 2>/dev/null | cut -f1)" \
                "$(payload_src "$p")"
        done
        printf -- '--- destination:\n'
        ssh $SSH_OPTS "$LAT" "df -h $STAGE; sudo du -sh $STAGE/* 2>/dev/null" </dev/null
        printf -- '--- logs:\n'
        for f in "$LOGDIR"/*.log; do
            [ -e "$f" ] || continue
            printf '%s:\n' "$f"; tail -3 "$f" | sed 's/^/  /'
        done
        ;;

    *)  usage ;;
esac
```

- [x] **Step 4: Run the suite to verify it passes**

```bash
chmod +x hosts/g15/staging/stage.sh
bash hosts/g15/staging/stage.test.sh
```

Expected: every line `PASS`, last line `ALL PASS`, exit 0.

- [x] **Step 5: Run the whole gate**

```bash
for t in $(just _test-suites); do bash "$t" < /dev/null || echo "FAILED: $t"; done
```

Expected: no `FAILED:` lines. (`just` is not installed on every box — on one without it, use `find . -name '*.test.sh' -not -path './.git/*' | sed 's|^\./||' | LC_ALL=C sort` in place of `just _test-suites`, which is exactly what that recipe is.) The suite count goes from 49 to 50.

- [x] **Step 6: Commit and push**

```bash
git add hosts/g15/staging/stage.sh hosts/g15/staging/stage.test.sh
git commit -m "feat(g15): the phase-1 staging tool, and a suite that pins its flags

293 GB has to leave g15 correctly on the first attempt — the disk is wiped
after. So stage.sh separates composing an rsync command from running it, and
stage.test.sh asserts the composition on any box, non-root, with no network.

Deviates from the spec's chunked-tar mandate, deliberately: xfer2.sh was
chunked because it ran through Windows sshd -> wsl.exe, where a raw tar stream
was the only simple fast path. This route is the distro pushing outbound over
plain ssh, both ends have rsync 3.4.1, and neither ext4 tree has a single
hardlink. rsync resumes per file with no marker bookkeeping and lands an
extracted tree, which is what the spec's own manifest check needs."
git push
```

---

### Task 2: The three gates before a byte moves

**Files:**
- Create: `hosts/g15/staging/identity-snapshot.txt`

**Interfaces:**
- Consumes: nothing.
- Produces: a live distro with a verified keepalive holder; `latitude:/mnt/immich-mirror/g15-staging/` existing and owned by `me`; the identity record committed.

- [ ] **Step 1: Confirm OneDrive has actually finished uploading — by hand, on the box**

This is a **manual step and stays one.** The spec's disposition for `OneDrive` (3.7 GB: Documents, Desktop, Pictures) is *no action, already in the cloud* — and that is only true if the client has finished, not if the folder merely exists. There is no reliable command for "is OneDrive caught up"; the client's own UI is the authority.

On g15, in the Windows session: click the OneDrive cloud icon in the tray. It must read **"Your files are up to date"** — not "Syncing", not "Processing changes", not a paused icon. Then in File Explorer open `C:\Users\methe\OneDrive` and confirm the Status column shows green checks or cloud icons, with no ⟳ arrows.

**If it is NOT up to date:** let it finish before continuing. If it cannot finish (a stuck file, an account problem), OneDrive becomes a fourth payload rather than a no-action item — add these two arms to `stage.sh` and re-run its suite:

```bash
        onedrive) printf '%s\n' /mnt/c/Users/methe/OneDrive ;;   # in payload_src
        onedrive) printf '%s\n' "$STAGE/OneDrive" ;;             # in payload_dst
        onedrive)                                                # in payload_flags
            printf '%s\n' -rlt -x --no-perms --no-owner --no-group --modify-window=1 ;;
```

It reads through `/mnt/c` and is drvfs, so it takes the `music` flag set verbatim. 3.7 GB adds under a minute.

- [ ] **Step 2: Re-arm the keepalive, and verify it by PID**

`State: Ready` means *not running*. The task last ran 2026-09-05 21:42 and exited `3221225786` (`STATUS_CONTROL_C_EXIT`) — it was killed. The distro is currently up only because stray `wsl.exe` clients from interactive sessions happen to be attached, and a distro dies when the last one detaches, taking any `setsid nohup`'d transfer with it.

From this box, base64 the script because PowerShell over ssh eats quotes:

```bash
SP=/tmp/claude-1000/-home-me-machines/scratch; mkdir -p "$SP"
cat > "$SP"/ka.ps1 <<'PS'
Start-ScheduledTask -TaskName 'wsl-keepalive'
Start-Sleep -Seconds 3
$i = Get-ScheduledTaskInfo -TaskName 'wsl-keepalive'
"state:  $((Get-ScheduledTask -TaskName 'wsl-keepalive').State)"
"lastrun: $($i.LastRunTime)  result: $($i.LastTaskResult)"
PS
iconv -f UTF-8 -t UTF-16LE "$SP"/ka.ps1 | base64 -w0 > "$SP"/ka.b64
ssh methe@g15.gg.ez "powershell -NoProfile -EncodedCommand $(cat "$SP"/ka.b64)"
```

Expected: `state: Running`.

Then the check that actually matters — the holder process inside the distro:

```bash
ssh g15-wsl.gg.ez 'ps -eo pid,user,args | grep -F "sleep infinity" | grep -v grep'
```

Expected: one line, `root ... /bin/sleep infinity`. **If that line is absent, stop here.** `State: Running` without the PID means the task fired and the client detached again, and a 40-minute transfer will not survive. Re-run `Start-ScheduledTask`; if the PID still never appears, hold the distro up for the duration with a foreground client instead and keep it open:

```bash
ssh -o ServerAliveInterval=30 methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- /bin/sleep 14400'
```

- [ ] **Step 3: Create the staging root on latitude**

```bash
ssh latitude.gg.ez 'sudo mkdir -p /mnt/immich-mirror/g15-staging && \
  sudo chown me:me /mnt/immich-mirror/g15-staging && \
  df -h /mnt/immich-mirror && ls -ld /mnt/immich-mirror/g15-staging'
```

Expected: the directory exists owned by `me:me`, and `Avail` is at least **293 GB**. It was 610 GB on 2026-09-07. If it is under 350 GB, stop and find out what grew — the immich mirror shares this drive.

- [ ] **Step 4: Record the identity set**

The spec's phase 0 asks for the identities that must move together. Capture them from live commands rather than retyping them:

```bash
{
  printf 'g15 identity snapshot — %s\n' "$(date -u +%FT%TZ)"
  printf '\n## tailnet nodes (tailscale status)\n'
  tailscale status | grep -E '^100\.64\.0\.(3|9) '
  printf '\n## fleet-authorized-keys entries\n'
  grep -n -E 'methe@g15$|me@g15-wsl$' provision/fleet-authorized-keys
  printf '\n## dotfiles branches\n'
  printf 'g15-wsl: %s\n' "$(ssh g15-wsl.gg.ez 'git --git-dir=$HOME/.dotfiles --work-tree=$HOME rev-parse --abbrev-ref HEAD')"
  printf '\n## what phase 5 does with each of these\n'
  cat <<'NOTE'
100.64.0.3  g15      windows -> becomes linux; the NODE IS KEPT, g15 inherits it
100.64.0.9  g15-wsl  linux   -> RETIRED with the distro
fleet-authorized-keys: methe@g15 kept; me@g15-wsl removed
dotfiles branch g15-wsl: retired. Its host-local content is not on main, so the
  only copies of those files are the branch on the remote and the /home/me
  staging copy from Task 6. Do not delete the branch in phase 5 — leave it.
NOTE
} > hosts/g15/staging/identity-snapshot.txt

cat hosts/g15/staging/identity-snapshot.txt
```

Expected: two tailnet rows, two `fleet-authorized-keys` line numbers (40 and 41 as of `de1fad2`), and `g15-wsl: g15-wsl`.

- [ ] **Step 5: Commit the snapshot**

```bash
git add hosts/g15/staging/identity-snapshot.txt
git commit -m "docs(g15): the identity set phase 1 has to preserve

Captured live rather than retyped. The load-bearing line is the last one: the
g15-wsl dotfiles branch holds host-local files that are on no other branch, so
retiring the distro in phase 5 must not delete the branch."
git push
```

---

### Task 3: Quiesce postgres and prove the shutdown was clean

**Files:** none — this task changes state on g15-wsl only.

**Interfaces:**
- Consumes: Task 2's live distro.
- Produces: `postmaster.pid` absent from `/data/qaz-law/pgdata/18/docker`, which is what unblocks `stage.sh stage pgdata`.

- [ ] **Step 1: Take the restart policy off the container first**

`qaz-law-db-1` has `restart: always`. Stopping it by hand is not enough — a docker daemon restart, or a WSL bounce, brings postgres back up and starts writing into the tree that is being copied. Set the policy before the stop, so there is no window:

```bash
ssh g15-wsl.gg.ez 'docker update --restart=no qaz-law-db-1 && \
  docker inspect qaz-law-db-1 --format "restart={{.HostConfig.RestartPolicy.Name}}"'
```

Expected: `restart=no`.

This is **not undone.** The container dies with the disk in Phase 2; the new box gets a fresh one in Phase 4. Restoring `always` here would only reopen the hole.

- [ ] **Step 2: Stop the container**

```bash
ssh g15-wsl.gg.ez 'docker stop -t 120 qaz-law-db-1 && \
  docker inspect qaz-law-db-1 --format "state={{.State.Status}} exit={{.State.ExitCode}}"'
```

Expected: `state=exited exit=0`. The `-t 120` matters: `docker stop`'s default 10-second grace, on a 186 GB database with 8 GB of shared buffers, can expire mid-checkpoint and escalate to `SIGKILL`, which is an unclean shutdown — recoverable by postgres, but it leaves a WAL replay that a *physical copy* then has to carry, and there is no reason to accept that when waiting is free.

- [ ] **Step 3: Prove the shutdown was clean — two independent checks**

```bash
ssh g15-wsl.gg.ez 'docker logs --tail 20 qaz-law-db-1 2>&1 | tail -8'
```

Expected: the log ends with `database system is shut down`. Absent that, look for `received smart shutdown request` / `shutting down` / `checkpoint complete` and no `received immediate shutdown request`.

The log line can scroll, so check the file-level evidence too:

```bash
printf '%s\n' \
  'ls -l /data/qaz-law/pgdata/18/docker/postmaster.pid 2>&1' \
  'echo "---"' \
  'ls -1 /data/qaz-law/pgdata/18/docker/ | head -20' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: `No such file or directory` for `postmaster.pid`. **A present `postmaster.pid` after an `exited` container means the shutdown was not clean** — start the container, stop it again with `-t 120`, and re-check. `stage.sh` refuses with exit 3 while that file exists, so this check and the tool agree.

---

### Task 4: Stage `pgdata` — 186 GB, ~40 minutes

**Files:** none — this task produces `latitude:/mnt/immich-mirror/g15-staging/pgdata/`.

**Interfaces:**
- Consumes: Task 1's `stage.sh` (present on g15-wsl at `/home/me/machines/hosts/g15/staging/`), Task 2's staging root, Task 3's stopped postgres.
- Produces: the staged tree, and `/var/log/g15-staging/pgdata.log`.

- [ ] **Step 1: Get the tool onto the box**

`~/machines` on g15-wsl is a normal checkout (at `de1fad2`, clean, as of 2026-09-07):

```bash
ssh g15-wsl.gg.ez 'cd ~/machines && git pull --ff-only && \
  ls -l hosts/g15/staging/stage.sh && git log --oneline -1'
```

Expected: the file is present and executable, and HEAD is at or past **Task 1's** commit — that is the one that adds `stage.sh`. Task 2's identity-snapshot commit is later and irrelevant here; the plan document itself (`c331260`) does not contain the tool.

- [ ] **Step 2: Dry run**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh plan pgdata 2>&1 | tail -20' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: rsync's stats block reporting about **1268 regular files and ~186 GB** to transfer, and no `Permission denied`. If it reports 0 files, the destination already holds the tree — check `stage.sh status` before assuming the source is empty.

- [ ] **Step 3: Launch it detached**

`setsid --fork` so it survives the ssh session; the script redirects its own output to the log, so no shell redirection has to survive PowerShell:

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  'setsid --fork ./stage.sh stage pgdata' \
  'sleep 3' \
  'ps -eo pid,etime,args | grep -F "stage.sh stage pgdata" | grep -v grep' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: one `ps` line showing the running script. No output there means it exited immediately — read the log in the next step for why.

- [ ] **Step 4: Watch it, over the direct ssh**

The log is world-readable by design, so progress checks do not have to go back through Windows for root:

```bash
ssh g15-wsl.gg.ez 'tail -f /var/log/g15-staging/pgdata.log'
```

Expected: the `=== stage pgdata` header, then rsync's `--info=stats2` output. Budget **~40 minutes** (186 GB at 78 MB/s). Ctrl-C on the `tail` does not touch the transfer.

If it dies mid-run, re-run Step 3 verbatim — rsync picks the partial file up from `.rsync-partial/` and continues. That is what `--partial-dir` is for.

- [ ] **Step 5: Confirm it finished cleanly**

```bash
ssh g15-wsl.gg.ez 'tail -6 /var/log/g15-staging/pgdata.log'
```

Expected: `rsync clean` then `=== done rc=0`. Any other `rc` is reported with the resume instruction; re-run Step 3. **Do not proceed to Task 5 on a non-zero rc** — the link is shared and a half-finished payload competing with the next one only makes both slower.

---

### Task 5: Stage `Music` — 89 GB, ~19 minutes

**Files:** none — this task produces `latitude:/mnt/immich-mirror/g15-staging/Music/`.

**Interfaces:**
- Consumes: Task 1's `stage.sh`, Task 4's finished transfer (the payloads share one link and run one at a time).
- Produces: the staged tree, and `/var/log/g15-staging/music.log`.

- [ ] **Step 1: Dry run**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh plan music 2>&1 | tail -20' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: about **14 878 files and ~89 GB**. Read from `/mnt/c/Users/methe/Music` inside the distro — there is no separate Windows-side transfer, and `desktop.ini` in that tree is expected and harmless.

- [ ] **Step 2: Launch it detached**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  'setsid --fork ./stage.sh stage music' \
  'sleep 3' \
  'ps -eo pid,etime,args | grep -F "stage.sh stage music" | grep -v grep' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: one `ps` line.

- [ ] **Step 3: Watch it and confirm**

```bash
ssh g15-wsl.gg.ez 'tail -f /var/log/g15-staging/music.log'
```

Expected: `rsync clean`, `=== done rc=0`, in **~19 minutes**. Reads come through drvfs (`/mnt/c`), which is slower per-file than ext4, so 14 878 files may run somewhat behind the byte-rate budget — that is expected, not a fault.

---

### Task 6: Stage `/home/me` — 18 GB, first pass

**Files:** none — this task produces `latitude:/mnt/immich-mirror/g15-staging/home-me/`.

**Interfaces:**
- Consumes: Task 1's `stage.sh`, Task 5's finished transfer.
- Produces: the staged tree, and `/var/log/g15-staging/home.log`. **This copy is not final** — Task 8 re-runs it as a delta with the box quiesced.

- [ ] **Step 1: Dry run**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh plan home 2>&1 | tail -20' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: roughly **226 000 files and ~18 GB**, and no `skipping non-regular file` lines — `--exclude=*.sock` covers the two orca sockets. If such a line does appear, a new socket was created under a name that does not end in `.sock`; add it to the exclude list rather than accepting exit 23.

- [ ] **Step 2: Launch it detached**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  'setsid --fork ./stage.sh stage home' \
  'sleep 3' \
  'ps -eo pid,etime,args | grep -F "stage.sh stage home" | grep -v grep' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: one `ps` line.

- [ ] **Step 3: Watch it and confirm**

```bash
ssh g15-wsl.gg.ez 'tail -f /var/log/g15-staging/home.log'
```

Expected: `rsync clean`, `=== done rc=0`. 18 GB is 4 minutes of bytes, but 226 000 files carry real per-file cost, so budget **10–20 minutes**.

`rc=24` (source files vanished mid-run) is treated as done by the script, and on a live home directory it is the *likely* outcome — a shell history file or an editor swap file disappearing between the file list and the transfer. That is precisely why Task 8 exists and why this pass is not the one the manifest is taken from.

- [ ] **Step 4: Check the total against the budget**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh status' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: source sizes near 186G / 18G / 89G, destination sizes within a percent or two of each, and `Avail` on `/mnt/immich-mirror` down by about 293 GB to roughly 315 GB.

**These `du` numbers are orientation, not verification.** A `du` total matches even when one file is truncated, which is exactly what a killed transfer leaves behind. Task 7 is the verification.

---

### Task 7: Verify all three payloads by manifest

**Files:** none — this task reads both sides and writes manifests to `/var/log/g15-staging/`.

**Interfaces:**
- Consumes: Tasks 4, 5 and 6.
- Produces: `<payload>.src.manifest` and `<payload>.dst.manifest` on g15-wsl for each payload, and a `MANIFEST MATCH` line for each.

- [ ] **Step 1: Verify `pgdata`**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh verify pgdata' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: `entries: src=N dst=N` with the two equal, then `MANIFEST MATCH — N entries, path+size+symlink-target identical`. Exit 4 with a diff means a real discrepancy: re-run `stage.sh stage pgdata` (it resumes), then verify again.

- [ ] **Step 2: Verify `music`**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh verify music' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: `MANIFEST MATCH`. Note what this check deliberately does not compare: mode, ownership and mtime. On drvfs all three are invented by the filesystem, so comparing them would report thousands of differences that mean nothing. Path, size and symlink target are the content.

- [ ] **Step 3: Verify `home` — and expect a small mismatch here**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh verify home' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: **either** `MANIFEST MATCH`, **or** exit 4 with a handful of differing lines under `.cache/`, `.local/state/`, `.bash_history`, `.zsh_history`, `.config/orca/` or a `.claude/projects/` transcript.

A mismatch here is not a failure of the copy — `/home/me` is a live tree and the manifest is taken minutes after the transfer. Read the diff and confirm every differing line is a file that changed after the copy, then continue: Task 8 is what settles it. **A differing line anywhere else — under `my/`, `.ssh/`, `.gnupg/` — is a real problem and stops the plan.**

- [ ] **Step 4: Record the three verdicts where the next phase can find them**

```bash
ssh g15-wsl.gg.ez 'grep -h MANIFEST /var/log/g15-staging/*.log | tail -20'
```

Expected: one `MANIFEST MATCH` line for `pgdata` and one for `music`, each naming its entry count. Those two are now final and must not be re-copied: `pgdata` because postgres is stopped and stays stopped, `music` because nothing on the box writes to it.

---

### Task 8: The final `/home/me` delta — the point of no return

**Files:** none.

**Interfaces:**
- Consumes: Tasks 4 through 7.
- Produces: a `MANIFEST MATCH` for `home` taken on a quiesced box. **This is the gate the spec names: "phase 1's manifest check is the point of no return and must pass before the installer boots."**

**Run this immediately before Phase 2, not right after Task 7.** Days may pass between them; that is fine and expected. What must not happen is booting the installer on the strength of Task 7's `home` verdict, which was taken while the box was in use.

- [ ] **Step 1: Quiesce the box**

Close every editor, terminal, Orca window and agent session that writes under `/home/me` on g15-wsl. Then confirm nothing is still writing:

```bash
ssh g15-wsl.gg.ez 'who; echo "---"; ps -eo user,pid,args | grep -E "^me " | grep -vE "sshd|ps -eo|grep" | head -20'
```

Expected: only the ssh session running this check. A leftover `orca`, `node`, `claude` or shell is what makes this pass unreliable — end it before continuing. The one process that must **stay** is the keepalive's `sleep infinity`, which runs as root and does not appear in this list.

- [ ] **Step 2: Run the delta**

Small enough to run in the foreground and watch:

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh stage home' \
  'tail -20 /var/log/g15-staging/home.log' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: a few hundred MB at most, `rsync clean`, `=== done rc=0`. A large delta means something is still running — go back to Step 1.

- [ ] **Step 3: Verify, and this time demand an exact match**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh verify home' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: `MANIFEST MATCH`, exit 0, **no tolerated differences.** Unlike Task 7 Step 3, a diff here is a stop: either something is still writing (back to Step 1) or the copy is genuinely incomplete (re-run Step 2).

- [ ] **Step 4: Re-confirm `pgdata` has not moved since Task 7**

Cheap, and it catches the one thing that silently invalidates the largest payload — postgres having been started again in the meantime:

```bash
printf '%s\n' \
  'ls -l /data/qaz-law/pgdata/18/docker/postmaster.pid 2>&1' \
  'docker inspect qaz-law-db-1 --format "state={{.State.Status}} restart={{.HostConfig.RestartPolicy.Name}}" 2>&1 </dev/null' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: `No such file or directory`, and `state=exited restart=no`. If postgres was started, its manifest is stale: stop it again per Task 3 and re-run `stage.sh stage pgdata` and `verify pgdata` before the installer boots.

- [ ] **Step 5: Declare phase 1 done, and say what that permits**

```bash
ssh g15-wsl.gg.ez 'grep -h MANIFEST /var/log/g15-staging/*.log | tail -6; \
  echo "---"; ls -l /var/log/g15-staging/*.manifest'
ssh latitude.gg.ez 'df -h /mnt/immich-mirror; sudo du -sh /mnt/immich-mirror/g15-staging/*'
```

Expected: a `MANIFEST MATCH` for each of `pgdata`, `music` and `home`; three payload directories on latitude totalling ~293 GB; `Avail` around 315 GB.

**With those three lines present, Phase 2 may boot the installer. Without all three, it may not.** Nothing on g15 has been destroyed up to this point, so this is the last moment at which rollback is free.

The staging copy stays on latitude until the rebuilt box has run for a week, then is deleted deliberately — not left to be reclaimed by accident.

---

## Self-review

**Spec coverage.** Phase 0's OneDrive confirmation → Task 2 Step 1; its identity record → Task 2 Steps 4–5. Phase 1's transport (`ssh -i ~/.ssh/id_fleet -o IdentitiesOnly=yes me@192.168.8.155`) → `stage.sh`'s `SSH_OPTS` and `LAT`, pinned by the suite. Its item 1 (stop postgres cleanly) → Task 3, with two independent proofs. Its item 2 (resumable, an interruption costs one chunk) → satisfied by `--partial-dir` per-file resume instead of chunk markers, which is a **stated deviation** argued in `stage.sh`'s header and in Task 1's commit message: xfer2.sh's chunking existed because that route ran through `wsl.exe`, and rsync additionally lands the extracted tree the manifest check requires. Its item 3 (`Music` via `/mnt/c`) → Task 5. Its manifest check, "never by `du`" → Task 7 and `stage.sh verify`, with the `du` reach explicitly failed by the suite. Its budget (~1 h 5 m) → 40 + 19 + 15 minutes across Tasks 4–6. Its point-of-no-return rule → Task 8.

Two things this plan adds that the spec does not state. The keepalive gate (Task 2 Step 2) — the spec assumes the distro stays up, and it is currently held only by stray `wsl.exe` orphans while the task that should hold it died on 2026-09-05. And the final quiesced `/home/me` delta (Task 8) — the spec says the manifest check is the point of no return without saying that a manifest of a *live* home directory cannot be that check.

One spec item is deliberately out of scope: `Downloads` (2.2 GB, "owner reviews before the wipe"). That is a human review with no staging step, and inventing a copy for it would contradict the spec's own disposition. It belongs in Phase 2's pre-wipe checklist.

**Both code blocks were extracted from this document and run before it was committed**, on desktop-wsl, non-root, with no g15 and no latitude involved. `bash -n` passes on both; the suite reports **ALL PASS** (59 assertions) against the script exactly as written above. Three defects were found that way and are fixed in the text: the manifest sorted by size-as-a-string instead of by path; `die()` printed `"$*"`, appending its exit-code argument to the message (the root refusal ended in a stray ` 1`); and `usage()` was a `sed` line-range into the script's own header, which drifts the first time a comment is added above it. The two assertions that pin the last two were mutation-tested by reintroducing each bug. The manifest pipeline was separately run against a tree carrying a regular file, a symlink, a broken symlink, a fifo, a socket and a `.rsync-partial/` directory, and handles all six as this plan claims.

**The repo gate was not re-run for this change and does not need to be** — the change adds a markdown file and no executable. `stage.sh` and its suite land in Task 1, and Task 1 Step 5 runs the gate there.

**Placeholder scan.** No `TBD`, no "add error handling", no "similar to Task N". Every code step carries the code. The one manual step (Task 2 Step 1) is manual on purpose and says exactly what to look at, with the concrete four-line fallback if the answer is no.

**Name consistency.** Payload tokens are `pgdata` / `home` / `music` everywhere — in `payload_src`, `payload_dst`, `payload_flags`, the `stage.sh` modes, the suite's loop, and every task's commands. Destination directories are `pgdata` / `home-me` / `Music` (asymmetric on purpose: `home-me` names the box's user, `Music` matches what comes back). Env overrides are `STAGE_LAT` / `STAGE_DIR` / `STAGE_KEY` / `STAGE_LOGDIR` / `STAGE_PGPID`, all read in `stage.sh` and the last three exercised by the suite. Log paths are `/var/log/g15-staging/<payload>.log` in the script and in every task that tails one. Exit codes 0/1/2/3/4 are defined in the header, produced by `require_root`, `usage`, `die … 3` and `verify`, and asserted by the suite.
