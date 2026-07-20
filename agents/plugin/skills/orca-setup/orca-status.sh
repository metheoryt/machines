#!/usr/bin/env bash
# orca-status.sh — READ-ONLY report of how a repo's Orca worktree setup-script
# field is currently wired. Never writes orca-data.json; safe with Orca open.
#
# Usage: orca-status.sh <orca-data.json> <origin-url> <expected-setup> <base-path>
# Prints ONE line: WIRED | UNWIRED | ABSENT | CONFLICT<TAB><current-value>. Exit 0.
#
# Note: this derives Orca's `github:owner/repo` projectId, a DIFFERENT string
# shape from fleet-pull.sh's `host/owner/repo` normalize_url — the two serve
# different stores, so the small overlap in URL-stripping is intentional, not a
# missed DRY.
set -u

DATA="${1:-}"; ORIGIN="${2:-}"; EXPECT="${3:-}"; BASE="${4:-}"

[ -n "$DATA" ] && [ -f "$DATA" ] || { echo "ABSENT"; exit 0; }

# Derive Orca's projectId (e.g. github:owner/repo) from a git origin URL.
project_id() {
  local u="$1"
  u="${u%.git}"
  u="${u#ssh://}"; u="${u#git+ssh://}"; u="${u#https://}"; u="${u#http://}"
  u="${u#git@}"; u="${u#*@}"     # strip any user@
  u="${u/://}"                    # scp-form host:owner -> host/owner (first :)
  u="${u/:/\/}"                   # port-less colon safeguard
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

# Read current setup: prefer .projectHostSetups[] matched by projectId; fall back
# to .repos[] matched by base path (.repos[] has no projectId). "" means the key
# is present but unset; sentinel __ABSENT__ means no entry in either array.
current="$(jq -r --arg pid "$pid" --arg base "$BASE" '
  ( [ .projectHostSetups[]? | select(.projectId == $pid) ] ) as $phs
  | ( [ .repos[]? | select(.path == $base) ] ) as $rp
  | if   ($phs | length) > 0 then ($phs[0].hookSettings.scripts.setup // "")
    elif ($rp  | length) > 0 then ($rp[0].hookSettings.scripts.setup  // "")
    else "__ABSENT__" end
' "$DATA" 2>/dev/null)" || current="__ABSENT__"

case "$current" in
  __ABSENT__) printf 'ABSENT\n' ;;
  "")         printf 'UNWIRED\n' ;;
  "$EXPECT")  printf 'WIRED\n' ;;
  *)          printf 'CONFLICT\t%s\n' "$current" ;;
esac
exit 0
