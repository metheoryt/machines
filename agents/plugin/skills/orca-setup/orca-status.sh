#!/usr/bin/env bash
# orca-status.sh — READ-ONLY report of how a repo's Orca worktree hook fields are
# currently wired. Never writes orca-data.json; safe with Orca open.
#
# Usage: orca-status.sh <orca-data.json> <origin-url> <expected-setup> <expected-teardown> <base-path>
# Prints TWO lines, one per Orca hook slot:
#   setup<TAB><TOKEN>
#   archive<TAB><TOKEN>
# where TOKEN is WIRED | UNWIRED | ABSENT | CONFLICT<TAB><current-value>. Exit 0.
#
# Orca hook keys: Setup = hookSettings.scripts.setup; Delete = hookSettings.scripts.archive.
#
# Note: this derives Orca's `github:owner/repo` projectId, a DIFFERENT string
# shape from fleet-pull.sh's `host/owner/repo` normalize_url — the two serve
# different stores, so the small overlap in URL-stripping is intentional.
set -u

DATA="${1:-}"; ORIGIN="${2:-}"; EXPECT_SETUP="${3:-}"; EXPECT_TEARDOWN="${4:-}"; BASE="${5:-}"

# No data file: both slots ABSENT (never an error).
if [ -z "$DATA" ] || [ ! -f "$DATA" ]; then
  printf 'setup\tABSENT\narchive\tABSENT\n'
  exit 0
fi

# Derive Orca's projectId (e.g. github:owner/repo) from a git origin URL.
project_id() {
  local u="$1"
  u="${u%.git}"
  u="${u#ssh://}"; u="${u#git+ssh://}"; u="${u#https://}"; u="${u#http://}"
  u="${u#git@}"; u="${u#*@}"
  u="${u/://}"
  u="${u/:/\/}"
  local host="${u%%/*}" rest="${u#*/}"
  local provider
  case "$host" in
    github.com)    provider=github ;;
    gitlab.com)    provider=gitlab ;;
    bitbucket.org) provider=bitbucket ;;
    *)             provider="$host" ;;
  esac
  printf '%s:%s' "$provider" "$rest"
}

pid="$(project_id "$ORIGIN")"

# Read one slot's current value. Prefer .projectHostSetups[] by projectId; fall back
# to .repos[] by base path. "" = entry present but key unset; __ABSENT__ = no entry.
read_slot() {
  local key="$1"
  jq -r --arg pid "$pid" --arg base "$BASE" --arg key "$key" '
    ( [ .projectHostSetups[]? | select(.projectId == $pid) ] ) as $phs
    | ( [ .repos[]? | select(.path == $base) ] ) as $rp
    | if   ($phs | length) > 0 then ($phs[0].hookSettings.scripts[$key] // "")
      elif ($rp  | length) > 0 then ($rp[0].hookSettings.scripts[$key]  // "")
      else "__ABSENT__" end
  ' "$DATA" 2>/dev/null || printf '__ABSENT__'
}

classify() {
  local slot="$1" current="$2" expect="$3"
  case "$current" in
    __ABSENT__) printf '%s\tABSENT\n' "$slot" ;;
    "")         printf '%s\tUNWIRED\n' "$slot" ;;
    "$expect")  printf '%s\tWIRED\n' "$slot" ;;
    *)          printf '%s\tCONFLICT\t%s\n' "$slot" "$current" ;;
  esac
}

classify setup   "$(read_slot setup)"   "$EXPECT_SETUP"
classify archive "$(read_slot archive)" "$EXPECT_TEARDOWN"
exit 0
