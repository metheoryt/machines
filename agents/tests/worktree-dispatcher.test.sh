#!/usr/bin/env bash
# Behavioral tests for agents/worktree-setup.sh and worktree-teardown.sh.
# Uses a fake `gortex` on PATH and real tmp git repos + linked worktrees.
#
# The fake serves `repos --json` from a mutable path-list file and rewrites that
# file on track/untrack, mirroring the real binary. That faithfulness is the point:
# the previous harness injected a $GORTEX_CONFIG at every call site, so the scripts'
# own default config path — wrong for two months, pointing at a file that does not
# exist, which made every coverage guard fail closed and no worktree was ever
# tracked — was never once exercised. The scripts now ask the daemon and read no
# config file at all; the "reads no config file" case below keeps it that way.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"        # agents/
setup="$repo/worktree-setup.sh"
teardown="$repo/worktree-teardown.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# --- Fake gortex.
#   * records every call in $GORTEX_CALLS
#   * `daemon status` exits $FAKE_GORTEX_DAEMON_UP (0/1)
#   * `repos` exits 1 with no output when $FAKE_GORTEX_REPOS_FAIL is set (an older
#     gortex with no `repos --json`)
#   * `repos --json` renders $FAKE_GORTEX_REPOS (newline-separated paths) as the
#     real pretty-printed JSON, backslashes escaped the way encoding/json does
#   * `track` / `untrack` MUTATE $FAKE_GORTEX_REPOS, like the real config rewrite
#   * `untrack` also appends to $FAKE_GORTEX_UNTRACK_LOG when set (ordering probe)
mk_fakebin() {
  local d; d="$(mktemp -d)"
  cat > "$d/gortex" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GORTEX_CALLS"
store="${FAKE_GORTEX_REPOS:-/dev/null}"
case "$1" in
  daemon)
    [ "$2" = "status" ] && exit "${FAKE_GORTEX_DAEMON_UP:-0}"
    ;;
  repos)
    # Older gortex has no `repos` subcommand / no --json: non-zero, no output.
    [ -n "${FAKE_GORTEX_REPOS_FAIL:-}" ] && exit 1
    printf '[\n'
    n=0
    while IFS= read -r p || [ -n "$p" ]; do
      [ -n "$p" ] || continue
      [ "$n" -eq 0 ] || printf ',\n'
      n=1
      esc=$(printf '%s' "$p" | sed 's/\\/\\\\/g')
      printf '  {\n    "name": "%s",\n    "path": "%s",\n    "indexed": true\n  }' \
        "$(basename "$p")" "$esc"
    done < "$store"
    printf '\n]\n'
    exit 0
    ;;
  track)
    [ -f "$store" ] && printf '%s\n' "$2" >> "$store"
    exit 0
    ;;
  untrack)
    if [ -f "$store" ]; then
      grep -v -x -F -- "$2" "$store" > "$store.tmp"
      mv "$store.tmp" "$store"
    fi
    [ -n "${FAKE_GORTEX_UNTRACK_LOG:-}" ] && echo untrack >> "$FAKE_GORTEX_UNTRACK_LOG"
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$d/gortex"
  printf '%s' "$d"
}

# A path-list store holding the arguments, one per line.
mk_store() { local f; f="$(mktemp)"; printf '%s\n' "$@" > "$f"; printf '%s' "$f"; }

# --- Fixture: a main repo + one linked worktree. Echoes "<main> <wt>".
mk_repo_with_worktree() {
  local base main wt
  # `pwd -P` matters: on macOS mktemp -d hands back /var/folders/... while /var is
  # a symlink to /private/var, and the scripts under test report git's PHYSICAL
  # path. Without this the expectations differ from the logged calls by that prefix
  # alone — which is why these two cases passed on Linux and failed on macOS.
  base="$(cd "$(mktemp -d)" && pwd -P)"
  main="$base/main"
  git init -q "$main"
  ( cd "$main" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
  wt="$base/wt-feature"
  ( cd "$main" && git worktree add -q "$wt" -b feature >/dev/null 2>&1 )
  printf '%s %s' "$main" "$wt"
}

# ============ SETUP ============

# Case 1: daemon up + main covered + worktree new -> tracks worktree, prefix qualified
# with the main checkout's basename (bare basename would collide across repos).
fb="$(mk_fakebin)"; read -r main wt <<<"$(mk_repo_with_worktree)"
store="$(mk_store "$main")"
calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup tracks a new worktree when main is covered" \
  'grep -q "track '"$wt"' --as-worktree" "$calls"'
check "setup qualifies --name with the main checkout basename" \
  'grep -q -- "--name main-wt-feature" "$calls"'

# Case 2: daemon down -> no track call.
store="$(mk_store "$main")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=1 bash "$setup" >/dev/null 2>&1 )
check "setup does not track when daemon is down" '! grep -q "^track " "$calls"'

# Case 3: main NOT covered -> no track call.
store2="$(mk_store /some/other/repo)"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store2" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup skips track when main is not covered" '! grep -q "^track " "$calls"'

# Case 4: worktree already tracked -> no duplicate track.
store3="$(mk_store "$main" "$wt")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store3" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup skips track when worktree already listed" '! grep -q "^track " "$calls"'

# Case 5: main checkout (not a linked worktree) -> takes main-checkout branch (distinctive log).
store="$(mk_store "$main")"; err="$(mktemp)"
( cd "$main" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" 2>"$err" >/dev/null )
check "setup takes the main-checkout branch in the main checkout" 'grep -q "main checkout" "$err"'

# Case 6: repo-local setup script runs; first candidate wins.
touched="$(mktemp)"; rm -f "$touched"
mkdir -p "$wt/.orca" "$wt/docker"
printf '#!/usr/bin/env bash\necho orca > "%s"\n' "$touched" > "$wt/.orca/worktree-setup.sh"
printf '#!/usr/bin/env bash\necho docker > "%s"\n' "$touched" > "$wt/docker/worktree-setup.sh"
chmod +x "$wt/.orca/worktree-setup.sh" "$wt/docker/worktree-setup.sh"
store="$(mk_store "$main")"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup runs first repo-local candidate (.orca over docker)" '[ "$(cat "$touched")" = "orca" ]'
rm -rf "$wt/.orca" "$wt/docker"

# Case 6b: coverage comes from the daemon, not a config file. Two halves:
# the script must ASK (`repos --json` in the call log) and must not read a config
# file to decide (no GORTEX_CONFIG / config.yaml default anywhere in either script).
store="$(mk_store "$main")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup asks the daemon for tracked repos" 'grep -q "^repos --json$" "$calls"'
check "neither script depends on a config-file path" \
  '! grep -qE "GORTEX_CONFIG|config\.yaml\"" "$setup" "$teardown"'

# Case 6c: regression — a FAILED `repos` query must not read as an empty repo list.
# `gortex repos --json | sed` reports sed's exit status, so an older gortex without
# the subcommand would come back empty, look "not covered", and silently skip
# tracking: the same fail-closed as the config-path bug, keyed on binary version
# instead. Both scripts must say so in their own words.
store="$(mk_store "$main")"; calls="$(mktemp)"; err="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$calls" \
  FAKE_GORTEX_REPOS_FAIL=1 FAKE_GORTEX_DAEMON_UP=0 bash "$setup" 2>"$err" >/dev/null )
check "setup distinguishes a failed repos query from 'not covered'" \
  'grep -q "gortex repos unavailable" "$err" && ! grep -q "not covered" "$err" && ! grep -q "^track " "$calls"'
err="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" \
  FAKE_GORTEX_REPOS_FAIL=1 FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" 2>"$err" >/dev/null )
check "teardown skips reconcile when the repos query fails" \
  'grep -q "gortex repos unavailable" "$err"'

# ============ TEARDOWN ============

# Case 7: repo-local teardown runs BEFORE gortex untrack.
fb="$(mk_fakebin)"; read -r main wt <<<"$(mk_repo_with_worktree)"
store="$(mk_store "$main" "$wt")"
order="$(mktemp)"
mkdir -p "$wt/docker"
printf '#!/usr/bin/env bash\necho local >> "%s"\n' "$order" > "$wt/docker/worktree-teardown.sh"
chmod +x "$wt/docker/worktree-teardown.sh"
calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$calls" \
  FAKE_GORTEX_UNTRACK_LOG="$order" FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" >/dev/null 2>&1 )
check "teardown untracks this worktree" 'grep -q "untrack '"$wt"'" "$calls"'
check "teardown runs local script before untrack" '[ "$(head -1 "$order")" = "local" ] && grep -q untrack "$order"'

# Case 8: reconcile prunes a missing path, keeps a live one.
missing="/no/such/dir/should/exist/$$"
store4="$(mk_store "$main" "$missing")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store4" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" >/dev/null 2>&1 )
check "reconcile untracks the missing path" 'grep -q "untrack '"$missing"'" "$calls"'
check "reconcile keeps the live main path" '! grep -q "untrack '"$main"'\$" "$calls"'

# Case 9: daemon down -> no untrack, no reconcile.
store4="$(mk_store "$main" "$missing")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store4" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=1 bash "$teardown" >/dev/null 2>&1 )
check "teardown does no gortex work when daemon down" '! grep -q "^untrack " "$calls"'

# Case 10: not inside a work tree -> both exit 0.
empty="$(mktemp -d)"
( cd "$empty" && PATH="$fb:$PATH" bash "$setup" >/dev/null 2>&1 ); check "setup exits 0 outside a work tree" '[ "$?" -eq 0 ]'
( cd "$empty" && PATH="$fb:$PATH" bash "$teardown" >/dev/null 2>&1 ); check "teardown exits 0 outside a work tree" '[ "$?" -eq 0 ]'

# Case 11: regression — untrack rewrites the very list reconcile is walking, so the
# sweep must run off a snapshot. Iterating the live source (an open fd on the config,
# as the old code did) drops every entry after the first prune. Two missing paths:
# both must go.
gone1="/no/such/dir/a/$$"; gone2="/no/such/dir/b/$$"
store5="$(mk_store "$main" "$gone1" "$gone2")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store5" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" >/dev/null 2>&1 )
check "reconcile prunes every missing path while untrack rewrites the list" \
  'grep -q "untrack '"$gone1"'" "$calls" && grep -q "untrack '"$gone2"'" "$calls"'

# Case 11b: a native-Windows path arrives JSON-escaped (C:\\Users\\...). The parser
# must unescape it to the forward-slash form Git Bash's `cd` accepts before deciding
# it is gone from disk.
winpath='C:\Users\methe\gone'
store6="$(mk_store "$main" "$winpath")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store6" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" >/dev/null 2>&1 )
check "reconcile unescapes a JSON-escaped Windows path" \
  'grep -qF "untrack C:/Users/methe/gone" "$calls"'

# Case 12: generic config linking — a .env in main is symlinked into a fresh worktree.
fb="$(mk_fakebin)"; read -r main wt <<<"$(mk_repo_with_worktree)"
store="$(mk_store "$main")"
printf 'SECRET=1\n' > "$main/.env"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup symlinks .env from main into the worktree" '[ -L "$wt/.env" ] && [ "$(cat "$wt/.env")" = "SECRET=1" ]'

# Case 13: nested-path config is linked with its parent dir created.
mkdir -p "$main/.claude"; printf '{"x":1}\n' > "$main/.claude/settings.local.json"
store="$(mk_store "$main")"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup symlinks nested .claude/settings.local.json" '[ -L "$wt/.claude/settings.local.json" ]'

# Case 14: a pre-existing dest file is NOT clobbered.
read -r main2 wt2 <<<"$(mk_repo_with_worktree)"
store2="$(mk_store "$main2")"
printf 'MAIN=1\n' > "$main2/.env"; printf 'LOCAL=1\n' > "$wt2/.env"
( cd "$wt2" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store2" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup does not clobber an existing dest file" '[ ! -L "$wt2/.env" ] && [ "$(cat "$wt2/.env")" = "LOCAL=1" ]'

# Case 15: idempotent — re-run exits 0 and leaves the link intact.
store="$(mk_store "$main")"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 ); rc=$?
check "setup re-run is idempotent (exit 0, link intact)" '[ "'$rc'" -eq 0 ] && [ -L "$wt/.env" ]'

# Case 16: link step is skipped in the main checkout (.env stays a real file, not a symlink).
read -r main3 wt3 <<<"$(mk_repo_with_worktree)"
store3="$(mk_store "$main3")"
printf 'X=1\n' > "$main3/.env"
( cd "$main3" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store3" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "link step skipped in main checkout (.env not a symlink)" '[ ! -L "$main3/.env" ]'

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
