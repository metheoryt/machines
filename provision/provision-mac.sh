#!/usr/bin/env bash
# provision/provision-mac.sh — provision THIS Mac as a fleet.json member, end to
# end. Run from inside the clone:
#   bash ~/machines/provision/provision-mac.sh air
#
# Chain (design: docs/superpowers/specs/2026-07-27-macos-one-command-provisioning-design.md):
#   1. macos-prep.sh <machine>          sudo once: hostname, Homebrew, Remote Login
#   2. tailscale-mac.sh --hostname …    tailnet enrollment + IP check
#   3. macos.sh                         the tier list (toolchain, agent config, launchd)
#   4. provision.sh --machine … --apply roles: agents, dotfiles, repos
#
# Orchestration only — every stage's logic lives in the stage, matching
# provision-wsl.sh. Stages 1-3 are fatal on failure; stage 4 is interactive
# (it confirms per role) and its exit status is reported, not enforced.
#
# The machine name is an ARGUMENT rather than detected, because stage 1 is what
# sets the hostname — detection cannot work before it runs.
set -u

info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN=0
MACHINE=""
AUTHKEY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)        DRY_RUN=1; shift ;;
    --authkey-file)   AUTHKEY_FILE="${2:-}"; [ -n "$AUTHKEY_FILE" ] || die "--authkey-file needs a path."; shift 2 ;;
    --authkey-file=*) AUTHKEY_FILE="${1#*=}"; shift ;;
    -h|--help)        sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)               die "unknown arg: $1" ;;
    *)                [ -z "$MACHINE" ] || die "unexpected extra argument: $1"; MACHINE="$1"; shift ;;
  esac
done
[ -n "$MACHINE" ] || die "usage: provision-mac.sh <machine> [--authkey-file <path>] [--dry-run]"

# ── Validate the machine BEFORE anything mutates ──────────────────────────────
# A typo here would otherwise rename the Mac to a name the manifest has never
# heard of, and only surface three stages later.
FLEET_JSON="$REPO/fleet.json"
[ -f "$FLEET_JSON" ] || die "fleet.json not found at $FLEET_JSON"
have jq || die "jq not found — install it first (brew install jq), or run macos-prep.sh"

PLATFORM="$(jq -r --arg m "$MACHINE" '.machines[$m].platform // empty' "$FLEET_JSON")"
if [ -z "$PLATFORM" ]; then
  die "machine '$MACHINE' is not in fleet.json. Known: $(jq -r '.machines | keys | join(", ")' "$FLEET_JSON")"
fi
[ "$PLATFORM" = darwin ] || die "machine '$MACHINE' has platform '$PLATFORM', not darwin — refusing"

STAGES=(
  "macos-prep.sh $MACHINE"
  "tailscale-mac.sh --hostname $MACHINE${AUTHKEY_FILE:+ --authkey-file $AUTHKEY_FILE}"
  "macos.sh"
  "provision.sh --machine $MACHINE --apply"
)

if [ "$DRY_RUN" = 1 ]; then
  printf 'provision-mac plan for %s (platform: %s)\n' "$MACHINE" "$PLATFORM"
  i=1
  for s in "${STAGES[@]}"; do printf '%d/%d %s\n' "$i" "${#STAGES[@]}" "$s"; i=$((i + 1)); done
  exit 0
fi

[ "$(uname -s)" = "Darwin" ] || die "this script targets macOS; this box is $(uname -s)."

printf '\n\033[1mProvisioning %s\033[0m from %s\n' "$MACHINE" "$REPO"

info "1/4 privileged setup (hostname, Homebrew, Remote Login)…"
bash "$REPO/provision/macos-prep.sh" "$MACHINE" || die "macos-prep.sh failed"

info "2/4 tailnet enrollment…"
# shellcheck disable=SC2086  # deliberate word-split: optional --authkey-file pair
bash "$REPO/provision/tailscale-mac.sh" --hostname "$MACHINE" \
  ${AUTHKEY_FILE:+--authkey-file "$AUTHKEY_FILE"} || die "tailscale-mac.sh failed"

info "3/4 toolchain + agent config + launchd timers…"
bash "$REPO/provision/macos.sh" || die "macos.sh failed"

info "4/4 roles (agents, dotfiles, repos)…"
bash "$REPO/provision/provision.sh" --machine "$MACHINE" --apply
role_rc=$?

printf '\n\033[1mProvisioned %s.\033[0m\n' "$MACHINE"
[ "$role_rc" -eq 0 ] || printf '\033[0;33m! the role stage exited %s — re-run: bash provision/provision.sh --machine %s --apply\033[0m\n' "$role_rc" "$MACHINE"
cat <<EOF

Next, by hand (not scriptable):
  • Register the SSH keys before any clone — tier_ssh_accounts wrote
    IdentitiesOnly on fresh keys, so git over SSH fails until:
        gh auth login          # SSH → ~/.ssh/id_metheoryt.pub
        ssh -T git@github.com
  • Enroll this box's fleet key so other members accept it:
        cat ~/.ssh/id_fleet.pub >> $REPO/provision/fleet-authorized-keys
        cd $REPO && git add -A && git commit -m 'feat(fleet): trust ${MACHINE}'\''s fleet key' && git push
    then 'git pull' on the other members.
  • Verify the launchd agents loaded:  launchctl list | grep kz.cyphy
EOF
exit 0
