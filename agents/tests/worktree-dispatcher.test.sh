#!/usr/bin/env bash
# Behavioral tests for agents/worktree-setup.sh and worktree-teardown.sh.
# Uses a fake `gortex` on PATH (records calls, daemon-status exit toggled by env),
# a tmp GORTEX_CONFIG, and real tmp git repos + linked worktrees.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"        # agents/
setup="$repo/worktree-setup.sh"
teardown="$repo/worktree-teardown.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# --- Fake gortex: logs every call; `daemon status` exit = $FAKE_GORTEX_DAEMON_UP (0/1).
mk_fakebin() {
  local d; d="$(mktemp -d)"
  cat > "$d/gortex" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GORTEX_CALLS"
if [ "$1" = "daemon" ] && [ "$2" = "status" ]; then
  exit "${FAKE_GORTEX_DAEMON_UP:-0}"
fi
exit 0
EOF
  chmod +x "$d/gortex"
  printf '%s' "$d"
}

# --- Fixture: a main repo + one linked worktree. Echoes "<main> <wt>".
mk_repo_with_worktree() {
  local base main wt
  base="$(mktemp -d)"
  main="$base/main"
  git init -q "$main"
  ( cd "$main" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
  wt="$base/wt-feature"
  ( cd "$main" && git worktree add -q "$wt" -b feature >/dev/null 2>&1 )
  printf '%s %s' "$main" "$wt"
}

# ============ SETUP ============

# Case 1: daemon up + main covered + worktree new -> tracks worktree.
fb="$(mk_fakebin)"; read -r main wt <<<"$(mk_repo_with_worktree)"
cfg="$(mktemp)"; printf 'repos:\n    - path: %s\n' "$main" > "$cfg"
calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup tracks a new worktree when main is covered" \
  'grep -q "track '"$wt"' --as-worktree" "$calls"'

# Case 2: daemon down -> no track call.
calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=1 bash "$setup" >/dev/null 2>&1 )
check "setup does not track when daemon is down" '! grep -q "^track " "$calls"'

# Case 3: main NOT covered -> no track call.
cfg2="$(mktemp)"; printf 'repos:\n    - path: /some/other/repo\n' > "$cfg2"
calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg2" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup skips track when main is not covered" '! grep -q "^track " "$calls"'

# Case 4: worktree already tracked -> no duplicate track.
cfg3="$(mktemp)"; printf 'repos:\n    - path: %s\n    - path: %s\n' "$main" "$wt" > "$cfg3"
calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg3" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup skips track when worktree already listed" '! grep -q "^track " "$calls"'

# Case 5: main checkout (not a linked worktree) -> takes main-checkout branch (distinctive log).
err="$(mktemp)"
( cd "$main" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" 2>"$err" >/dev/null )
check "setup takes the main-checkout branch in the main checkout" 'grep -q "main checkout" "$err"'

# Case 6: repo-local setup script runs; first candidate wins.
touched="$(mktemp)"; rm -f "$touched"
mkdir -p "$wt/.orca" "$wt/docker"
printf '#!/usr/bin/env bash\necho orca > "%s"\n' "$touched" > "$wt/.orca/worktree-setup.sh"
printf '#!/usr/bin/env bash\necho docker > "%s"\n' "$touched" > "$wt/docker/worktree-setup.sh"
chmod +x "$wt/.orca/worktree-setup.sh" "$wt/docker/worktree-setup.sh"
( cd "$wt" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup runs first repo-local candidate (.orca over docker)" '[ "$(cat "$touched")" = "orca" ]'
rm -rf "$wt/.orca" "$wt/docker"

# ============ TEARDOWN ============

# Case 7: repo-local teardown runs BEFORE gortex untrack.
fb="$(mk_fakebin)"; read -r main wt <<<"$(mk_repo_with_worktree)"
cfg="$(mktemp)"; printf 'repos:\n    - path: %s\n    - path: %s\n' "$main" "$wt" > "$cfg"
order="$(mktemp)"
mkdir -p "$wt/docker"
printf '#!/usr/bin/env bash\necho local >> "%s"\n' "$order" > "$wt/docker/worktree-teardown.sh"
chmod +x "$wt/docker/worktree-teardown.sh"
# Wrap fake gortex to also append to the order file on untrack.
cat > "$fb/gortex" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "\$GORTEX_CALLS"
[ "\$1" = "untrack" ] && echo untrack >> "$order"
if [ "\$1" = "daemon" ] && [ "\$2" = "status" ]; then exit "\${FAKE_GORTEX_DAEMON_UP:-0}"; fi
exit 0
EOF
chmod +x "$fb/gortex"
calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" >/dev/null 2>&1 )
check "teardown untracks this worktree" 'grep -q "untrack '"$wt"'" "$calls"'
check "teardown runs local script before untrack" '[ "$(head -1 "$order")" = "local" ] && grep -q untrack "$order"'

# Case 8: reconcile prunes a missing path, keeps a live one.
missing="/no/such/dir/should/exist/$$"
cfg4="$(mktemp)"; printf 'repos:\n    - path: %s\n    - path: %s\n' "$main" "$missing" > "$cfg4"
calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg4" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" >/dev/null 2>&1 )
check "reconcile untracks the missing path" 'grep -q "untrack '"$missing"'" "$calls"'
check "reconcile keeps the live main path" '! grep -q "untrack '"$main"'\$" "$calls"'

# Case 9: daemon down -> no untrack, no reconcile.
calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg4" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=1 bash "$teardown" >/dev/null 2>&1 )
check "teardown does no gortex work when daemon down" '! grep -q "^untrack " "$calls"'

# Case 10: not inside a work tree -> both exit 0.
empty="$(mktemp -d)"
( cd "$empty" && PATH="$fb:$PATH" bash "$setup" >/dev/null 2>&1 ); check "setup exits 0 outside a work tree" '[ "$?" -eq 0 ]'
( cd "$empty" && PATH="$fb:$PATH" bash "$teardown" >/dev/null 2>&1 ); check "teardown exits 0 outside a work tree" '[ "$?" -eq 0 ]'

# Case 11: regression — last config line has no trailing newline; reconcile still
# untracks the final (missing) path (config-parsing loop must read it via
# `|| [ -n "$line" ]` after the read loop hits EOF without a final \n).
missing2="/no/such/dir/should/exist/nl/$$"
cfg5="$(mktemp)"; printf 'repos:\n    - path: %s\n    - path: %s' "$main" "$missing2" > "$cfg5"
calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg5" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" >/dev/null 2>&1 )
check "reconcile untracks the missing path when config has no trailing newline" \
  'grep -q "untrack '"$missing2"'" "$calls"'

# Case 12: generic config linking — a .env in main is symlinked into a fresh worktree.
fb="$(mk_fakebin)"; read -r main wt <<<"$(mk_repo_with_worktree)"
cfg="$(mktemp)"; printf 'repos:\n    - path: %s\n' "$main" > "$cfg"
printf 'SECRET=1\n' > "$main/.env"
( cd "$wt" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup symlinks .env from main into the worktree" '[ -L "$wt/.env" ] && [ "$(cat "$wt/.env")" = "SECRET=1" ]'

# Case 13: nested-path config is linked with its parent dir created.
printf '{"x":1}\n' > "$main/.claude/settings.local.json" 2>/dev/null || { mkdir -p "$main/.claude"; printf '{"x":1}\n' > "$main/.claude/settings.local.json"; }
( cd "$wt" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup symlinks nested .claude/settings.local.json" '[ -L "$wt/.claude/settings.local.json" ]'

# Case 14: a pre-existing dest file is NOT clobbered.
read -r main2 wt2 <<<"$(mk_repo_with_worktree)"
cfg2="$(mktemp)"; printf 'repos:\n    - path: %s\n' "$main2" > "$cfg2"
printf 'MAIN=1\n' > "$main2/.env"; printf 'LOCAL=1\n' > "$wt2/.env"
( cd "$wt2" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg2" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup does not clobber an existing dest file" '[ ! -L "$wt2/.env" ] && [ "$(cat "$wt2/.env")" = "LOCAL=1" ]'

# Case 15: idempotent — re-run exits 0 and leaves the link intact.
( cd "$wt" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 ); rc=$?
check "setup re-run is idempotent (exit 0, link intact)" '[ "'$rc'" -eq 0 ] && [ -L "$wt/.env" ]'

# Case 16: link step is skipped in the main checkout (.env stays a real file, not a symlink).
read -r main3 wt3 <<<"$(mk_repo_with_worktree)"
cfg3="$(mktemp)"; printf 'repos:\n    - path: %s\n' "$main3" > "$cfg3"
printf 'X=1\n' > "$main3/.env"
( cd "$main3" && PATH="$fb:$PATH" GORTEX_CONFIG="$cfg3" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "link step skipped in main checkout (.env not a symlink)" '[ ! -L "$main3/.env" ]'

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
