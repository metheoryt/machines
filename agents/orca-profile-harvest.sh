#!/usr/bin/env bash
# Copy an Orca-managed Claude profile OUT to $HOME, so what accumulates inside
# Orca's tree survives Orca.
#
# Direction and why
# -----------------
# Orca runs Claude Code against a dir it creates and owns:
#
#     ~/.local/share/orca/claude-accounts/<orca-profile-id>/auth
#
# That works — Orca picks up the account and its sessions from there, and this
# script deliberately does not disturb it. What it lacks is durability:
# transcripts under projects/, sessions/, prompt history and per-project
# auto-memory all live in a directory only Orca manages, and a re-auth or a
# reinstall takes them with it. Nothing else backs up WSL $HOME.
#
# So: one-way rsync, Orca -> ~/.claude-profiles/<name>/. Read-only with respect
# to Orca, no symlink in its tree, nothing to migrate, and no coupling to how
# Orca lays its directories out. The copy is a snapshot — anything since the last
# run is not in it — which is the trade against relocating the profile outright.
#
# The copy is a WORKING profile, not an archive blob: the curated set arrives as
# symlinks (they point at absolute ~/.claude paths, so they still resolve), which
# means you can run against it directly —
#
#     CLAUDE_CONFIG_DIR=~/.claude-profiles/pure claude
#
# — to read old sessions outside Orca, or cherry-pick transcripts between
# profiles by hand.
#
# ARCHIVE SEMANTICS: no --delete. A file that vanishes from the live profile
# stays in the copy. That is the point — this exists so a transcript cannot be
# lost, and a mirror that faithfully reproduces a deletion would not do that.
# Pass --mirror when you want an exact copy instead.
#
# RE-CREATED ACCOUNTS: a copy is paired to the Claude account's own accountUuid,
# not to Orca's directory id. Removing an account and signing back in gives Orca
# a fresh <orca-profile-id>, so id- or path-based pairing would read the re-login
# as a brand-new account: harvest would refuse to touch the existing copy, and
# --restore would write into the dead directory and report success. The uuid is
# stable across re-logins, so both follow the account to its new home. The
# snapshot itself is never at risk either way — without --delete, a blank or
# missing source copies nothing and removes nothing.
#
# Excluded (regenerable, and 18MB of the 26MB): plugins/ rebuilds itself from
# settings.json on launch; caches, file-history/, shell-snapshots/, session-env/
# and tmp/ are scratch.
#
# Usage:
#   bash agents/orca-profile-harvest.sh                    # every account
#   bash agents/orca-profile-harvest.sh --name pure [<dir>]
#   bash agents/orca-profile-harvest.sh --restore <name>   # copy back
#   …plus --dry-run, --mirror, --force, --to <auth-dir>
set -u

ACCOUNTS_DIR="${ORCA_CLAUDE_ACCOUNTS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/orca/claude-accounts}"
PROFILES_DIR="${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}"
# Written into each copy; pairs it with the account it was harvested from, so a
# later run finds the same destination without being told the name again.
PAIR_FILE=".orca-source"

DRY_RUN="${DRY_RUN:-}"
MIRROR=0
FORCE=0
MODE=harvest
NAME=""
ARG=""
TO=""

die() { printf 'orca-profile-harvest: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)    shift; NAME="${1:-}"; [ -n "$NAME" ] || die "--name needs a value" 2 ;;
    --to)      shift; TO="${1:-}"; [ -n "$TO" ] || die "--to needs a value" 2 ;;
    --restore) MODE=restore ;;
    --mirror)  MIRROR=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,53p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)        die "unknown flag $1" 2 ;;
    *)         [ -z "$ARG" ] && ARG="${1%/}" || die "unexpected argument $1" 2 ;;
  esac
  shift
done

[ -n "$TO" ] && [ "$MODE" != restore ] && die "--to only applies to --restore" 2

command -v rsync >/dev/null 2>&1 || die "rsync is required but not installed"
_resolve() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }

# Scratch and regenerable state. Kept as one list so harvest and restore agree
# on what is not worth copying in either direction.
EXCLUDES="
plugins/
cache/
file-history/
shell-snapshots/
session-env/
paste-cache/
pr-cache/
gortex-cache/
downloads/
tmp/
daemon/
telemetry/
statsig/
.bootstrap-bak/
"
rsync_args() {
  printf '%s\n' -a --human-readable
  [ "$MIRROR" -eq 1 ] && printf '%s\n' --delete
  [ -n "$DRY_RUN" ] && printf '%s\n' --dry-run --itemize-changes
  local e
  for e in $EXCLUDES; do printf '%s\n' --exclude "$e"; done
}

# orca_id <auth-dir>: the id Orca keys the account by — the parent dir's name.
#
# Resolves the PARENT, never the auth path itself. If auth is a symlink (a
# profile relocated by orca-profile-link.sh), resolving it first lands on the
# link target and yields the profiles root as the "id" — pairing every relocated
# account to the same bogus name.
orca_id() { basename "$(_resolve "$(dirname "$1")")"; }

# account_uuid <auth-dir>: the Claude account's own id, from oauth-account.json.
#
# STABLE across re-logins, unlike the Orca dir id, which Orca re-mints when an
# account is removed and added back. That makes it the pairing key.
#
# Empty when the profile has no oauth-account.json yet, or when jq is missing.
# Callers MUST treat empty as "unknown" and never match two empties to each
# other — that would pair every unidentifiable account into one destination.
account_uuid() {
  [ -f "$1/oauth-account.json" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.accountUuid // empty' "$1/oauth-account.json" 2>/dev/null
}

# pair_get <copy-dir> <key>: one field out of a copy's pairing file.
pair_get() { sed -n "s/^$2=//p" "$1/$PAIR_FILE" 2>/dev/null | head -n1; }

# dest_for <auth-dir>: an existing copy already paired with this account, else
# empty. Matching on identity (not the path) keeps the pairing intact if the
# accounts root ever moves.
dest_for() {
  local id uuid d v
  id="$(orca_id "$1")"
  uuid="$(account_uuid "$1")"
  # Pass 1: the account uuid, which survives Orca re-minting the directory id.
  if [ -n "$uuid" ]; then
    for d in "$PROFILES_DIR"/*; do
      [ -f "$d/$PAIR_FILE" ] || continue
      v="$(pair_get "$d" account_uuid)"
      if [ -n "$v" ] && [ "$v" = "$uuid" ]; then printf '%s' "$d"; return 0; fi
    done
  fi
  # Pass 2: the Orca dir id — covers copies harvested before uuids were recorded,
  # and accounts that have no oauth-account.json to identify them by.
  for d in "$PROFILES_DIR"/*; do
    [ -f "$d/$PAIR_FILE" ] || continue
    if [ "$(pair_get "$d" orca_profile_id)" = "$id" ]; then printf '%s' "$d"; return 0; fi
  done
  return 1
}

# default_name <auth-dir>: org name, else the email local part, else the Orca
# id's first segment. Only consulted on the FIRST harvest of an account — after
# that the pairing file decides, so a rename by hand sticks.
default_name() {
  local auth="$1" n=""
  if command -v jq >/dev/null 2>&1 && [ -f "$auth/oauth-account.json" ]; then
    n="$(jq -r '.organizationName // empty' "$auth/oauth-account.json" 2>/dev/null)"
    [ -n "$n" ] || n="$(jq -r '(.emailAddress // "") | split("@")[0]' "$auth/oauth-account.json" 2>/dev/null)"
  fi
  [ -n "$n" ] || n="$(orca_id "$auth" | cut -d- -f1)"
  printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' | sed 's/-*$//'
}

harvest_one() {
  local auth="$1" dest name id uuid
  [ -d "$auth" ] || { printf '  ✗ not a directory: %s\n' "$auth"; return 1; }
  id="$(orca_id "$auth")"
  uuid="$(account_uuid "$auth")"

  if [ -n "$NAME" ]; then
    dest="$PROFILES_DIR/$NAME"
  elif dest="$(dest_for "$auth")"; then
    :                                            # already paired — reuse it
  else
    name="$(default_name "$auth")"
    dest="$PROFILES_DIR/$name"
    printf '  . first harvest of %s — naming it "%s" (override with --name)\n' "$id" "$name"
  fi

  # If the account dir is a symlink pointing AT the destination, the profile has
  # been relocated there (orca-profile-link.sh) and source and destination are
  # one directory. Harvesting would rsync it into itself. Nothing to copy — the
  # data already lives in $HOME, which is what harvesting is for.
  if [ "$(_resolve "$auth")" = "$(_resolve "$dest")" ]; then
    printf '  = %s is already relocated to %s — nothing to harvest\n' "$auth" "$dest"
    return 0
  fi

  # Refuse to write into a directory that is some OTHER account's copy; two
  # profiles rsynced over each other would interleave transcripts and auth.
  # A re-login is NOT that case: same account, new Orca dir id.
  if [ -f "$dest/$PAIR_FILE" ]; then
    local owner owner_uuid
    owner="$(pair_get "$dest" orca_profile_id)"
    owner_uuid="$(pair_get "$dest" account_uuid)"
    if [ -n "$uuid" ] && [ -n "$owner_uuid" ] && [ "$uuid" != "$owner_uuid" ]; then
      # Both sides identified, and they are different accounts — even if Orca
      # happened to hand the dir id back out to this one.
      if [ "$FORCE" -eq 0 ]; then
        printf '  ✗ %s already holds account %s — refusing to overwrite with %s\n' "$dest" "$owner_uuid" "$uuid"
        printf '    Pick another --name, or pass --force.\n'
        return 1
      fi
    elif [ -n "$uuid" ] && [ "$uuid" = "$owner_uuid" ]; then
      [ "$owner" != "$id" ] && \
        printf '  . Orca re-created this account (%s -> %s) — same account, topping the copy up\n' "$owner" "$id"
    elif [ -n "$owner" ] && [ "$owner" != "$id" ] && [ "$FORCE" -eq 0 ]; then
      # One side or the other is unidentifiable; fall back to the dir id.
      printf '  ✗ %s already holds account %s — refusing to overwrite with %s\n' "$dest" "$owner" "$id"
      printf '    Pick another --name, or pass --force.\n'
      return 1
    fi
  fi

  printf '\n%s\n  -> %s%s\n' "$auth" "$dest" "$([ "$MIRROR" -eq 1 ] && printf ' (mirror: deletions propagate)')"
  if [ -z "$DRY_RUN" ]; then
    mkdir -p "$dest" || return 1
  fi
  # Trailing slash on the source: copy its CONTENTS into dest, not the dir itself.
  local args=(); while IFS= read -r a; do args+=("$a"); done < <(rsync_args)
  rsync "${args[@]}" "$auth"/ "$dest"/ || { printf '  ✗ rsync failed\n'; return 1; }

  if [ -z "$DRY_RUN" ]; then
    {
      printf '# Written by agents/orca-profile-harvest.sh. This directory is a COPY of an\n'
      printf '# Orca-managed profile, not the live one — Orca still reads auth_dir below.\n'
      printf 'auth_dir=%s\n' "$auth"
      printf 'orca_profile_id=%s\n' "$id"
      # Only when known — an empty value would read back as "unidentified" and
      # must not look like a uuid that happens to match another empty one.
      [ -n "$uuid" ] && printf 'account_uuid=%s\n' "$uuid"
      printf 'harvested_by=%s\n' "$(uname -n 2>/dev/null || printf unknown)"
    } > "$dest/$PAIR_FILE"
  fi
  printf '  %s\n' "$([ -n "$DRY_RUN" ] && printf '~ would harvest' || printf '✓ harvested')"
  return 0
}

# restore <name>: copy a harvested profile back over the live account dir. The
# recovery path — deliberately a real command rather than a remembered rsync
# incantation, because you reach for it exactly when something has gone wrong.
restore_one() {
  local name="$1" dest auth uuid
  [ -n "$name" ] || die "--restore needs the profile name (see $PROFILES_DIR)" 2
  dest="$PROFILES_DIR/$name"
  [ -d "$dest" ] || die "no such harvested profile: $dest"
  auth="$(pair_get "$dest" auth_dir)"
  uuid="$(pair_get "$dest" account_uuid)"
  [ -n "$TO" ] && auth="$TO"
  [ -n "$auth" ] || die "$dest/$PAIR_FILE does not record an auth_dir"

  # The recorded path goes stale when Orca re-creates the account: the new
  # profile is a new <orca-profile-id>, and the old directory is gone. Restoring
  # into it would recreate an orphan and print ✓ while Orca still shows nothing.
  # Re-resolve by the account uuid, which the re-login carries over.
  if [ ! -d "$auth" ] && [ -z "$TO" ]; then
    local match="" n=0 d
    if [ -n "$uuid" ]; then
      for d in "$ACCOUNTS_DIR"/*/auth; do
        [ -d "$d" ] || continue
        [ "$(account_uuid "$d")" = "$uuid" ] || continue
        match="$d"; n=$((n + 1))
      done
    fi
    if [ "$n" -eq 1 ]; then
      printf 'Recorded profile dir is gone:\n  %s\nAccount %s now lives at\n  %s\n' "$auth" "$uuid" "$match"
      auth="$match"
    else
      printf 'orca-profile-harvest: the recorded profile dir no longer exists:\n  %s\n' "$auth" >&2
      if [ -z "$uuid" ]; then
        printf '  %s/%s records no account_uuid, so the new dir cannot be identified.\n' "$dest" "$PAIR_FILE" >&2
      elif [ "$n" -gt 1 ]; then
        printf '  %s live profiles claim account %s — too ambiguous to pick one.\n' "$n" "$uuid" >&2
      else
        printf '  No live profile claims account %s (sign in to Orca first?).\n' "$uuid" >&2
      fi
      printf '  Live profiles:\n' >&2
      for d in "$ACCOUNTS_DIR"/*/auth; do [ -d "$d" ] && printf '    %s\n' "$d" >&2; done
      die "pass --to <auth-dir> to name the target explicitly" 4
    fi
  fi

  # --to skips the resolution above, so it is the one path where a typo aims a
  # whole profile — credentials, transcripts, .orca-managed-claude-auth — at an
  # arbitrary directory. `--to ~/.claude` would bury the primary profile under an
  # Orca snapshot. Require the target to look like an Orca-managed profile: under
  # the accounts root, or already carrying Orca's marker (which a relocated
  # profile does). --force waives it.
  if [ -n "$TO" ] && [ "$FORCE" -eq 0 ]; then
    local to_real accounts_real
    to_real="$(_resolve "$TO")"; accounts_real="$(_resolve "$ACCOUNTS_DIR")"
    case "$to_real" in
      "$accounts_real"/*) ;;
      *)
        [ -f "$TO/.orca-managed-claude-auth" ] || die "--to $TO does not look like an
  Orca-managed profile: it is not under $ACCOUNTS_DIR and carries no
  .orca-managed-claude-auth marker. Restoring there would write a full profile
  over whatever is in it. Pass --force if you meant it." 5 ;;
    esac
  fi

  # Writing into a profile a session is using would have Claude and rsync racing
  # for the same transcript. Same check as orca-profile-link.sh.
  if [ "$FORCE" -eq 0 ]; then
    if [ "$(_resolve "${CLAUDE_CONFIG_DIR:-/nonexistent}")" = "$(_resolve "$auth")" ]; then
      die "this shell's CLAUDE_CONFIG_DIR IS $auth — close Orca and restore from a
  plain terminal, or pass --force." 3
    fi
    local envfile pid
    if [ -d /proc ]; then
      for envfile in /proc/[0-9]*/environ; do
        [ -r "$envfile" ] || continue
        if tr '\0' '\n' < "$envfile" 2>/dev/null | grep -qxF "CLAUDE_CONFIG_DIR=$auth"; then
          pid="${envfile#/proc/}"; pid="${pid%/environ}"
          die "pid $pid is running against $auth — close it first, or pass --force." 3
        fi
      done
    fi
  fi

  printf 'Restoring\n  from: %s\n  to:   %s\n' "$dest" "$auth"
  [ -z "$DRY_RUN" ] && mkdir -p "$auth"
  # Never --delete on the way back, whatever --mirror says: the live dir may hold
  # newer state than the snapshot, and losing it is the failure this guards against.
  local args=(); while IFS= read -r a; do args+=("$a"); done < <(MIRROR=0 rsync_args)
  rsync "${args[@]}" --exclude "$PAIR_FILE" "$dest"/ "$auth"/ || die "rsync failed"
  printf '  ✓ restored (the live profile keeps anything newer than the snapshot)\n'
}

if [ "$MODE" = restore ]; then
  [ -n "$DRY_RUN" ] && printf '(dry run — nothing will be written)\n'
  restore_one "${NAME:-$ARG}"
  exit 0
fi

# ── harvest ─────────────────────────────────────────────────────────────────
targets=()
if [ -n "$ARG" ]; then
  targets+=("$ARG")
else
  for d in "$ACCOUNTS_DIR"/*/auth; do
    [ -d "$d" ] || continue
    targets+=("$d")
  done
  if [ "${#targets[@]}" -eq 0 ]; then
    printf 'No Orca-managed Claude profiles under %s — nothing to harvest.\n' "$ACCOUNTS_DIR"
    exit 0
  fi
  if [ -n "$NAME" ] && [ "${#targets[@]}" -gt 1 ]; then
    die "--name with several accounts is ambiguous — name the auth dir too" 2
  fi
fi

printf 'Harvesting Orca profiles -> %s\n' "$PROFILES_DIR"
[ -n "$DRY_RUN" ] && printf '(dry run — nothing will be written)\n'

rc=0
for d in "${targets[@]}"; do
  harvest_one "${d%/}" || rc=1
done
exit "$rc"
