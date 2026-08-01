#!/usr/bin/env bash
# Behavioral tests for agents/orca-profile-link.sh (and its handshake with
# orca-profile-sync.sh).
#
# Runs for REAL against synthetic account dirs and a throwaway profiles root
# (ORCA_CLAUDE_ACCOUNTS_DIR / CLAUDE_PROFILES_DIR / MACHINES_PRIMARY_DIR). The
# live Orca dirs and ~/.claude are never read or written. Executing for real is
# the point: the contract is about what ends up on disk — a real dir moved, a
# symlink in its place, data still reachable — which a dry run cannot show.
#
# CLAUDE_CONFIG_DIR is scrubbed from every invocation: inside an Orca session it
# points at the live account dir, and refuse_if_live would compare against it.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"        # agents/
lnk="$repo/orca-profile-link.sh"
sync="$repo/orca-profile-sync.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
accounts="$tmp/accounts"
profiles="$tmp/profiles"

# run_link / run_sync: the two scripts, pinned at the throwaway roots.
run_link() { env -u CLAUDE_CONFIG_DIR ORCA_CLAUDE_ACCOUNTS_DIR="$accounts" \
                 CLAUDE_PROFILES_DIR="$profiles" bash "$lnk" "$@" 2>&1; }
run_sync() { env -u CLAUDE_CONFIG_DIR ORCA_CLAUDE_ACCOUNTS_DIR="$accounts" \
                 CLAUDE_PROFILES_DIR="$profiles" MACHINES_PRIMARY_DIR="$primary" \
                 bash "$sync" "$@" 2>&1; }

# mk_account <id>: a fresh Orca account dir, shaped like a real one.
mk_account() {
  local d="$accounts/$1/auth"
  mkdir -p "$d/projects/-home-me-x" "$d/sessions"
  printf '%s\n'   "$1"        > "$d/.orca-managed-claude-auth"
  printf 'TOKEN-%s\n' "$1"    > "$d/.credentials.json"
  printf '{"emailAddress":"me@example.test"}\n' > "$d/oauth-account.json"
  printf '{"projects":{}}\n'  > "$d/.claude.json"
  printf 'TRANSCRIPT-%s\n' "$1" > "$d/projects/-home-me-x/session.jsonl"
  printf '{"theme":"auto"}\n' > "$d/settings.json"
  printf '%s' "$d"
}

# A throwaway primary, for the sync-integration cases at the end.
primary="$tmp/claude"
mkdir -p "$primary/skills/my-skill" "$primary/memory"
printf 'AGENT INSTRUCTIONS\n' > "$primary/CLAUDE.md"
printf 'GLOBAL\n'             > "$primary/memory/global.md"
printf 'skill\n'              > "$primary/skills/my-skill/SKILL.md"
printf '{"model":"opus"}\n'   > "$primary/settings.json"

# ── Case 1: migrate — content moves to $HOME, a symlink takes its place ─────
auth="$(mk_account acct-one)"
out1="$(run_link pure "$auth")"; rc1=$?
check "migrate exits 0"                  '[ "$rc1" -eq 0 ]'
check "account dir is now a symlink"     '[ -L "$auth" ]'
check "it points at the named profile"   '[ "$(readlink "$auth")" = "$profiles/pure" ]'
check "the profile is a real directory"  '[ -d "$profiles/pure" ] && [ ! -L "$profiles/pure" ]'
# The data is the whole point: it must be intact AND reachable both ways.
check "transcripts moved with it"        '[ "$(cat "$profiles/pure/projects/-home-me-x/session.jsonl")" = "TRANSCRIPT-acct-one" ]'
check "credentials readable through the link" '[ "$(cat "$auth/.credentials.json")" = "TOKEN-acct-one" ]'
check "Orca'\''s own marker came along"  '[ -f "$profiles/pure/.orca-managed-claude-auth" ]'
check "nothing left at the old path"     '[ ! -e "$profiles/pure/auth" ]'

# ── Case 2: the pairing marker — what makes --status and --relink possible ──
check "pairing file written"             '[ -f "$profiles/pure/.orca-account" ]'
check "it records the account dir"       'grep -qxF "auth_dir=$auth" "$profiles/pure/.orca-account"'
check "it records the orca profile id"   'grep -qxF "orca_profile_id=acct-one" "$profiles/pure/.orca-account"'

# ── Case 3: idempotent — a second run is a no-op, not a nested move ─────────
out3="$(run_link pure "$auth")"; rc3=$?
check "second migrate exits 0"           '[ "$rc3" -eq 0 ]'
check "second migrate reports already-migrated" 'printf "%s" "$out3" | grep -q "already migrated"'
check "no profile nested inside itself"  '[ ! -e "$profiles/pure/pure" ] && [ ! -e "$profiles/pure/auth" ]'

# ── Case 4: never merge two profiles under one name ─────────────────────────
auth2="$(mk_account acct-two)"
out4="$(run_link pure "$auth2")"; rc4=$?
check "refuses an existing profile name" '[ "$rc4" -ne 0 ] && printf "%s" "$out4" | grep -q "already exists"'
check "the second account is untouched"  '[ -d "$auth2" ] && [ ! -L "$auth2" ]'

# ── Case 5: guards ──────────────────────────────────────────────────────────
plain="$tmp/not-orca"; mkdir -p "$plain"; printf 'x\n' > "$plain/f"
out5="$(run_link other "$plain")"; rc5=$?
check "refuses a non-Orca dir"           '[ "$rc5" -ne 0 ] && printf "%s" "$out5" | grep -q "not an Orca-managed auth dir"'
check "non-Orca dir left in place"       '[ -f "$plain/f" ] && [ ! -L "$plain" ]'
out5b="$(run_link other --force "$plain")"
check "--force overrides the dir check"  '[ -L "$plain" ] && [ "$(cat "$plain/f")" = "x" ]'

out5c="$(run_link 'bad/name' "$auth2")"; rc5c=$?
check "refuses a name with a slash"      '[ "$rc5c" -ne 0 ]'

# The live-session guard: the one genuinely dangerous case.
out5d="$(ORCA_CLAUDE_ACCOUNTS_DIR="$accounts" CLAUDE_PROFILES_DIR="$profiles" \
         CLAUDE_CONFIG_DIR="$auth2" bash "$lnk" two "$auth2" 2>&1)"; rc5d=$?
check "refuses to migrate the running profile" \
  '[ "$rc5d" -ne 0 ] && printf "%s" "$out5d" | grep -q "CLAUDE_CONFIG_DIR IS that profile"'
check "the running profile is untouched"  '[ ! -L "$auth2" ]'
out5e="$(ORCA_CLAUDE_ACCOUNTS_DIR="$accounts" CLAUDE_PROFILES_DIR="$profiles" \
         CLAUDE_CONFIG_DIR="$auth2" bash "$lnk" two --force-live "$auth2" 2>&1)"
check "--force-live overrides it"         '[ -L "$auth2" ]'

# ── Case 6: auto-discovery of the un-migrated account ───────────────────────
auth3="$(mk_account acct-three)"
out6="$(run_link three)"                     # no auth-dir argument
check "discovers the single un-migrated account" '[ -L "$auth3" ] && [ "$(readlink "$auth3")" = "$profiles/three" ]'
auth4="$(mk_account acct-four)"; auth5="$(mk_account acct-five)"
out6b="$(run_link ambiguous)"; rc6b=$?
check "refuses when several are un-migrated" '[ "$rc6b" -ne 0 ] && printf "%s" "$out6b" | grep -q "several un-migrated"'
check "neither ambiguous account was touched" '[ ! -L "$auth4" ] && [ ! -L "$auth5" ]'

# ── Case 7: --status ────────────────────────────────────────────────────────
out7="$(run_link --status)"
check "status shows a linked account"    'printf "%s" "$out7" | grep -q "linked   $auth3"'
check "status shows an un-migrated one"  'printf "%s" "$out7" | grep -q "in place $auth4"'
check "status pairs a profile to its account" 'printf "%s" "$out7" | grep -qE "^  three +serving "'

# ── Case 8: --relink after Orca re-creates the account dir ──────────────────
# The scenario the whole design exists for: re-auth, and a pristine dir appears
# where the link was. Fresh auth state must win; profile content must survive.
rm -f "$auth3"                                     # Orca dropped the link…
mkdir -p "$auth3/projects"                         # …and made a new empty dir
printf 'NEW-TOKEN\n'          > "$auth3/.credentials.json"
printf 'acct-three\n'         > "$auth3/.orca-managed-claude-auth"
printf '{"theme":"dark"}\n'   > "$auth3/settings.json"
printf 'ORCA-NEW\n'           > "$auth3/brand-new-file"
printf '{"marker":"MERGED"}\n' > "$profiles/three/settings.json"   # valid JSON: the sync merges it below
printf 'KEEP\n'               > "$profiles/three/projects/-home-me-x/session.jsonl"

out8="$(run_link --relink)"
check "relink restores the symlink"      '[ -L "$auth3" ] && [ "$(readlink "$auth3")" = "$profiles/three" ]'
check "fresh credentials win"            '[ "$(cat "$profiles/three/.credentials.json")" = "NEW-TOKEN" ]'
check "the profile'\''s settings.json survives" 'grep -q MERGED "$profiles/three/settings.json"'
check "transcripts survive a re-auth"    '[ "$(cat "$profiles/three/projects/-home-me-x/session.jsonl")" = "KEEP" ]'
check "genuinely new files are folded in" '[ "$(cat "$profiles/three/brand-new-file")" = "ORCA-NEW" ]'
check "the re-created dir is gone"       '[ -L "$auth3" ]'

# (b) link simply missing → recreated, no merge needed.
rm -f "$auth3"
out8b="$(run_link --relink)"
check "relink recreates a missing link"  '[ -L "$auth3" ]'
# (c) already healthy → reported, nothing done.
out8c="$(run_link --relink)"
check "relink is a no-op when healthy"   'printf "%s" "$out8c" | grep -q "three: link healthy"'

# ── Case 9: --dry-run writes nothing ────────────────────────────────────────
auth6="$(mk_account acct-six)"
out9="$(run_link six --dry-run "$auth6")"
check "dry run creates no profile"       '[ ! -e "$profiles/six" ]'
check "dry run leaves the account dir"   '[ -d "$auth6" ] && [ ! -L "$auth6" ]'
check "dry run says what it would do"    'printf "%s" "$out9" | grep -q "would: mv"'

# ── Case 10: the sync follows the link and lands in the real profile ────────
out10="$(run_sync "$auth3")"
check "sync mirrors through the link"    '[ -L "$profiles/three/CLAUDE.md" ]'
check "sync resolves to the real path"   '[ "$(readlink "$profiles/three/CLAUDE.md")" = "$primary/CLAUDE.md" ]'
check "sync names the link it followed"  'printf "%s" "$out10" | grep -q "(via $auth3)"'
# Backups and the settings stamp must land in $HOME, not inside Orca's tree.
check "settings snapshot written at the real path" '[ -f "$profiles/three/.settings.json.pre-orca-sync" ]'
check "the merge kept the profile'\''s own key"  'grep -q MERGED "$profiles/three/settings.json"'
check "…and took the primary'\''s"               '[ "$(jq -r .model "$profiles/three/settings.json")" = "opus" ]'
check "nothing written inside the account dir itself" \
  '[ "$(readlink "$auth3")" = "$profiles/three" ]'

# ── Case 11: a DETACHED profile is still populated ──────────────────────────
# Its account dir is gone; the profile stands on its own and discovery finds it
# by the pairing marker. This is the payoff of moving the profile into $HOME.
rm -f "$auth3"
rm -f "$profiles/three/CLAUDE.md"
out11="$(run_sync)"
check "sync discovers a detached profile" '[ -L "$profiles/three/CLAUDE.md" ]'
check "…and reports no failure"           'printf "%s" "$out11" | grep -q "failed=0"'
# Restore the link so the dedup case below is meaningful.
run_link --relink >/dev/null
out11b="$(run_sync)"
check "a healthy link is not synced twice" \
  '[ "$(printf "%s" "$out11b" | grep -c "^Profile $profiles/three$")" = 1 ]'

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME TESTS FAILED"; fi
exit "$fail"
