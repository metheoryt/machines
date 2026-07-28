#!/usr/bin/env bash
# agents/plugin/hooks/dotfiles-offer.sh — PostToolUse (Edit|Write|NotebookEdit).
# Spec: docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md §5.3
#
# When the agent edits a file under $HOME that has no home in any repo, surface a
# non-blocking offer to track it in the dotfiles bare repo. NEVER a permission
# prompt, and never a blocker — this hook always exits 0, even on its own errors.
#
# The interesting branch is step 4: a file inside a git repo whose .gitignore is
# allowlist-style (`*` plus a few `!` lines) is ignored THERE, so writing it
# there produces machine-local state that never syncs. dotfiles is its only home.
# A normal source file in the same repo belongs to that repo and stays silent.
#
# Declines are session-scoped (D10). A hook process cannot observe the user's
# answer — PostToolUse fires before any reply exists — so "declined this session"
# is implemented as "already offered this session": one offer per (session,path),
# recorded in a scratch file that nothing syncs and a reboot discards.
set -u

: "${DOTFILES_GIT_DIR:=$HOME/.dotfiles}"
: "${DOTFILES_OFFER_STATE_DIR:=${TMPDIR:-/tmp}/dotfiles-offer}"

payload="$(cat)" || exit 0

# Field extraction without jq: this hook runs on every edit, so it must be cheap
# and must not hard-depend on a tool some fleet member lacks.
jget() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null
    else
        printf '%s' "$payload" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
    fi
}
file="$(jget '.tool_input.file_path' 'file_path')"
session="$(jget '.session_id' 'session_id')"
[ -n "$file" ] || exit 0

# ── 1. Under $HOME? ──────────────────────────────────────────────────────────
case "$file" in
    "$HOME"/*) : ;;
    *) exit 0 ;;
esac
rel="${file#"$HOME"/}"

# No repo on this box: it is not enrolled, so there is nothing to offer.
[ -d "$DOTFILES_GIT_DIR" ] || exit 0
df() { git --git-dir="$DOTFILES_GIT_DIR" --work-tree="$HOME" "$@"; }

# ── 2. Ban block — silent, ALWAYS, before anything else. ─────────────────────
# Checked structurally rather than by asking git, because the whole point is
# that this must hold even if a future broad `!` rule un-ignores the path.
case "$rel" in
    .ssh/id_*|*.pem|*.key|*.gpg|id_rsa*|id_ed25519*|id_ecdsa*|.gnupg/*|.secrets/*)
        exit 0 ;;
esac
case "$(basename "$rel")" in
    id_rsa*|id_ed25519*|id_ecdsa*) exit 0 ;;
esac

# ── 3. Already tracked? ──────────────────────────────────────────────────────
df ls-files --error-unmatch "$rel" >/dev/null 2>&1 && exit 0

# ── 2b. Obvious non-config noise — silent. ───────────────────────────────────
# Step 4 below treats "gitignored inside a repo" as the homeless signal, which is
# spec-faithful but also matches every build artifact, virtualenv and cache the
# agent ever touches. Without this filter the hook fires constantly and the user
# turns it off, which costs more than the false negatives it prevents.
case "/$rel/" in
    */.venv/*|*/venv/*|*/node_modules/*|*/__pycache__/*|*/.pytest_cache/*|\
    */.mypy_cache/*|*/.ruff_cache/*|*/target/*|*/dist/*|*/build/*|*/.next/*|\
    */.direnv/*|*/.cache/*|*/coverage/*|*/.tox/*|*/site-packages/*)
        exit 0 ;;
esac
case "$rel" in
    *.pyc|*.pyo|*.o|*.so|*.class|*.log|*.lock|*.tmp|*.swp) exit 0 ;;
esac

# ── 4. Inside another git repo? ──────────────────────────────────────────────
# Walk up from the file's directory looking for a .git. If one is found, the
# question becomes: would THAT repo track this file? If yes, it belongs there —
# stay silent. If it is gitignored there, the file is homeless: offer.
dir="$(dirname "$file")"
owner=""
while [ "$dir" != "/" ] && [ "$dir" != "$HOME" ] && [ -n "$dir" ]; do
    if [ -e "$dir/.git" ]; then owner="$dir"; break; fi
    dir="$(dirname "$dir")"
done
if [ -n "$owner" ]; then
    if ! git -C "$owner" check-ignore -q "$file" 2>/dev/null; then
        exit 0      # trackable in its own repo — not our business
    fi
fi

# ── 5. Already offered this session? ─────────────────────────────────────────
mkdir -p "$DOTFILES_OFFER_STATE_DIR" 2>/dev/null || exit 0
# One flat file per session; the path is hashed so any filename is safe to key on.
if command -v shasum >/dev/null 2>&1; then
    key="$(printf '%s' "$rel" | shasum | cut -c1-16)"
elif command -v sha1sum >/dev/null 2>&1; then
    key="$(printf '%s' "$rel" | sha1sum | cut -c1-16)"
else
    key="$(printf '%s' "$rel" | tr -c 'a-zA-Z0-9' '_')"
fi
seen="$DOTFILES_OFFER_STATE_DIR/${session:-nosession}.$key"
[ -e "$seen" ] && exit 0
: > "$seen"

# ── 6. Offer. ────────────────────────────────────────────────────────────────
branch="$(df rev-parse --abbrev-ref HEAD 2>/dev/null || echo '<branch>')"
cat <<JSON
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"dotfiles: \`~/$rel\` is not tracked anywhere — it is outside every repo that would keep it, so it is machine-local state today. Offer the user (do not act unprompted) to track it in the dotfiles repo on branch \`$branch\`. Accepting is two steps:\n  1. append \`!$rel\` to ~/.gitignore under the explicit-allow block\n  2. git --git-dir=\$HOME/.dotfiles --work-tree=\$HOME add ~/.gitignore $rel\nIt lands on the machine branch; promoting it to main is a separate, manual /dotfiles-promote run. If the user declines, drop it — do not ask again this session."}}
JSON
exit 0
