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
