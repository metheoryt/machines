#!/usr/bin/env bash
# Behavioural tests for the git-autofetch script that tier_autofetch generates.
#
# WHY THESE ARE BEHAVIOURAL, NOT GREPS: the bug that motivated them was invisible
# to any static check. `timeout 60 git fetch` is a perfectly well-formed line —
# it just does not run on macOS, where timeout(1) does not exist. A test asserting
# "the script contains a timeout call" passed the whole time the script fetched
# nothing. So each case below runs the real generated script and asserts that refs
# MOVED, or that a hang was killed, or that a total failure exited non-zero.
#
# No root, no network: the fixture remotes are local bare repos reached by path,
# so `git fetch` is a real fetch with a real refs update and no transport.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIERS="$HERE/../lib/tiers.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }

tmp="$(cd -P "$(mktemp -d)" && pwd)"; trap 'rm -rf "$tmp"' EXIT

# ── Extract the script exactly as tier_autofetch writes it ────────────────────
# Pulling the heredoc body out of tiers.sh (rather than calling tier_autofetch)
# keeps the test faithful to the deployed bytes while skipping the tier's
# launchd/systemd scheduling, which must never run from a test.
AF="$tmp/git-autofetch"
awk "/^  cat > \"\\\$AF\" <<'AUTOFETCH'\$/{f=1;next} /^AUTOFETCH\$/{f=0} f" "$TIERS" > "$AF"
chmod +x "$AF"
[ -s "$AF" ] || { echo "FAIL could not extract the heredoc from tiers.sh"; exit 1; }
pass "extracted the generated script from tiers.sh"

G() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }

# fixture <name> — a work repo whose origin is a local bare repo that has since
# advanced by one commit, so a real fetch must move refs/remotes/origin/main.
fixture() {
    local name="$1" root="$2"
    G init -q --bare "$tmp/$name.git"
    mkdir -p "$root/$name"
    G init -q -b main "$root/$name"
    ( cd "$root/$name" \
      && : > a && G add a && G commit -qm A \
      && G remote add origin "$tmp/$name.git" \
      && G push -q -u origin main ) >/dev/null 2>&1
    # Advance the remote from a throwaway clone.
    G clone -q "$tmp/$name.git" "$tmp/$name-push" >/dev/null 2>&1
    ( cd "$tmp/$name-push" && : > b && G add b && G commit -qm B && G push -q ) >/dev/null 2>&1
}

otm() { git -C "$1" rev-parse --verify -q refs/remotes/origin/main || echo NONE; }

# ── Case 1: the real timeout(1) path (Linux, or macOS with coreutils) ─────────
r1="$tmp/r1"; fixture repo1 "$r1"
before="$(otm "$r1/repo1")"
GIT_AUTOFETCH_ROOTS="$r1" sh "$AF" >"$tmp/o1" 2>"$tmp/e1"; rc1=$?
after="$(otm "$r1/repo1")"
eq "$rc1" "0" "exits 0 when the fetch succeeds"
[ "$before" != "$after" ] && [ "$after" != NONE ] \
  && pass "refs actually moved (default PATH)" \
  || die "refs did not move (default PATH): $before -> $after"

# ── Case 2: THE REGRESSION — no timeout(1) anywhere on PATH ───────────────────
# Masking means ABSENT, not stubbed: the script probes with `command -v`, so a
# non-executable or exit-127 stub would still be "found" and prove nothing. A
# PATH holding only the binaries the script needs is the only honest mask.
mask="$tmp/mask"; mkdir -p "$mask"
# `sh` belongs in the mask too: PATH is what resolves the interpreter in
# `PATH="$mask" sh "$AF"`, so omitting it makes every masked case die 127 before
# the script is even read — which looks exactly like the bug under test.
for b in sh git find dirname sleep mktemp rm; do
    p="$(command -v "$b" 2>/dev/null)" || { die "cannot mask PATH: no $b"; continue; }
    # An ABSOLUTE path is required. If `find` happens to be a shell function or
    # alias, `command -v` returns the bare name and `ln -s find mask/find` makes a
    # self-referential symlink — the mask then resolves NOTHING, every masked case
    # finds zero repos, and the suite reports the shim broken when it is fine.
    # (Real occurrence: Claude Code's zsh snapshot defines `find` as a function.)
    case "$p" in
        /*) ln -sf "$p" "$mask/$b" ;;
        *)  die "cannot mask PATH: '$b' resolved to '$p', not an absolute path" ;;
    esac
done
# Prove the mask works before trusting a negative result from it.
if PATH="$mask" sh -c 'find / -maxdepth 0 -print >/dev/null 2>&1'; then
    pass "the masked PATH can still run find"
else
    die "the masked PATH cannot run find — masked cases below prove nothing"
fi
if PATH="$mask" command -v timeout >/dev/null 2>&1 \
   || PATH="$mask" command -v gtimeout >/dev/null 2>&1; then
    die "PATH mask leaked a timeout binary — case 2 would not test the shim"
else
    pass "PATH mask hides both timeout and gtimeout"
fi

r2="$tmp/r2"; fixture repo2 "$r2"
before="$(otm "$r2/repo2")"
PATH="$mask" GIT_AUTOFETCH_ROOTS="$r2" sh "$AF" >"$tmp/o2" 2>"$tmp/e2"; rc2=$?
after="$(otm "$r2/repo2")"
eq "$rc2" "0" "exits 0 with no timeout(1) on PATH"
[ "$before" != "$after" ] && [ "$after" != NONE ] \
  && pass "refs actually moved with NO timeout(1) — the macOS regression" \
  || die "refs did not move without timeout(1): $before -> $after (the shim is broken)"
grep -q 'fetch failed/skipped' "$tmp/e2" \
  && die "reported a failure despite a reachable remote" \
  || pass "no spurious 'fetch failed/skipped' without timeout(1)"

# ── Case 3: a total failure must be non-zero ─────────────────────────────────
# The old script exited 0 no matter what, which is exactly why a fleet-wide
# breakage looked like a healthy launchd job for a day.
r3="$tmp/r3"; mkdir -p "$r3/broken"
G init -q -b main "$r3/broken"
G -C "$r3/broken" remote add origin "$tmp/does-not-exist.git"
GIT_AUTOFETCH_ROOTS="$r3" sh "$AF" >"$tmp/o3" 2>"$tmp/e3"; rc3=$?
[ "$rc3" -ne 0 ] \
  && pass "exits non-zero when EVERY fetch fails" \
  || die "exited 0 with every fetch failing — the silent-breakage bug is back"
grep -q 'all 1 fetches failed' "$tmp/e3" \
  && pass "names the all-failed condition on stderr" \
  || die "all-failed message missing from stderr"

# ── Case 4: one bad repo among good ones stays a warning, not an error ────────
r4="$tmp/r4"; fixture repo4 "$r4"
mkdir -p "$r4/broken"; G init -q -b main "$r4/broken"
G -C "$r4/broken" remote add origin "$tmp/nope.git"
before="$(otm "$r4/repo4")"
GIT_AUTOFETCH_ROOTS="$r4" sh "$AF" >"$tmp/o4" 2>"$tmp/e4"; rc4=$?
eq "$rc4" "0" "one unreachable remote among reachable ones exits 0"
[ "$(otm "$r4/repo4")" != "$before" ] \
  && pass "the healthy repo still fetched despite its broken neighbour" \
  || die "a broken repo blocked its neighbour's fetch"
grep -q "fetch failed/skipped: $r4/broken" "$tmp/e4" \
  && pass "still warns about the one broken repo" \
  || die "the broken repo produced no warning"

# ── Case 5: the wall clock actually fires, and the loop continues ─────────────
# The ONE property the shim exists for, and the one no static test can reach.
#
# The hang is injected as a FAKE ssh ON THE MASKED PATH, not via GIT_SSH_COMMAND:
# the script exports its own GIT_SSH_COMMAND unconditionally (it must — BatchMode
# is what stops a fetch blocking forever on an auth prompt), so a value passed in
# here is clobbered before git ever sees it. An earlier draft did exactly that and
# "passed" in 0s while the fetch was in fact failing instantly on a missing ssh —
# a green light for an untested property. Resolving `ssh` from the mask means real
# git, a real ssh:// fetch, and a real hang in the transport.
cat > "$mask/ssh" <<EOF
#!/bin/sh
exec "$(command -v sleep)" 120
EOF
chmod +x "$mask/ssh"

r5="$tmp/r5"; fixture repo5 "$r5"
mkdir -p "$r5/hang"; G init -q -b main "$r5/hang"
G -C "$r5/hang" remote add origin "ssh://nowhere.invalid/x.git"
start=$(date +%s)
PATH="$mask" GIT_AUTOFETCH_ROOTS="$r5" GIT_AUTOFETCH_TIMEOUT=3 \
  sh "$AF" >"$tmp/o5" 2>"$tmp/e5"; rc5=$?
elapsed=$(( $(date +%s) - start ))
# Both bounds matter. The lower one is what distinguishes "the watchdog fired"
# from "the fetch died instantly for an unrelated reason"; the upper one is the
# actual guarantee — a 120s hang bounded to a 3s budget.
[ "$elapsed" -ge 3 ] \
  && pass "the fetch really did hang (${elapsed}s >= the 3s budget)" \
  || die "the fetch did not hang (${elapsed}s) — case 5 is not testing the wall clock"
[ "$elapsed" -lt 60 ] \
  && pass "the hanging fetch was KILLED (${elapsed}s, would have run 120s)" \
  || die "the wall clock did not fire: took ${elapsed}s"
grep -q "fetch failed/skipped: $r5/hang" "$tmp/e5" \
  && pass "the killed fetch is reported as failed" \
  || die "the killed fetch was not reported"
eq "$rc5" "0" "a killed fetch alongside a good one still exits 0"
[ "$(otm "$r5/repo5")" != NONE ] \
  && pass "the loop continued past the killed fetch to the next repo" \
  || die "a killed fetch aborted the loop"
rm -f "$mask/ssh"

# ── Case 6: no roots / no repos must not be a false alarm ─────────────────────
# _total is 0, so the all-failed branch must not fire — otherwise a box with no
# checkouts yet would page on every tick.
GIT_AUTOFETCH_ROOTS="$tmp/empty-root-does-not-exist" sh "$AF" >/dev/null 2>&1
eq "$?" "0" "a root with no repos exits 0, not the all-failed error"

# ── Case 7: the transport-level stall guard is present ───────────────────────
# ConnectTimeout only bounds the handshake. This is the one assertion here that
# is a grep, because the property is "what we hand to ssh" and provoking a real
# post-handshake stall needs a server.
grep -q 'ServerAliveInterval=10 -o ServerAliveCountMax=3' "$AF" \
  && pass "GIT_SSH_COMMAND bounds a post-handshake stall" \
  || die "GIT_SSH_COMMAND lost its ServerAlive* guard"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
