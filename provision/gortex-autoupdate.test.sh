#!/usr/bin/env bash
# Unit tests for provision/gortex-autoupdate.sh against a scratch repo + bare
# "remote" and a stubbed releases API. Nothing here touches the real machines
# checkout, the real remote, or the network.
#
# The property under test is not "does it bump" but "what can it ever commit or
# push". This script runs unattended on the always-on box, with credentials, on
# the branch the whole fleet reprovisions from — so every case asserts on the
# COMMIT CONTENT and the remote tip, not just on exit status.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/gortex-autoupdate.sh"

fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { if [ "$2" = "$3" ]; then pass "$1"; else die "$1: got '$2', want '$3'"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: gortex-autoupdate tests (jq not installed)"
  echo "ALL PASS"; exit 0
fi

PIN_REL="provision/gortex.version"

# setup [pin]: scratch remote + repo with the pin, a stub scripts/update-gortex.sh
# and a stub curl. Echoes the temp root. Every case gets its own.
#
# The stubs are the two seams the real script already has: it delegates the pin
# rewrite to scripts/update-gortex.sh (so the parse rule has one implementation)
# and reads the release over curl. Replacing exactly those two keeps every gate
# under test running its shipped code.
setup() {
  local T pin="${1:-0.61.4}"
  T="$(mktemp -d)"
  git init -q --bare "$T/remote.git"
  mkdir -p "$T/repo/provision" "$T/repo/scripts" "$T/bin" "$T/state" "$T/home"

  cat > "$T/repo/$PIN_REL" <<EOF
# The gortex release this fleet pins to. One bare semver, no \`v\` prefix.
#
# The reader takes the first bare semver on a non-comment line.
$pin
EOF

  # Stub writer: same awk shape as the real scripts/update-gortex.sh, minus the
  # network lookup. STUB_PIN_TO is what it writes.
  cat > "$T/repo/scripts/update-gortex.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
f="$(cd "$(dirname "$0")/.." && pwd)/provision/gortex.version"
awk -v v="${STUB_PIN_TO:-0.63.2}" '
  /^[[:space:]]*#/ { print; next }
  /[0-9]+\.[0-9]+\.[0-9]+/ && !done { print v; done = 1; next }
  { print }
' "$f" > "$f.tmp"
mv "$f.tmp" "$f"
STUB

  git -C "$T/repo" init -q -b main .
  git -C "$T/repo" config user.email t@t
  git -C "$T/repo" config user.name t
  git -C "$T/repo" add -A
  git -C "$T/repo" commit -qm init
  git -C "$T/repo" remote add origin "$T/remote.git"
  git -C "$T/repo" push -q -u origin main
  echo "$T"
}

# stub_release <root> <version> <age-seconds>: the fixture the stubbed curl
# returns. age is how long ago the release was published.
stub_release() {
  local T="$1" ver="$2" age="$3" ts
  ts="$(date -u -d "@$(( $(date -u +%s) - age ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r "$(( $(date -u +%s) - age ))" +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s' '{"tag_name":"v${ver}","published_at":"${ts}"}'
EOF
  chmod +x "$T/bin/curl"
}

# tick <root> [extra-env…]: one pass. Echoes the exit code.
# `env "$@"` and not a bare `"$@"`: bash recognises assignment prefixes at PARSE
# time, so a quoted expansion that merely looks like VAR=val is treated as the
# command name (exit 127), not as an assignment. env re-reads them at runtime.
tick() {
  local T="$1"; shift
  MACHINES_REPO="$T/repo" \
  GORTEX_AUTOUPDATE_STATE_DIR="$T/state" \
  HOME="$T/home" \
  PATH="$T/bin:$PATH" \
  env "$@" bash "$SCRIPT" >"$T/out" 2>"$T/err"
  echo $?
}

pin_of()     { grep -vE '^[[:space:]]*#' "$1/repo/$PIN_REL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }
commits()    { git -C "$1/repo" rev-list --count HEAD; }
remote_tip() { git -C "$1/remote.git" rev-parse main; }
local_tip()  { git -C "$1/repo" rev-parse main; }

# ── Case 1: the happy path ────────────────────────────────────────────────────
T="$(setup 0.61.4)"; stub_release "$T" 0.63.2 604800
rc="$(tick "$T")"
eq "case1 rc" "$rc" "0"
eq "case1 pin bumped" "$(pin_of "$T")" "0.63.2"
eq "case1 one new commit" "$(commits "$T")" "2"
eq "case1 commit touches ONLY the pin" \
   "$(git -C "$T/repo" show --name-only --format= HEAD | grep -v '^$' | tr '\n' ' ')" \
   "$PIN_REL "
eq "case1 pushed" "$(remote_tip "$T")" "$(local_tip "$T")"
# The pin file's header is what documents the parse rule; a bump that ate it
# would leave the next reader guessing.
grep -q 'no `v` prefix' "$T/repo/$PIN_REL" \
  && pass "case1 pin header survives the bump" || die "case1 pin header survives the bump"
rm -rf "$T"

# ── Case 2: MIN_AGE holds a fresh release back ────────────────────────────────
# The point of the gate: a release nobody has shaken out yet must not reach five
# boxes because a timer happened to fire an hour after it was cut.
T="$(setup 0.61.4)"; stub_release "$T" 0.63.2 3600
rc="$(tick "$T")"
eq "case2 rc" "$rc" "0"
eq "case2 pin unchanged" "$(pin_of "$T")" "0.61.4"
eq "case2 no commit" "$(commits "$T")" "1"
grep -q 'MIN_AGE' "$T/err" && pass "case2 says why it held" || die "case2 says why it held"
# Same release, once it has aged past an explicitly lowered gate.
rc="$(tick "$T" GORTEX_AUTOUPDATE_MIN_AGE=60)"
eq "case2 rc after the gate is lowered" "$rc" "0"
eq "case2 bumps once old enough" "$(pin_of "$T")" "0.63.2"
rm -rf "$T"

# ── Case 3: already at the latest release ─────────────────────────────────────
T="$(setup 0.63.2)"; stub_release "$T" 0.63.2 604800
rc="$(tick "$T")"
eq "case3 rc" "$rc" "0"
eq "case3 no commit" "$(commits "$T")" "1"
rm -rf "$T"

# ── Case 4: a hand-edited pin is never overwritten ────────────────────────────
# THE load-bearing gate. scripts/update-gortex.sh REWRITES the pin file, so a
# human mid-bump would otherwise have their edit silently replaced and committed
# under the timer's message.
T="$(setup 0.61.4)"; stub_release "$T" 0.63.2 604800
printf '0.62.0\n' > "$T/repo/$PIN_REL"
rc="$(tick "$T")"
eq "case4 rc" "$rc" "0"
eq "case4 hand edit preserved" "$(pin_of "$T")" "0.62.0"
eq "case4 no commit" "$(commits "$T")" "1"
rm -rf "$T"

# ── Case 5: somebody else's dirty file is never committed ─────────────────────
# `git commit --only <path>` is the guarantee; this is what proves it. A plain
# `commit -a` here would ship an unrelated work-in-progress to the branch every
# box reprovisions from.
T="$(setup 0.61.4)"; stub_release "$T" 0.63.2 604800
printf 'wip\n' > "$T/repo/provision/other.sh"
git -C "$T/repo" add provision/other.sh
git -C "$T/repo" commit -qm "add other"
git -C "$T/repo" push -q origin main
printf 'wip edited\n' > "$T/repo/provision/other.sh"
rc="$(tick "$T")"
eq "case5 rc" "$rc" "0"
eq "case5 pin bumped" "$(pin_of "$T")" "0.63.2"
eq "case5 commit touches ONLY the pin" \
   "$(git -C "$T/repo" show --name-only --format= HEAD | grep -v '^$' | tr '\n' ' ')" \
   "$PIN_REL "
eq "case5 the WIP is still uncommitted" \
   "$(git -C "$T/repo" status --porcelain -- provision/other.sh)" \
   " M provision/other.sh"
rm -rf "$T"

# ── Case 6: not on the publishing branch ──────────────────────────────────────
T="$(setup 0.61.4)"; stub_release "$T" 0.63.2 604800
git -C "$T/repo" checkout -q -b scratch
rc="$(tick "$T")"
eq "case6 rc" "$rc" "0"
eq "case6 no commit" "$(commits "$T")" "1"
eq "case6 pin unchanged" "$(pin_of "$T")" "0.61.4"
rm -rf "$T"

# ── Case 7: behind the remote ─────────────────────────────────────────────────
# fleet-selfpull owns the ff-pull (and fires the converge that applies it).
# Bumping from behind would commit on a stale base and diverge the publisher.
T="$(setup 0.61.4)"; stub_release "$T" 0.63.2 604800
git clone -q "$T/remote.git" "$T/other"
git -C "$T/other" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "upstream moved"
git -C "$T/other" push -q origin main
rc="$(tick "$T")"
eq "case7 rc" "$rc" "0"
eq "case7 no commit" "$(commits "$T")" "1"
eq "case7 pin unchanged" "$(pin_of "$T")" "0.61.4"
rm -rf "$T"

# ── Case 8: unpushed local work is never pushed ───────────────────────────────
T="$(setup 0.61.4)"; stub_release "$T" 0.63.2 604800
before="$(remote_tip "$T")"
printf 'secret wip\n' > "$T/repo/provision/wip.sh"
git -C "$T/repo" add provision/wip.sh
git -C "$T/repo" commit -qm "local only"
rc="$(tick "$T")"
eq "case8 rc" "$rc" "0"
eq "case8 no bump on top of unpushed work" "$(pin_of "$T")" "0.61.4"
eq "case8 remote untouched" "$(remote_tip "$T")" "$before"
rm -rf "$T"

# ── Case 9: a stranded bump is pushed, not duplicated ─────────────────────────
# The retry path. pushurl (not url) is broken, so the fetch that classifies the
# state still works while the push fails — exactly the offline-tick shape.
T="$(setup 0.61.4)"; stub_release "$T" 0.63.2 604800
git -C "$T/repo" config remote.origin.pushurl "$T/nonexistent.git"
rc="$(tick "$T")"
eq "case9 rc after a failed push" "$rc" "0"
eq "case9 bump is committed locally" "$(pin_of "$T")" "0.63.2"
eq "case9 commits" "$(commits "$T")" "2"
[ "$(remote_tip "$T")" != "$(local_tip "$T")" ] \
  && pass "case9 remote is behind after the failed push" \
  || die "case9 remote is behind after the failed push"
git -C "$T/repo" config --unset remote.origin.pushurl
rc="$(tick "$T")"
eq "case9 rc on the retry" "$rc" "0"
eq "case9 retry pushed" "$(remote_tip "$T")" "$(local_tip "$T")"
eq "case9 retry added no second bump" "$(commits "$T")" "2"
rm -rf "$T"

# ── Case 10: a merge in progress is a hard stop ────────────────────────────────
# Non-zero ON PURPOSE: unlike every skip above, this one needs a human, and the
# timer going red is the only way anyone finds out.
T="$(setup 0.61.4)"; stub_release "$T" 0.63.2 604800
: > "$T/repo/.git/MERGE_HEAD"
rc="$(tick "$T")"
[ "$rc" -ne 0 ] && pass "case10 rc is non-zero" || die "case10 rc is non-zero (got $rc)"
eq "case10 no commit" "$(commits "$T")" "1"
eq "case10 pin unchanged" "$(pin_of "$T")" "0.61.4"
rm -rf "$T"

# ── Case 11: a linked worktree never publishes ────────────────────────────────
# It shares the object store, so a bump committed there lands on a branch nobody
# pushes — the bump would look done and reach no box.
T="$(setup 0.61.4)"; stub_release "$T" 0.63.2 604800
git -C "$T/repo" worktree add -q -b wt "$T/wt" >/dev/null 2>&1
mkdir -p "$T/wt/scripts"
rc="$(MACHINES_REPO="$T/wt" GORTEX_AUTOUPDATE_STATE_DIR="$T/state" HOME="$T/home" \
      PATH="$T/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1; echo $?)"
eq "case11 rc" "$rc" "0"
eq "case11 no commit in the linked worktree" "$(git -C "$T/wt" rev-list --count HEAD)" "1"
rm -rf "$T"

# ── Case 12: no releases API reachable ────────────────────────────────────────
T="$(setup 0.61.4)"
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "$T/bin/curl"
rc="$(tick "$T")"
eq "case12 rc" "$rc" "0"
eq "case12 no commit" "$(commits "$T")" "1"
rm -rf "$T"

# ── Case 13: the library sources inert ────────────────────────────────────────
out="$(GORTEX_AUTOUPDATE_LIB_ONLY=1 bash -c 'source "$1"; declare -F ga_tick >/dev/null && echo LOADED' _ "$SCRIPT" 2>&1)"
eq "case13 LIB_ONLY sources without a tick" "$out" "LOADED"

# ── Case 14: the script installs nothing ──────────────────────────────────────
# The publisher/installer split is the safety argument for auto-updating at all
# (tier_gortex installs the pin, on every box, from a reviewable commit). A
# future edit that reached for the tarball here would quietly rebuild the drift
# the pin exists to prevent.
# COMMENTS STRIPPED, deliberately — the same trap tiers.test.sh names for
# tier_rapl_read: the script's header EXPLAINS that it never installs a binary
# and never runs `gortex upgrade`, so a whole-file grep is satisfied by the
# prose and passes no matter what the code does. Assert against the executable
# lines alone.
code="$(grep -vE '^[[:space:]]*#' "$SCRIPT")"
printf '%s\n' "$code" | grep -q 'releases/download' \
  && die "case14 script downloads no release asset" \
  || pass "case14 script downloads no release asset"
printf '%s\n' "$code" | grep -q 'local/bin' \
  && die "case14 script writes nothing to ~/.local/bin" \
  || pass "case14 script writes nothing to ~/.local/bin"
printf '%s\n' "$code" | grep -qE 'gortex (upgrade|install|init)' \
  && die "case14 script runs no gortex subcommand" \
  || pass "case14 script runs no gortex subcommand"

# ── Case 15: the pin-only check holds AT the push, not seconds earlier ─────────
# ga_sync_state classifies the checkout BEFORE the commit, so its verdict is
# stale by the time the push runs. Case 8 proves the tick declines to publish
# somebody's unpushed work; this proves the push itself declines too, which is
# what makes the property hold against a commit landing in between.
T="$(setup 0.61.4)"
git -C "$T/repo" fetch -q origin main
printf 'wip\n' > "$T/repo/provision/other.sh"
git -C "$T/repo" add provision/other.sh
git -C "$T/repo" commit -qm "not a pin bump"
before="$(remote_tip "$T")"
out="$(MACHINES_REPO="$T/repo" GORTEX_AUTOUPDATE_LIB_ONLY=1 \
       bash -c 'source "$1"; ga_push' _ "$SCRIPT" 2>&1)"
eq "case15 remote untouched" "$(remote_tip "$T")" "$before"
printf '%s\n' "$out" | grep -q 'refusing to push' \
  && pass "case15 the push itself refuses a non-pin diff" \
  || die "case15 the push itself refuses a non-pin diff"
rm -rf "$T"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
