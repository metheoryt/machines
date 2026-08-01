#!/usr/bin/env bash
# Mirror the PRIMARY Claude profile (~/.claude) into Orca's per-account config
# dirs. Run ONCE PER ORCA AUTH — idempotent, so re-running costs nothing.
#
# Why this exists
# ---------------
# Orca launches Claude Code with CLAUDE_CONFIG_DIR pointed at a per-account dir:
#
#     ~/.local/share/orca/claude-accounts/<account-uuid>/auth
#
# That dir is created fresh at login and holds ONLY account/session state
# (.credentials.json, oauth-account.json, .claude.json, projects/, sessions/…).
# None of the primary profile's content follows it, so switching to an
# Orca-managed profile silently drops: settings.json (hooks, statusline,
# enabledPlugins), CLAUDE.md, memory/ + host-memory.md (the cyphy
# global-memory-load.sh hook reads "$CLAUDE_CONFIG_DIR/memory", so the synced
# memory stores go dark), every entry under skills/ (including the `cyphy`
# plugin link), agents/ and commands/.
#
# bootstrap.sh already fans the SHARED set out to ~/.claude-<postfix>, but it
# cannot serve this case: it keys a profile off the
# `.claude-<postfix>` basename (an Orca dir is named `auth`), and it deploys the
# REPO baseline. What an Orca profile needs is the LIVE primary profile —
# including the machine-local parts the repo never carries (`gortex install`'s
# skills/agents/commands, plugin state written through /plugin and /config).
#
# So: content paths are SYMLINKED at the primary profile — one edit, every
# profile sees it, exactly like the secondary-profile fan-out. settings.json is
# the sole exception; see merge_settings.
#
# Never touched (Orca- and account-owned, and mirroring them would cross-wire
# two accounts' auth or corrupt live session state):
#   .credentials.json  oauth-account.json  .claude.json  .orca-managed-claude-auth
#   projects/  sessions/  history.jsonl  shell-snapshots/  session-env/
#   backups/  cache/  plugins/  policy-limits.json  remote-settings.json
#
# plugins/ is deliberately excluded: `enabledPlugins` + `extraKnownMarketplaces`
# ride along in settings.json, and Claude Code installs the declared
# marketplaces into the profile itself on next launch.
#
# The curated set is PROFILE_FILES + PROFILE_DIRS below — that pair IS the answer
# to "what do I want in every profile". Edit them to change it; everything else
# in a profile stays profile-specific.
#
# Pairs with agents/orca-profile-link.sh, which relocates an account profile to
# ~/.claude-profiles/<name> and leaves a symlink in Orca's tree, so transcripts
# and sessions outlive the account dir. This script follows that link and writes
# to the real profile; it also finds a migrated profile whose link is currently
# broken, so population never depends on Orca's dir being intact.
#
# Usage:
#   bash agents/orca-profile-sync.sh                 # every discovered profile
#   bash agents/orca-profile-sync.sh <auth-dir> …    # specific dirs
#   bash agents/orca-profile-sync.sh --dry-run       # report, change nothing
#   bash agents/orca-profile-sync.sh --force <dir>   # skip the Orca-dir check
#
# Also invoked automatically at the end of a personal `bootstrap.sh` run (after
# orca-profile-link.sh --relink), so a new account picked up by a pull/provision
# run is wired without a manual step.
set -u

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT="$SRC_DIR/bootstrap.sh"
# MACHINES_PRIMARY_DIR mirrors bootstrap.sh's override of the same name (tests
# point it at a throwaway dir). Computed BEFORE sourcing because it seeds
# CLAUDE_CONFIG_DIR for the source call below.
PRIMARY_DIR="${MACHINES_PRIMARY_DIR:-$HOME/.claude}"

ACCOUNTS_DIR="${ORCA_CLAUDE_ACCOUNTS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/orca/claude-accounts}"
# Where orca-profile-link.sh parks migrated profiles. Discovery reads it so a
# profile whose account link is currently broken still gets populated.
PROFILES_DIR="${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}"

# Parsed BEFORE bootstrap.sh is sourced: sourcing honours DRY_RUN (it mkdirs the
# config dir otherwise), so --dry-run has to be in the environment by then.
FORCE=0
targets=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1; export DRY_RUN ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)        printf 'orca-profile-sync: unknown flag %s\n' "$arg" >&2; exit 2 ;;
    *)         targets+=("$arg") ;;
  esac
done

# Borrow bootstrap.sh's helpers (link / link_if_present / _resolve / _mkdir /
# the counters) rather than re-implementing them.
#
# CLAUDE_CONFIG_DIR is pinned to the primary for the source call: bootstrap
# derives its CLAUDE_DIR/BAK_ROOT globals from that variable at source time, and
# inside an Orca session it already points at an account dir — which would leave
# those globals aimed at whichever account happens to be running. Each
# sync_profile call overrides both with `local` anyway (bash's dynamic scoping
# makes the override visible to link()/backup_target()); pinning here just keeps
# the pre-override state deterministic.
#
# MACHINES_BOOTSTRAP_ALLOW_COPY: bootstrap refuses to run from a temp copy or a
# linked worktree because every link IT creates points into SRC_DIR and would
# die with that copy. This script creates no such link — every target is under
# PRIMARY_DIR — so the guard is a false positive here.
if [ ! -f "$BOOT" ]; then
  printf 'orca-profile-sync: cannot find %s\n' "$BOOT" >&2
  exit 1
fi
# shellcheck source=./bootstrap.sh
MACHINES_BOOTSTRAP_ALLOW_COPY=1 BOOTSTRAP_LIB_ONLY=1 \
  CLAUDE_CONFIG_DIR="$PRIMARY_DIR" . "$BOOT"

pruned=0
synced=0

# ── Whole files and per-entry dirs mirrored from the primary ────────────────
# Whole-file links. statusline-command.sh / balance-refresh.py are here for
# parity with the secondary-profile fan-out even though settings.json spells the
# statusline out as "$HOME/.claude/statusline-command.sh" (an absolute primary
# path that resolves from any profile) — a profile-relative statusline config
# would otherwise break silently.
PROFILE_FILES="CLAUDE.md host-memory.md statusline-command.sh balance-refresh.py"
# Per-ENTRY dirs: link each entry individually so machine-local additions made
# inside the Orca profile (a hand-written skill, `gortex install` output run
# against that profile) coexist with the mirrored ones.
PROFILE_DIRS="skills agents commands memory"

# Top-level entries in the primary that are deliberately NOT mirrored: live
# session/account state, caches, plugin data. Purely a REPORTING list — nothing
# reads it to decide behaviour, so a wrong entry costs at most a missing or
# spurious warning, never a wrong link.
KNOWN_STATE="backups cache daemon daemon.log downloads file-history gortex-cache
history.jsonl jobs mcp-needs-auth-cache.json paste-cache plugins policy-limits.json
pr-cache projects pure-dev remote-settings.json session-env sessions
settings.json.bak settings.local.json shell-snapshots tasks telemetry tmp
window-reset.json"

# report_drift: name every top-level path in the primary that is neither mirrored
# nor known state.
#
# PROFILE_FILES / PROFILE_DIRS are ALLOWLISTS on purpose: a denylist would sooner
# or later mirror a state file and cross-wire two accounts' history or sessions.
# The price of an allowlist is that a NEW top-level path — Claude Code starting
# to write an `output-styles/`, a `keybindings.json` — is missed in SILENCE, and
# you find out weeks later when the feature is quietly absent from every Orca
# profile. This converts that silence into one line of output per unknown path.
#
# Dot-entries are skipped wholesale: every one of them in this profile is state
# (.credentials.json, .claude.json, .bootstrap-bak, the .srchash stamps).
report_drift() {
  local entry base known unknown=0
  [ -d "$PRIMARY_DIR" ] || return 0
  # Collapse to a single space-delimited line first: KNOWN_STATE is wrapped
  # across several source lines, and an embedded newline would break the
  # *" $base "* match for every entry sitting at a line boundary.
  known=" $(printf '%s %s %s %s' "$PROFILE_FILES" "$PROFILE_DIRS" settings.json \
            "$KNOWN_STATE" | tr -s '[:space:]' ' ') "
  for entry in "$PRIMARY_DIR"/*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    case "$known" in
      *" $base "*) continue ;;
    esac
    [ "$unknown" -eq 0 ] && printf '\n'
    printf '  ! not mirrored and not known state: %s/%s\n' "$PRIMARY_DIR" "$base"
    unknown=$((unknown + 1))
  done
  [ "$unknown" -gt 0 ] && printf '    Add it to PROFILE_FILES / PROFILE_DIRS to mirror it, or to KNOWN_STATE\n    to silence this. (%s path(s) — the primary layout has drifted.)\n' "$unknown"
  return 0
}

# looks_like_orca_dir <dir>: Orca's own account marker, the pairing marker
# orca-profile-link.sh writes, or the canonical claude-accounts path. Keeps a
# --force-less run from mirroring the profile into an arbitrary directory typo'd
# on the command line.
#
# The pairing marker is what lets a MIGRATED profile still identify as one: after
# orca-profile-link.sh moves it to ~/.claude-profiles/<name>, the path no longer
# matches the canonical pattern. Orca's own marker moves with the content and
# would carry it too, but a re-auth can rewrite that file, so we do not lean on it.
looks_like_orca_dir() {
  [ -f "$1/.orca-managed-claude-auth" ] && return 0
  [ -f "$1/.orca-account" ] && return 0
  case "$1" in
    */orca/claude-accounts/*/auth | */orca/claude-accounts/*/auth/) return 0 ;;
  esac
  return 1
}

# drop_dangling <dest>: remove dest IF it is a symlink into PRIMARY_DIR whose
# target no longer exists — a skill or facet deleted from the primary since the
# last sync. Never removes a real file (machine-local content of the Orca
# profile) and never removes a link pointing somewhere else.
drop_dangling() {
  local dest="$1" tgt
  [ -L "$dest" ] || return 0
  [ -e "$dest" ] && return 0                     # resolves fine — keep it
  tgt="$(readlink "$dest")"
  case "$tgt" in "$PRIMARY_DIR"/*) ;; *) return 0 ;; esac
  if [ -n "${DRY_RUN:-}" ]; then
    printf '  ~ would drop dangling link: %s\n' "$dest"
    pruned=$((pruned + 1))
    return 0
  fi
  rm -f "$dest" && printf '  - dropped dangling link: %s\n' "$dest"
  pruned=$((pruned + 1))
}

# prune_dangling_in <dir>: drop_dangling across every entry of dir.
prune_dangling_in() {
  local dir="$1" entry
  [ -d "$dir" ] || return 0
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [ -L "$entry" ] || continue                  # -e is false for a dangling link
    drop_dangling "$entry"
  done
}

# keep_local <dest>: true when dest is a REAL file or dir (not a symlink of
# ours) — content the Orca profile itself owns, which the mirror must never
# overwrite. bootstrap's link() would back it up and link over it; here that is
# the wrong call, because the destination copy is routinely the AUTHORITATIVE
# one.
#
# The case that forced this: `gortex install`-generated commands/, agents/ and
# gortex-* skills are regenerated PER PROFILE. The Orca profile's set is written
# by whichever gortex is current, while ~/.claude's may be months older — on
# this box the Orca profile already held the new consolidated-tool commands
# (explore / search / relations) and the primary still had the previous
# generation. Linking would have silently downgraded them, then gortex would
# rewrite them, then the next sync would link again: pure churn, with a
# .bootstrap-bak tree growing on every round trip.
#
# So the mirror only fills gaps. A fresh Orca profile still gets the primary's
# copy of everything (nothing is there to keep), and any generator that later
# writes its own version wins permanently.
keep_local() {
  [ -e "$1" ] || return 1
  [ -L "$1" ] && return 1
  return 0
}

# mirror_entries <primary-sub> <dest-sub>: link each entry of the primary subdir
# into the destination subdir. link_if_present (not link) because a dangling
# entry in the primary — e.g. skills/cyphy while ~/machines is being re-cloned —
# must not be propagated as a second dangling link.
mirror_entries() {
  local src_sub="$1" dest_sub="$2" entry dest
  [ -d "$src_sub" ] || return 0
  _mkdir "$dest_sub"
  for entry in "$src_sub"/* "$src_sub"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue   # unmatched glob
    dest="$dest_sub/$(basename "$entry")"
    if keep_local "$dest"; then
      printf '  = kept (machine-local, not overwritten): %s\n' "$dest"
      skipped=$((skipped + 1))
      continue
    fi
    link_if_present "$entry" "$dest"
  done
}

# merge_settings <primary-settings> <dest-settings>: settings.json is the one
# path that is NOT a symlink. Both Claude (/config, /plugin) and Orca (its
# agent-hooks block, injected at launch) write through the live file; a symlink
# would push those writes into the primary profile — and, since the primary's
# own settings.json is a copy_managed seed of the tracked baseline, on into a
# dirty working tree that jams convergence.
#
# Merge direction is "primary wins, destination keeps its extras":
# `dest * primary` recursively overlays the primary, so baseline changes always
# propagate, while a key only the Orca profile has survives. The two exceptions
# are the permissions arrays, unioned instead of replaced — those accumulate
# from the user clicking "always allow" inside a session, and are worth keeping
# on both sides. Orca's hook block is safe to overwrite: it re-injects on every
# launch, and the primary's settings.json already carries an equivalent block.
merge_settings() {
  local src="$1" dst="$2" tmp orig
  [ -f "$src" ] || { printf '  ! no primary settings.json — skipping\n'; return 0; }
  if [ ! -f "$dst" ]; then
    if [ -n "${DRY_RUN:-}" ]; then
      printf '  ~ would seed settings.json: %s\n' "$dst"
      would_link=$((would_link + 1))
      return 0
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst" && printf '  + seeded settings.json: %s\n' "$dst"
    linked=$((linked + 1))
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '  ! jq not found — leaving %s alone (install jq and re-run)\n' "$dst"
    return 0
  fi
  tmp="$(mktemp "$dst.XXXXXX")" || return 0
  if ! jq -s '
        .[0] as $base | .[1] as $tgt
        | ($tgt * $base)
        | .permissions = (
            (.permissions // {})
            | .allow = (((($base.permissions // {}).allow // []) + ((($tgt.permissions // {}).allow) // [])) | unique)
            | .deny  = (((($base.permissions // {}).deny  // []) + ((($tgt.permissions // {}).deny)  // [])) | unique)
            | .ask   = (((($base.permissions // {}).ask   // []) + ((($tgt.permissions // {}).ask)   // [])) | unique)
            | with_entries(select((.value | type) != "array" or (.value | length) > 0))
          )
      ' "$src" "$dst" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    printf '  ✗ could not merge settings.json into %s\n' "$dst"
    failed=$((failed + 1))
    return 0
  fi
  if [ "$(jq -S -c . "$tmp" 2>/dev/null)" = "$(jq -S -c . "$dst" 2>/dev/null)" ]; then
    rm -f "$tmp"
    printf '  = settings.json already in sync\n'
    skipped=$((skipped + 1))
    return 0
  fi
  if [ -n "${DRY_RUN:-}" ]; then
    rm -f "$tmp"
    printf '  ~ would merge settings.json into %s\n' "$dst"
    would_link=$((would_link + 1))
    return 0
  fi
  # One-time snapshot of what Orca created, kept next to the file (the sibling
  # convention copy_managed uses for its .srchash stamp). Never overwritten, so
  # the pristine Orca default stays recoverable after any number of syncs.
  orig="$(dirname "$dst")/.$(basename "$dst").pre-orca-sync"
  [ -e "$orig" ] || cp "$dst" "$orig" 2>/dev/null || true
  chmod 644 "$tmp" 2>/dev/null || true
  mv "$tmp" "$dst" && printf '  + merged settings.json -> %s\n' "$dst"
  linked=$((linked + 1))
}

# sync_profile <auth-dir>: the whole job for one Orca account dir.
#
# CLAUDE_DIR and BAK_ROOT are `local` overrides of bootstrap.sh's globals. Bash
# is dynamically scoped, so link()/backup_target() called from here see the Orca
# dir — backups land in that profile's .bootstrap-bak, not the primary's.
sync_profile() {
  local dir="$1" f sub link_note=""

  if [ ! -d "$dir" ]; then
    printf '  ✗ not a directory: %s\n' "$dir"
    failed=$((failed + 1))
    return 0
  fi
  # Follow the link to the real profile. After orca-profile-link.sh migrates an
  # account, the account dir is a symlink into ~/.claude-profiles/<name>; writing
  # through it would work, but backups (.bootstrap-bak) and the settings stamp
  # must land at the real path, and the output should name where things actually
  # went. Harmless when the dir is not a link — _resolve is then a no-op.
  if [ -L "$dir" ]; then
    link_note="$dir"
    dir="$(_resolve "$dir")"
    [ -d "$dir" ] || { printf '  ✗ broken account link: %s -> %s (run orca-profile-link.sh --relink)\n' "$link_note" "$dir"; failed=$((failed + 1)); return 0; }
  fi

  local CLAUDE_DIR="$dir"
  local BAK_ROOT="$dir/.bootstrap-bak"
  if [ "$(_resolve "$dir")" = "$(_resolve "$PRIMARY_DIR")" ]; then
    printf '  ✗ refusing to sync the primary profile onto itself: %s\n' "$dir"
    failed=$((failed + 1))
    return 0
  fi
  if [ "$FORCE" -eq 0 ] && ! looks_like_orca_dir "$dir"; then
    printf '  ✗ not an Orca-managed auth dir (no .orca-managed-claude-auth): %s\n' "$dir"
    printf '    pass --force if you really mean this path.\n'
    failed=$((failed + 1))
    return 0
  fi

  if [ -n "$link_note" ]; then
    printf '\nProfile %s\n         (via %s)\n' "$dir" "$link_note"
  else
    printf '\nProfile %s\n' "$dir"
  fi
  for f in $PROFILE_FILES; do
    drop_dangling "$dir/$f"
    if keep_local "$dir/$f"; then
      printf '  = kept (machine-local, not overwritten): %s\n' "$dir/$f"
      skipped=$((skipped + 1))
      continue
    fi
    link_if_present "$PRIMARY_DIR/$f" "$dir/$f"
  done
  for sub in $PROFILE_DIRS; do
    prune_dangling_in "$dir/$sub"
    mirror_entries "$PRIMARY_DIR/$sub" "$dir/$sub"
  done
  merge_settings "$PRIMARY_DIR/settings.json" "$dir/settings.json"
  synced=$((synced + 1))
}

# ── Resolve the target list ─────────────────────────────────────────────────
if [ "${#targets[@]}" -eq 0 ]; then
  for d in "$ACCOUNTS_DIR"/*/auth; do
    [ -d "$d" ] || continue
    targets+=("$d")
  done
  # Migrated profiles (orca-profile-link.sh) whose account link is broken or not
  # yet re-created still deserve the curated set — the whole point of moving them
  # into $HOME is that they stand on their own. Found by their pairing marker,
  # deduped against the glob above, which reaches the same dir via a healthy link.
  for p in "$PROFILES_DIR"/*; do
    [ -f "$p/.orca-account" ] || continue
    dup=0
    for t in ${targets[@]+"${targets[@]}"}; do
      [ "$(_resolve "$t")" = "$(_resolve "$p")" ] && { dup=1; break; }
    done
    [ "$dup" -eq 0 ] && targets+=("$p")
  done
  if [ "${#targets[@]}" -eq 0 ]; then
    # Silent-ish no-op: bootstrap.sh calls this unconditionally on machines that
    # have never signed into an Orca-managed account.
    printf 'No Orca-managed Claude profiles under %s or %s — nothing to sync.\n' "$ACCOUNTS_DIR" "$PROFILES_DIR"
    exit 0
  fi
fi

printf 'Syncing base Claude profile into Orca-managed profiles\n  primary: %s\n' "$PRIMARY_DIR"
[ -n "${DRY_RUN:-}" ] && printf '  (dry run — nothing will be written)\n'
report_drift

for d in "${targets[@]}"; do
  sync_profile "${d%/}"
done

if [ -n "${DRY_RUN:-}" ]; then
  printf '\n(dry-run) profiles=%d  would-link=%d  would-back-up=%d  would-prune=%d  already-linked=%d\n' \
    "$synced" "$would_link" "$would_backup" "$pruned" "$skipped"
else
  printf '\nDone. profiles=%d  linked=%d  skipped=%d  pruned=%d  backed-up=%d  failed=%d\n' \
    "$synced" "$linked" "$skipped" "$pruned" "$backed" "$failed"
  [ "$synced" -gt 0 ] && cat <<'EOF'
Auth, session and plugin state were left untouched. Restart the Orca session to
pick this up; declared marketplaces install themselves on that first launch.
EOF
fi

[ "$failed" -gt 0 ] && exit 1
exit 0
