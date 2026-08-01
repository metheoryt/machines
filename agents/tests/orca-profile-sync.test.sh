#!/usr/bin/env bash
# Behavioral tests for agents/orca-profile-sync.sh.
#
# Unlike bootstrap.test.sh these run for REAL (no DRY_RUN) — against a throwaway
# primary profile (MACHINES_PRIMARY_DIR) and a throwaway accounts root
# (ORCA_CLAUDE_ACCOUNTS_DIR). The live ~/.claude and the real Orca dirs are never
# read or written. Actually executing the sync is the point: the contract is
# about what ends up on disk (symlink vs real file vs untouched), which a
# dry-run cannot show.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"        # agents/
sync="$repo/orca-profile-sync.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# ── A throwaway primary profile, shaped like the real one ───────────────────
primary="$tmp/claude"
mkdir -p "$primary/skills/my-skill" "$primary/agents" "$primary/commands" \
         "$primary/memory/personality"
printf 'AGENT INSTRUCTIONS\n'  > "$primary/CLAUDE.md"
printf 'HOST MEMORY\n'         > "$primary/host-memory.md"
printf 'echo status\n'         > "$primary/statusline-command.sh"
printf 'GLOBAL\n'              > "$primary/memory/global.md"
printf 'TONE\n'                > "$primary/memory/personality/tone.md"
printf 'skill\n'               > "$primary/skills/my-skill/SKILL.md"
printf 'agent\n'               > "$primary/agents/gortex-search.md"
printf 'command\n'             > "$primary/commands/gortex-explore.md"
cat > "$primary/settings.json" <<'EOF'
{
  "model": "opus",
  "statusLine": {"type": "command", "command": "bash \"$HOME/.claude/statusline-command.sh\""},
  "enabledPlugins": {"caveman@caveman": true},
  "permissions": {"allow": ["Bash(git status)"], "defaultMode": "auto"},
  "theme": "auto"
}
EOF

# ── A throwaway Orca account dir, shaped like a fresh Orca login ─────────────
accounts="$tmp/accounts"
acct="$accounts/4e09ba8b-dead-beef/auth"
mkdir -p "$acct/projects" "$acct/sessions"
printf 'acct-uuid\n'           > "$acct/.orca-managed-claude-auth"
printf 'SECRET-TOKEN\n'        > "$acct/.credentials.json"
printf '{"projects":{}}\n'     > "$acct/.claude.json"
printf 'session state\n'       > "$acct/projects/keep.jsonl"
cat > "$acct/settings.json" <<'EOF'
{
  "theme": "auto",
  "tui": "fullscreen",
  "permissions": {"allow": ["Bash(ls:*)"]}
}
EOF

run() { MACHINES_PRIMARY_DIR="$primary" ORCA_CLAUDE_ACCOUNTS_DIR="$accounts" bash "$sync" "$@" 2>&1; }

out="$(run)"
rc=$?

# ── Case 1: content is mirrored, and mirrored as SYMLINKS at the primary ────
check "exits 0 on a clean sync"        '[ "$rc" -eq 0 ]'
check "CLAUDE.md linked at primary"    '[ -L "$acct/CLAUDE.md" ] && [ "$(cat "$acct/CLAUDE.md")" = "AGENT INSTRUCTIONS" ]'
check "host-memory.md linked"          '[ -L "$acct/host-memory.md" ]'
check "statusline linked"              '[ -L "$acct/statusline-command.sh" ]'
check "memory/global.md linked"        '[ -L "$acct/memory/global.md" ] && [ "$(cat "$acct/memory/global.md")" = "GLOBAL" ]'
check "memory/personality linked"      '[ -L "$acct/memory/personality" ] && [ -f "$acct/memory/personality/tone.md" ]'
check "skills entry linked"            '[ -L "$acct/skills/my-skill" ]'
check "agents entry linked"            '[ -L "$acct/agents/gortex-search.md" ]'
check "commands entry linked"          '[ -L "$acct/commands/gortex-explore.md" ]'
# Entry-by-entry, never a whole-dir link — a machine-local addition inside the
# Orca profile has to be able to sit next to the mirrored ones.
check "skills/ itself is a real dir"   '[ -d "$acct/skills" ] && [ ! -L "$acct/skills" ]'
# balance-refresh.py is absent from this fake primary: a missing source must be
# skipped, never left as a dangling link.
check "absent primary file not linked" '[ ! -e "$acct/balance-refresh.py" ] && [ ! -L "$acct/balance-refresh.py" ]'

# ── Case 2: account/session state is never touched ──────────────────────────
check "credentials untouched"          '[ "$(cat "$acct/.credentials.json")" = "SECRET-TOKEN" ] && [ ! -L "$acct/.credentials.json" ]'
check ".claude.json untouched"         '[ ! -L "$acct/.claude.json" ] && grep -q projects "$acct/.claude.json"'
check "projects/ untouched"            '[ ! -L "$acct/projects" ] && [ -f "$acct/projects/keep.jsonl" ]'
check "sessions/ untouched"            '[ -d "$acct/sessions" ] && [ ! -L "$acct/sessions" ]'
check "no plugins/ dir invented"       '[ ! -e "$acct/plugins" ]'

# ── Case 3: settings.json is a merged REAL file, not a link ─────────────────
# A symlink here would push Claude's /config writes and Orca's injected
# agent-hooks block into the primary — and from there into the tracked baseline.
check "settings.json is a real file"   '[ -f "$acct/settings.json" ] && [ ! -L "$acct/settings.json" ]'
check "primary keys propagate"         '[ "$(jq -r .model "$acct/settings.json")" = "opus" ]'
check "primary enabledPlugins arrive"  '[ "$(jq -r ".enabledPlugins[\"caveman@caveman\"]" "$acct/settings.json")" = "true" ]'
check "target-only keys survive"       '[ "$(jq -r .tui "$acct/settings.json")" = "fullscreen" ]'
check "permissions.allow is a union"   '[ "$(jq -r "[.permissions.allow[]]|sort|join(\",\")" "$acct/settings.json")" = "Bash(git status),Bash(ls:*)" ]'
check "pre-sync snapshot kept"         'grep -q fullscreen "$acct/.settings.json.pre-orca-sync"'

# ── Case 4: idempotent — a second run relinks nothing and rewrites nothing ──
# Portable snapshot (no GNU find -printf, which would silently return empty on
# macOS and make this assertion pass vacuously): the path set, every symlink's
# target, and the settings.json bytes.
snapshot() {
  ( cd "$1" && find . | sort
    cd "$1" && find . -type l | sort | while IFS= read -r l; do
      printf '%s -> %s\n' "$l" "$(readlink "$l")"
    done
    cat "$1/settings.json" )
}
before="$(snapshot "$acct")"
out2="$(run)"
after="$(snapshot "$acct")"
check "second run is a no-op on disk"  '[ "$before" = "$after" ]'
check "second run reports in-sync settings" 'printf "%s" "$out2" | grep -q "settings.json already in sync"'
check "second run reports linked=0"    'printf "%s" "$out2" | grep -qE "Done\. profiles=1  linked=0"'

# ── Case 5: pruning — a link whose primary source is gone is dropped; a
# machine-local real file in the same dir is not.
printf 'local only\n' > "$acct/skills/local-skill.md"
rm -rf "$primary/skills/my-skill"
out3="$(run)"
check "dangling mirror link pruned"    '[ ! -L "$acct/skills/my-skill" ] && [ ! -e "$acct/skills/my-skill" ]'
check "machine-local file kept"        '[ -f "$acct/skills/local-skill.md" ] && [ ! -L "$acct/skills/local-skill.md" ]'

# ── Case 5b: a real file AT a mirrored path is never clobbered. This is the
# gortex case: commands/, agents/ and the gortex-* skills are regenerated per
# profile, and the Orca profile's copy is routinely NEWER than the primary's.
# Replace the mirror link the way a generator does — unlink, then write. A bare
# `>` redirect would write THROUGH the symlink into the primary instead.
rm -f "$acct/commands/gortex-explore.md"
printf 'NEWER GENERATED\n' > "$acct/commands/gortex-explore.md"
printf 'PROFILE-OWNED\n'   > "$acct/CLAUDE.md.tmp" && mv "$acct/CLAUDE.md.tmp" "$acct/CLAUDE.md"
out3b="$(run)"
check "real file at a mirrored dir path kept" \
  '[ ! -L "$acct/commands/gortex-explore.md" ] && [ "$(cat "$acct/commands/gortex-explore.md")" = "NEWER GENERATED" ]'
check "real file at a mirrored whole-file path kept" \
  '[ ! -L "$acct/CLAUDE.md" ] && [ "$(cat "$acct/CLAUDE.md")" = "PROFILE-OWNED" ]'
check "keeping is reported, not silent" 'printf "%s" "$out3b" | grep -q "kept (machine-local, not overwritten)"'
check "nothing was backed up to make room" '[ ! -d "$acct/.bootstrap-bak" ]'
# Restore the mirrored state for the cases below.
rm -f "$acct/commands/gortex-explore.md" "$acct/CLAUDE.md"
run >/dev/null
# A link pointing somewhere else entirely is none of our business, dangling or not.
ln -s "$tmp/nowhere" "$acct/skills/foreign"
run >/dev/null
check "foreign dangling link kept"     '[ -L "$acct/skills/foreign" ]'
rm -f "$acct/skills/foreign"

# ── Case 6: guards ──────────────────────────────────────────────────────────
plain="$tmp/not-orca"; mkdir -p "$plain"
out4="$(run "$plain")"; rc4=$?
check "refuses a non-Orca dir"         '[ "$rc4" -ne 0 ] && printf "%s" "$out4" | grep -q "not an Orca-managed auth dir"'
check "non-Orca dir left empty"        '[ -z "$(ls -A "$plain")" ]'
out5="$(run --force "$plain")"
check "--force overrides the guard"    '[ -L "$plain/CLAUDE.md" ]'

out6="$(run --force "$primary")"; rc6=$?
check "refuses to sync primary onto itself" \
  '[ "$rc6" -ne 0 ] && printf "%s" "$out6" | grep -q "onto itself"'

missing="$tmp/nope"
out7="$(run --force "$missing")"; rc7=$?
check "refuses a missing dir"          '[ "$rc7" -ne 0 ] && printf "%s" "$out7" | grep -q "not a directory"'

# ── Case 7: discovery + dry run ─────────────────────────────────────────────
acct2="$accounts/11111111-2222-3333/auth"
mkdir -p "$acct2"; printf 'acct2\n' > "$acct2/.orca-managed-claude-auth"
out8="$(run --dry-run)"
check "dry run finds both accounts"    'printf "%s" "$out8" | grep -q "(dry-run) profiles=2"'
check "dry run writes nothing"         '[ -z "$(ls -A "$acct2")" ] || [ "$(ls -A "$acct2")" = ".orca-managed-claude-auth" ]'
out9="$(run)"
check "discovery syncs the new account" '[ -L "$acct2/CLAUDE.md" ]'

# ── Case 8: an accounts root with no accounts is a clean no-op ──────────────
empty="$tmp/empty-accounts"; mkdir -p "$empty"
out10="$(MACHINES_PRIMARY_DIR="$primary" ORCA_CLAUDE_ACCOUNTS_DIR="$empty" bash "$sync" 2>&1)"; rc10=$?
check "no accounts → exit 0, no error" '[ "$rc10" -eq 0 ] && printf "%s" "$out10" | grep -q "nothing to sync"'

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME TESTS FAILED"; fi
exit "$fail"
