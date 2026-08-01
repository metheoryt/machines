#!/usr/bin/env bash
# Behavioral tests for agents/orca-profile-harvest.sh.
#
# Real runs against synthetic account dirs and a throwaway profiles root. The
# live Orca dirs are never read or written. Running for real is the point: the
# contract is about what lands on disk — symlinks still symlinks, excluded trees
# absent, a deleted source file still present in the copy.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"        # agents/
h="$repo/orca-profile-harvest.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

command -v rsync >/dev/null 2>&1 || { echo "SKIP (rsync absent)"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
accounts="$tmp/accounts"
profiles="$tmp/profiles"
run() { env -u CLAUDE_CONFIG_DIR ORCA_CLAUDE_ACCOUNTS_DIR="$accounts" \
            CLAUDE_PROFILES_DIR="$profiles" bash "$h" "$@" 2>&1; }

# A curated-source dir the account's symlinks point into, mirroring how the live
# profile carries links to ~/.claude.
curated="$tmp/claude"
mkdir -p "$curated"
printf 'AGENT INSTRUCTIONS\n' > "$curated/CLAUDE.md"

# mk_account <id> <org> [uuid]: an account dir shaped like a real one — real
# state, symlinked curated set, and the regenerable trees that must NOT be
# copied. The uuid defaults to one derived from the id; pass it explicitly to
# model a re-login, where Orca mints a new dir id for the SAME account.
#
# The counter pads each account's token to a DIFFERENT length. rsync's quick
# check is size+mtime, so two fixtures written in the same second at the same
# size look identical to it and are skipped — an artifact of generating them
# milliseconds apart, not something real transcripts do (they differ in size, and
# a modified source always gets a newer mtime than the copy).
#
# It is file-backed, not a shell variable: mk_account is called as $(mk_account …),
# so any increment happens in the command-substitution subshell and is lost.
mk_account() {
  local n d uuid="${3:-uuid-$1}"
  n=$(( $(cat "$tmp/.acct_n" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$n" > "$tmp/.acct_n"
  d="$accounts/$1/auth"
  mkdir -p "$d/projects/-home-me-x" "$d/sessions" "$d/plugins/marketplaces/big" \
           "$d/cache" "$d/file-history/x" "$d/shell-snapshots" "$d/session-env"
  printf '%s\n' "$1"            > "$d/.orca-managed-claude-auth"
  printf 'TOKEN-%s%s\n' "$1" "$(printf "%${n}s" '' | tr ' ' 'x')" > "$d/.credentials.json"
  printf '{"organizationName":"%s","emailAddress":"me@example.test","accountUuid":"%s"}\n' \
         "$2" "$uuid" > "$d/oauth-account.json"
  printf 'TRANSCRIPT-%s\n' "$1" > "$d/projects/-home-me-x/session.jsonl"
  printf 'HISTORY\n'            > "$d/history.jsonl"
  printf '{"theme":"auto"}\n'   > "$d/settings.json"
  printf 'BIGPLUGIN\n'          > "$d/plugins/marketplaces/big/blob"
  printf 'CACHE\n'              > "$d/cache/c"
  printf 'FH\n'                 > "$d/file-history/x/v1"
  printf 'SNAP\n'               > "$d/shell-snapshots/s"
  ln -sfn "$curated/CLAUDE.md"    "$d/CLAUDE.md"
  printf '%s' "$d"
}

# ── Case 1: the copy is complete, and it is a usable profile ────────────────
auth="$(mk_account acct-one Pure)"
out1="$(run)"; rc1=$?
dest="$profiles/pure"
check "harvest exits 0"                    '[ "$rc1" -eq 0 ]'
check "names the copy from the org"        '[ -d "$dest" ]'
check "transcripts copied"                 '[ "$(cat "$dest/projects/-home-me-x/session.jsonl")" = "TRANSCRIPT-acct-one" ]'
check "prompt history copied"              '[ "$(cat "$dest/history.jsonl")" = "HISTORY" ]'
check "credentials copied"                 '[[ "$(cat "$dest/.credentials.json")" = TOKEN-acct-one* ]]'
check "settings copied"                    '[ -f "$dest/settings.json" ]'
# Symlinks stay symlinks — they point at absolute paths, so the copy resolves
# them exactly like the live profile does. Dereferencing would inflate the copy
# and freeze the curated set at harvest time.
check "curated set stays a symlink"        '[ -L "$dest/CLAUDE.md" ]'
check "…and still resolves"                '[ "$(cat "$dest/CLAUDE.md")" = "AGENT INSTRUCTIONS" ]'

# ── Case 2: regenerable trees are excluded — 18MB of the 26MB on the real box ─
check "plugins/ excluded"                  '[ ! -e "$dest/plugins" ]'
check "cache/ excluded"                    '[ ! -e "$dest/cache" ]'
check "file-history/ excluded"             '[ ! -e "$dest/file-history" ]'
check "shell-snapshots/ excluded"          '[ ! -e "$dest/shell-snapshots" ]'
check "session-env/ excluded"              '[ ! -e "$dest/session-env" ]'

# ── Case 3: pairing — a second run finds the same copy with no --name ───────
check "pairing file written"               '[ -f "$dest/.orca-source" ]'
check "it records the account dir"         'grep -qxF "auth_dir=$auth" "$dest/.orca-source"'
check "it records the orca id"             'grep -qxF "orca_profile_id=acct-one" "$dest/.orca-source"'
printf 'NEWER\n' > "$auth/projects/-home-me-x/session2.jsonl"
out3="$(run)"
check "second run reuses the same copy"    '[ -f "$dest/projects/-home-me-x/session2.jsonl" ]'
# -eq, not =: BSD `wc -l` pads its count with leading spaces ("       1"), so a
# STRING compare fails on macOS and passes on Linux. Numeric compare strips it.
# (`grep -c` does not pad on either, which is why only the wc sites broke.)
check "…and creates no second directory"   '[ "$(ls -1 "$profiles" | wc -l)" -eq 1 ]'
# Pairing is by Orca id, not path, so renaming the copy by hand sticks.
mv "$dest" "$profiles/renamed"
printf 'AFTER-RENAME\n' > "$auth/history.jsonl"
out3b="$(run)"
check "a hand-renamed copy keeps being used" '[ "$(cat "$profiles/renamed/history.jsonl")" = "AFTER-RENAME" ]'
check "…and no copy reappears at the old name" '[ ! -e "$dest" ]'
mv "$profiles/renamed" "$dest"

# ── Case 4: ARCHIVE semantics — the whole reason this exists ────────────────
# A transcript that vanishes from the live profile must survive in the copy.
rm -f "$auth/projects/-home-me-x/session.jsonl"
out4="$(run)"
check "a deleted source file survives in the copy" \
  '[ "$(cat "$dest/projects/-home-me-x/session.jsonl")" = "TRANSCRIPT-acct-one" ]'
out4b="$(run --mirror)"
check "--mirror does propagate the deletion" '[ ! -e "$dest/projects/-home-me-x/session.jsonl" ]'

# ── Case 5: never interleave two accounts into one copy ─────────────────────
auth2="$(mk_account acct-two Pure)"          # same org → same default name
out5="$(run "$auth2")"; rc5=$?
check "refuses to overwrite another account'\''s copy" \
  '[ "$rc5" -ne 0 ] && printf "%s" "$out5" | grep -q "already holds account"'
check "the first copy is untouched"        '[[ "$(cat "$dest/.credentials.json")" = TOKEN-acct-one* ]]'
out5b="$(run --name two "$auth2")"
check "--name gives it its own copy"       '[[ "$(cat "$profiles/two/.credentials.json")" = TOKEN-acct-two* ]]'
# --name is required to aim at `pure` here: acct-two now has its own paired copy,
# and pairing beats the default name (Case 3). --force only waives the
# owner check, it does not redirect the destination.
out5c="$(run --name pure --force "$auth2")"
check "--force overrides the refusal"      '[[ "$(cat "$dest/.credentials.json")" = TOKEN-acct-two* ]]'

# ── Case 6: --dry-run writes nothing ────────────────────────────────────────
auth3="$(mk_account acct-three Solo)"
out6="$(run --dry-run "$auth3")"
check "dry run creates no copy"            '[ ! -e "$profiles/solo" ]'
check "dry run still reports the plan"     'printf "%s" "$out6" | grep -q "dry run"'
# A dry run must not claim it harvested — that reads as done in a bootstrap log.
check "dry run does not claim success"     '! printf "%s" "$out6" | grep -q "✓ harvested"'

# ── Case 7: naming fallbacks ────────────────────────────────────────────────
authN="$accounts/acct-noorg/auth"; mkdir -p "$authN"
printf 'x\n' > "$authN/.orca-managed-claude-auth"
printf '{"emailAddress":"someone@example.test"}\n' > "$authN/oauth-account.json"
out7="$(run "$authN")"
check "falls back to the email local part" '[ -d "$profiles/someone" ]'

# ── Case 8: restore — the recovery path ─────────────────────────────────────
# Orca re-created the account dir empty; the copy puts the transcripts back.
rm -rf "$auth2"; mkdir -p "$auth2"
printf 'FRESH\n' > "$auth2/.credentials.json"
out8="$(run --restore two)"
check "restore brings transcripts back"    '[ "$(cat "$auth2/projects/-home-me-x/session.jsonl")" = "TRANSCRIPT-acct-two" ]'
check "restore does not carry the pair file" '[ ! -e "$auth2/.orca-source" ]'
# Never --delete on the way back: the live dir may hold state newer than the snapshot.
printf 'NEWER-THAN-SNAPSHOT\n' > "$auth2/brand-new"
out8b="$(run --restore two)"
check "restore keeps state newer than the snapshot" '[ -f "$auth2/brand-new" ]'

out8c="$(ORCA_CLAUDE_ACCOUNTS_DIR="$accounts" CLAUDE_PROFILES_DIR="$profiles" \
         CLAUDE_CONFIG_DIR="$auth2" bash "$h" --restore two 2>&1)"; rc8c=$?
check "restore refuses into a live profile" \
  '[ "$rc8c" -ne 0 ] && printf "%s" "$out8c" | grep -q "CLAUDE_CONFIG_DIR IS"'
out8d="$(run --restore nope 2>&1)"; rc8d=$?
check "restore refuses an unknown name"    '[ "$rc8d" -ne 0 ]'

# ── Case 8b: a relocated profile is not harvested into itself ───────────────
# If orca-profile-link.sh ever moved a profile to the same destination, source
# and destination are one directory and rsync would copy it into itself.
relocated="$profiles/relocated"
mkdir -p "$relocated"; printf 'LIVE\n' > "$relocated/marker"
printf 'auth_dir=x\norca_profile_id=acct-reloc\n' > "$relocated/.orca-source"
authR="$accounts/acct-reloc/auth"; mkdir -p "$(dirname "$authR")"
ln -s "$relocated" "$authR"
out8e="$(run "$authR")"; rc8e=$?
check "a relocated profile is skipped, not self-copied" \
  '[ "$rc8e" -eq 0 ] && printf "%s" "$out8e" | grep -q "already relocated"'
check "…and its content is intact"         '[ "$(cat "$relocated/marker")" = "LIVE" ]'
rm -f "$authR"

# ── Case 9: an empty accounts root is a clean no-op ─────────────────────────
empty="$tmp/empty"; mkdir -p "$empty"
out9="$(env -u CLAUDE_CONFIG_DIR ORCA_CLAUDE_ACCOUNTS_DIR="$empty" \
        CLAUDE_PROFILES_DIR="$profiles" bash "$h" 2>&1)"; rc9=$?
check "no accounts → exit 0, no error"     '[ "$rc9" -eq 0 ] && printf "%s" "$out9" | grep -q "nothing to harvest"'

# ── Case 10: Orca re-creates the account — new dir id, same account ─────────
# Deleting an account and signing back in mints a fresh <orca-profile-id>. The
# copy is paired to the account's own uuid, so the re-login must be recognised
# as the same account and top the copy up — not refused as a stranger, and not
# forked into a second directory.
authR1="$(mk_account acct-relog-a Relog uuid-stable)"
out10a="$(run "$authR1")"
relog="$profiles/relog"
check "first harvest of the account"        '[ -d "$relog" ]'
check "the pair file records the uuid"      'grep -qxF "account_uuid=uuid-stable" "$relog/.orca-source"'

rm -rf "$accounts/acct-relog-a"                       # account removed in Orca
authR2="$(mk_account acct-relog-b Relog uuid-stable)" # …and signed back in
rm -f "$authR2/projects/-home-me-x/session.jsonl"     # the new dir starts blank
printf 'AFTER-RELOGIN\n' > "$authR2/projects/-home-me-x/session-new.jsonl"
out10b="$(run "$authR2")"; rc10b=$?
check "a re-login is not refused"           '[ "$rc10b" -eq 0 ]'
check "…and says what happened"             'printf "%s" "$out10b" | grep -q "re-created this account"'
check "…it reuses the same copy"            '[ -f "$relog/projects/-home-me-x/session-new.jsonl" ]'
check "…creating no second copy"            '[ "$(ls -1d "$profiles"/relog* | wc -l)" -eq 1 ]'  # -eq: see the wc -l note above
check "…and keeps what the old dir held"    \
  '[ "$(cat "$relog/projects/-home-me-x/session.jsonl")" = "TRANSCRIPT-acct-relog-a" ]'
check "the pairing follows to the new dir"  'grep -qxF "auth_dir=$authR2" "$relog/.orca-source"'

# ── Case 11: restore after a re-creation targets the LIVE dir ───────────────
# The recorded auth_dir is stale. Restoring into it would recreate an orphaned
# directory and print ✓ while Orca still showed an empty profile — the worst
# failure of the two, because restore is what you reach for when it has already
# gone wrong.
rm -rf "$accounts/acct-relog-b"
authR3="$(mk_account acct-relog-c Relog uuid-stable)"
rm -f "$authR3/projects/-home-me-x/session.jsonl"
out11="$(run --restore relog)"; rc11=$?
check "restore follows the account to its new dir" \
  '[ "$rc11" -eq 0 ] && [ "$(cat "$authR3/projects/-home-me-x/session.jsonl")" = "TRANSCRIPT-acct-relog-a" ]'
check "…and says where it went"             'printf "%s" "$out11" | grep -q "now lives at"'
check "…and does not recreate the dead dir" '[ ! -e "$accounts/acct-relog-b" ]'

# ── Case 12: an unresolvable target fails loudly, and --to overrides ────────
rm -rf "$accounts/acct-relog-c"
out12="$(run --restore relog)"; rc12=$?
check "restore refuses when nothing claims the account" \
  '[ "$rc12" -ne 0 ] && printf "%s" "$out12" | grep -q "no longer exists"'
check "…and the copy is left alone"         '[ -d "$relog/projects/-home-me-x" ]'
authR4="$accounts/acct-relog-d/auth"; mkdir -p "$authR4"
out12b="$(run --restore relog --to "$authR4")"; rc12b=$?
check "--to names the target explicitly" \
  '[ "$rc12b" -eq 0 ] && [ -f "$authR4/projects/-home-me-x/session.jsonl" ]'
check "--to is rejected outside --restore"  '! run --to "$authR4" >/dev/null 2>&1'
# --to skips the resolution above, so a typo there aims a whole profile at an
# arbitrary directory — `--to ~/.claude` would bury the primary profile.
stray="$tmp/not-a-profile"; mkdir -p "$stray"; printf 'MINE\n' > "$stray/keepme"
out12c="$(run --restore relog --to "$stray")"; rc12c=$?
check "--to refuses a target that is not an Orca profile" \
  '[ "$rc12c" -ne 0 ] && printf "%s" "$out12c" | grep -q "does not look like"'
check "…and writes nothing there"           '[ ! -e "$stray/history.jsonl" ] && [ -f "$stray/keepme" ]'
printf 'x\n' > "$stray/.orca-managed-claude-auth"
out12d="$(run --restore relog --to "$stray")"; rc12d=$?
check "…but accepts one carrying Orca's marker" \
  '[ "$rc12d" -eq 0 ] && [ -f "$stray/history.jsonl" ]'
rm -f "$stray/.orca-managed-claude-auth"
out12e="$(run --restore relog --to "$stray" --force)"; rc12e=$?
check "…and --force waives the check"       '[ "$rc12e" -eq 0 ]'

# A copy paired by uuid must still be defended by the owner guard when --name
# aims a DIFFERENT account at it (--name bypasses the pairing lookup entirely).
authX="$(mk_account acct-other Otherco)"
out12f="$(run --name relog "$authX")"; rc12f=$?
check "--name cannot aim another account at a paired copy" \
  '[ "$rc12f" -ne 0 ] && printf "%s" "$out12f" | grep -q "already holds account"'

# ── Case 13: copies harvested before uuids were recorded still pair ─────────
# The live ~/.claude-profiles copy predates uuid pairing; it must not fork.
authL="$(mk_account acct-legacy Legacy uuid-legacy)"
out13a="$(run "$authL")"
legacy="$profiles/legacy"
grep -v '^account_uuid=' "$legacy/.orca-source" > "$tmp/pair.tmp"
mv "$tmp/pair.tmp" "$legacy/.orca-source"
printf 'LATER\n' > "$authL/history.jsonl"
out13b="$(run "$authL")"; rc13=$?
check "a uuid-less copy still pairs by orca id" \
  '[ "$rc13" -eq 0 ] && [ "$(ls -1d "$profiles"/legacy* | wc -l)" -eq 1 ]'  # -eq: see the wc -l note above
check "…and is brought up to date"          '[ "$(cat "$legacy/history.jsonl")" = "LATER" ]'
check "…and gains a uuid on the way through" 'grep -qxF "account_uuid=uuid-legacy" "$legacy/.orca-source"'

# An empty uuid means "unknown", never "matches the other unknown" — two
# unidentifiable accounts must not collapse into one copy.
authU="$accounts/acct-noid/auth"; mkdir -p "$authU"
printf '{"organizationName":"Other","emailAddress":"other@example.test"}\n' > "$authU/oauth-account.json"
out13c="$(run "$authU")"; rc13c=$?
check "unidentified accounts do not pair with each other" \
  '[ "$rc13c" -eq 0 ] && [ -d "$profiles/other" ] && [ -d "$profiles/someone" ]'
check "…and no uuid is invented for them"   '! grep -q "^account_uuid=" "$profiles/other/.orca-source"'

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME TESTS FAILED"; fi
exit "$fail"
