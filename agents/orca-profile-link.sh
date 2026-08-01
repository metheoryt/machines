#!/usr/bin/env bash
# Move an Orca-managed Claude account profile into $HOME and leave a symlink
# behind, so the profile outlives the account dir Orca owns.
#
# Why
# ---
# Orca points CLAUDE_CONFIG_DIR at a dir it created and controls:
#
#     ~/.local/share/orca/claude-accounts/<orca-profile-id>/auth
#
# Everything that accumulates in a profile lives there — transcripts under
# projects/, sessions/, prompt history, per-project auto-memory. If Orca ever
# drops or re-creates that dir (re-auth, account removed, reinstall), all of it
# goes with it. On this box that was 525MB of transcripts sitting inside a
# directory no one but Orca manages.
#
# After this script:
#
#     ~/.claude-profiles/<name>/                     ← the real profile, yours
#     …/claude-accounts/<orca-id>/auth -> ~/.claude-profiles/<name>
#
# The failure mode inverts. Orca replacing the dir now costs you THE LINK, not
# the data: the profile sits untouched in $HOME and `--relink` puts it back.
# Nothing about how Claude Code reads the profile changes — a symlinked config
# dir resolves like any other, and Orca's own `mkdir -p` is satisfied by it.
#
# The curated population from ~/.claude (CLAUDE.md, memory, skills, agents,
# commands, settings) is a SEPARATE step and stays in orca-profile-sync.sh. This
# script only relocates and pairs; run the sync afterwards.
#
# Usage:
#   bash agents/orca-profile-link.sh <name> [<auth-dir>]  # migrate + link
#   bash agents/orca-profile-link.sh --status             # show every pairing
#   bash agents/orca-profile-link.sh --relink             # re-heal broken links
#   …plus --dry-run, --force (skip the Orca-dir check), --force-live (see below)
#
# <auth-dir> may be omitted when exactly one un-migrated account exists.
set -u

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNTS_DIR="${ORCA_CLAUDE_ACCOUNTS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/orca/claude-accounts}"
# Own namespace, deliberately NOT ~/.claude-<postfix>: that pattern is
# bootstrap.sh's secondary-profile registry, and a profile named there would be
# claimed by it and have the tracked baseline deployed over the mirror.
PROFILES_DIR="${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}"
# Written into each migrated profile; pairs it back to the account dir it serves.
PAIR_FILE=".orca-account"

DRY_RUN="${DRY_RUN:-}"
FORCE=0
FORCE_LIVE=0
MODE=migrate
NAME=""
AUTH=""

die() { printf 'orca-profile-link: %s\n' "$1" >&2; exit "${2:-1}"; }
say() { printf '%s\n' "$1"; }
run() { if [ -n "$DRY_RUN" ]; then printf '  ~ would: %s\n' "$*"; else "$@"; fi; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --status)     MODE=status ;;
    --relink)     MODE=relink ;;
    --dry-run)    DRY_RUN=1 ;;
    --force)      FORCE=1 ;;
    --force-live) FORCE_LIVE=1 ;;
    -h|--help)    sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)           die "unknown flag $1" 2 ;;
    *)            if [ -z "$NAME" ]; then NAME="$1"; elif [ -z "$AUTH" ]; then AUTH="${1%/}"; else die "unexpected argument $1" 2; fi ;;
  esac
  shift
done

_resolve() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }

# looks_like_orca_dir <dir>: Orca's own marker, our pairing marker, or the
# canonical path. Same test orca-profile-sync.sh uses, plus PAIR_FILE so an
# already-migrated profile still identifies as one from its new home.
looks_like_orca_dir() {
  [ -f "$1/.orca-managed-claude-auth" ] && return 0
  [ -f "$1/$PAIR_FILE" ] && return 0
  case "$1" in */orca/claude-accounts/*/auth | */orca/claude-accounts/*/auth/) return 0 ;; esac
  return 1
}

# is_live <auth-dir>: true when a Claude session is currently running against it.
# Relocating a profile out from under a live session is the one genuinely
# dangerous move here. A same-filesystem `mv` keeps already-open file descriptors
# valid, so it usually survives — but "usually" is a poor bet against a live
# transcript, and Orca may re-open paths at any moment.
#
# Returns rather than dying: `migrate` treats it as fatal (the user asked for
# exactly this profile), `--relink` skips that profile and carries on (it sweeps
# every profile, and bootstrap calls it unattended on every pull). LIVE_WHY
# carries the explanation.
LIVE_WHY=""
is_live() {
  local auth="$1" real cur envfile pid
  LIVE_WHY=""
  [ "$FORCE_LIVE" -eq 1 ] && return 1
  real="$(_resolve "$auth")"
  cur="$(_resolve "${CLAUDE_CONFIG_DIR:-/nonexistent}")"
  if [ "$cur" = "$real" ]; then
    LIVE_WHY="this shell's CLAUDE_CONFIG_DIR IS that profile"
    return 0
  fi
  # Best-effort second opinion on Linux: any other process pointed at it?
  [ -d /proc ] || return 1
  for envfile in /proc/[0-9]*/environ; do
    [ -r "$envfile" ] || continue
    if tr '\0' '\n' < "$envfile" 2>/dev/null | grep -qxF "CLAUDE_CONFIG_DIR=$auth"; then
      pid="${envfile#/proc/}"; pid="${pid%/environ}"
      LIVE_WHY="pid $pid is running against it"
      return 0
    fi
  done
  return 1
}

refuse_if_live() {
  is_live "$1" || return 0
  die "$LIVE_WHY:
    $1
  You are inside the session whose transcript would move out from under it.
  Close Orca and re-run from a plain terminal, or pass --force-live if you
  understand the risk." 3
}

# ── --status ────────────────────────────────────────────────────────────────
# Every account dir and every migrated profile, and whether the two are joined.
status() {
  local d real profile auth found=0
  printf 'Orca account dirs (%s)\n' "$ACCOUNTS_DIR"
  for d in "$ACCOUNTS_DIR"/*/auth; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    found=1
    real="$(_resolve "$d")"
    if [ -L "$d" ]; then
      if [ -d "$real" ]; then printf '  linked   %s\n           -> %s\n' "$d" "$real"
      else                    printf '  BROKEN   %s\n           -> %s (missing) — run --relink\n' "$d" "$real"; fi
    else
      printf '  in place %s  (not migrated)\n' "$d"
    fi
  done
  [ "$found" -eq 1 ] || printf '  (none)\n'
  printf '\nProfiles (%s)\n' "$PROFILES_DIR"
  found=0
  for profile in "$PROFILES_DIR"/*; do
    [ -d "$profile" ] || continue
    found=1
    auth="$(sed -n 's/^auth_dir=//p' "$profile/$PAIR_FILE" 2>/dev/null)"
    printf '  %-28s ' "$(basename "$profile")"
    if [ -z "$auth" ]; then printf 'no %s — not paired with any account\n' "$PAIR_FILE"
    elif [ "$(_resolve "$auth")" = "$(_resolve "$profile")" ]; then printf 'serving %s\n' "$auth"
    elif [ -e "$auth" ]; then printf 'DETACHED — %s exists but is not the link (run --relink)\n' "$auth"
    else printf 'DETACHED — %s is gone (run --relink to recreate)\n' "$auth"; fi
  done
  [ "$found" -eq 1 ] || printf '  (none)\n'
}

# write_pair <profile> <auth> : record which account dir this profile serves.
write_pair() {
  local profile="$1" auth="$2" email=""
  [ -n "$DRY_RUN" ] && { printf '  ~ would write %s/%s\n' "$profile" "$PAIR_FILE"; return 0; }
  if command -v jq >/dev/null 2>&1 && [ -f "$profile/oauth-account.json" ]; then
    email="$(jq -r '.emailAddress // empty' "$profile/oauth-account.json" 2>/dev/null)"
  fi
  {
    printf '# Written by agents/orca-profile-link.sh — pairs this profile with the\n'
    printf '# Orca account dir it serves. Used by --status and --relink.\n'
    printf 'auth_dir=%s\n' "$auth"
    printf 'orca_profile_id=%s\n' "$(basename "$(dirname "$auth")")"
    [ -n "$email" ] && printf 'account=%s\n' "$email"
  } > "$profile/$PAIR_FILE"
}

# ── migrate ─────────────────────────────────────────────────────────────────
migrate() {
  local name="$1" auth="$2" profile real

  [ -n "$name" ] || die "a profile name is required (e.g. \`pure\`)" 2
  case "$name" in */*|.*) die "profile name must be a bare directory name, got '$name'" 2 ;; esac
  profile="$PROFILES_DIR/$name"

  # Discover the account dir when not given: unambiguous only if there is
  # exactly one that has not been migrated yet.
  if [ -z "$auth" ]; then
    local d cands=()
    for d in "$ACCOUNTS_DIR"/*/auth; do
      [ -d "$d" ] && [ ! -L "$d" ] && cands+=("$d")
    done
    case "${#cands[@]}" in
      0) die "no un-migrated account dirs under $ACCOUNTS_DIR (see --status)" ;;
      1) auth="${cands[0]}" ;;
      *) die "several un-migrated accounts — name the one you mean:
$(printf '    %s\n' "${cands[@]}")" 2 ;;
    esac
  fi

  [ -d "$auth" ] || die "not a directory: $auth"
  if [ -L "$auth" ]; then
    real="$(_resolve "$auth")"
    say "  = already migrated: $auth -> $real"
    say "    (nothing to do; populate it with: bash agents/orca-profile-sync.sh)"
    return 0
  fi
  if [ "$FORCE" -eq 0 ] && ! looks_like_orca_dir "$auth"; then
    die "not an Orca-managed auth dir (no .orca-managed-claude-auth): $auth
  Pass --force if you really mean this path."
  fi
  if [ -e "$profile" ]; then
    die "$profile already exists.
  Refusing to merge two profiles. Pick another name, or move the existing one
  aside first — this script never overwrites profile content."
  fi
  refuse_if_live "$auth"

  say "Migrating"
  say "  from: $auth"
  say "  to:   $profile"
  run mkdir -p "$PROFILES_DIR"
  # mv keeps inodes (both paths are under $HOME, one filesystem), so anything
  # holding an open fd keeps working. cp+rm is the cross-device fallback.
  if [ -n "$DRY_RUN" ]; then
    printf '  ~ would: mv %s %s\n' "$auth" "$profile"
  elif ! mv "$auth" "$profile" 2>/dev/null; then
    say "  ! mv failed (different filesystem?) — falling back to copy + remove"
    cp -a "$auth" "$profile" || die "copy failed; nothing was removed"
    rm -rf "$auth" || die "copy succeeded but removing $auth failed — link it by hand"
  fi
  write_pair "$profile" "$auth"
  run ln -s "$profile" "$auth"
  say "  + linked: $auth -> $profile"
  say ""
  say "Now populate the curated set from ~/.claude:"
  say "    bash agents/orca-profile-sync.sh"
}

# ── --relink ────────────────────────────────────────────────────────────────
# Orca re-created the account dir (re-auth, reinstall): the link is gone and a
# fresh real dir sits in its place. Fold the genuinely new state into the
# profile, then re-establish the link.
#
# Only the AUTH set is taken from the new dir — those files are the point of a
# re-auth and must win. Everything else the profile already has is kept: a fresh
# account dir also carries a pristine 3-key settings.json that would otherwise
# clobber the merged one, and empty projects/ + sessions/ that would look like a
# wiped history. Anything the profile does NOT have is copied over as-is.
AUTH_SET=".credentials.json oauth-account.json .orca-managed-claude-auth .claude.json"

relink_one() {
  local profile="$1" auth base f
  auth="$(sed -n 's/^auth_dir=//p' "$profile/$PAIR_FILE" 2>/dev/null)"
  [ -n "$auth" ] || { printf '  . %s: no %s, skipping\n' "$(basename "$profile")" "$PAIR_FILE"; return 0; }

  if [ -L "$auth" ] && [ "$(_resolve "$auth")" = "$(_resolve "$profile")" ]; then
    printf '  = %s: link healthy\n' "$(basename "$profile")"
    return 0
  fi

  if [ -d "$auth" ] && [ ! -L "$auth" ]; then
    # Skip, do not abort: this runs unattended from bootstrap after every pull,
    # and one live profile must not stop the others from healing.
    if is_live "$auth"; then
      printf '  . %s: skipped — %s (close Orca, then re-run --relink)\n' "$(basename "$profile")" "$LIVE_WHY"
      return 0
    fi
    printf '  ~ %s: account dir was re-created — folding it in\n' "$(basename "$profile")"
    for f in "$auth"/* "$auth"/.[!.]*; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      case " $AUTH_SET " in
        *" $base "*)  run cp -a "$f" "$profile/$base"; printf '    + fresh auth state: %s\n' "$base"; continue ;;
      esac
      [ -e "$profile/$base" ] && continue          # profile's copy wins
      run cp -a "$f" "$profile/$base"
      printf '    + new: %s\n' "$base"
    done
    run rm -rf "$auth"
  elif [ -L "$auth" ]; then
    printf '  ~ %s: link points elsewhere (%s) — repointing\n' "$(basename "$profile")" "$(readlink "$auth")"
    run rm -f "$auth"
  else
    printf '  ~ %s: account dir is gone — recreating the link\n' "$(basename "$profile")"
  fi

  run mkdir -p "$(dirname "$auth")"
  run ln -s "$profile" "$auth"
  printf '    + linked: %s -> %s\n' "$auth" "$profile"
}

relink() {
  local profile found=0
  printf 'Re-heal (%s)\n' "$PROFILES_DIR"
  for profile in "$PROFILES_DIR"/*; do
    [ -d "$profile" ] || continue
    found=1
    relink_one "$profile"
  done
  [ "$found" -eq 1 ] || printf '  (no profiles)\n'
}

[ -n "$DRY_RUN" ] && say "(dry run — nothing will be written)"
case "$MODE" in
  status)  status ;;
  relink)  relink ;;
  migrate) migrate "$NAME" "$AUTH" ;;
esac
