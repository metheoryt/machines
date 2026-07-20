#!/usr/bin/env bash
# Behavior test for the post-merge hook: it must (1) run _refresh-claude-config
# (NOT exec — the second job must still run) and (2) route a converge FIRE.
# We stub _refresh-claude-config and the fire commands on PATH and assert both
# ran. Forces the linux branch via a fake `uname`.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/post-merge"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Fake repo with a scripts/converge.sh present.
repo="$tmp/machines"; mkdir -p "$repo/scripts" "$repo/agents/git-hooks" "$tmp/bin"
git -C "$repo" init -q; git -C "$repo" checkout -q -b main
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
: > "$repo/x"; git -C "$repo" add .; git -C "$repo" -c commit.gpgsign=false commit -qm c1
# converge.sh writes a marker instead of converging.
cat > "$repo/scripts/converge.sh" <<EOF
#!/usr/bin/env sh
echo fired > "$tmp/converge-ran"
EOF
chmod +x "$repo/scripts/converge.sh"
cp "$HOOK" "$repo/agents/git-hooks/post-merge"
# Stub the shared refresh script the hook calls.
cat > "$repo/agents/git-hooks/_refresh-claude-config" <<EOF
#!/usr/bin/env bash
echo refreshed > "$tmp/refresh-ran"
EOF
chmod +x "$repo/agents/git-hooks/_refresh-claude-config"
# Fake `uname` -> Linux so the WSL/linux branch backgrounds converge.sh.
cat > "$tmp/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF
chmod +x "$tmp/bin/uname"

( cd "$repo" && PATH="$tmp/bin:$PATH" bash agents/git-hooks/post-merge )
sleep 0.5   # detached converge is backgrounded

[ -f "$tmp/refresh-ran" ]  && pass "refresh ran" || die "refresh ran"
[ -f "$tmp/converge-ran" ] && pass "converge fired" || die "converge fired"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
