#!/usr/bin/env bash
# Table-driven tests for the dotfiles-offer PostToolUse hook.
#
# The hook decides, for a file the agent just edited, whether to offer to track
# it in the dotfiles repo. Six branches (spec §5.3); the two that matter most
# are the ban block (must NEVER offer to track a private key) and the
# gitignored-inside-a-repo case (the homeless file the whole hook exists for).
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../dotfiles-offer.sh"

fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export DOTFILES_GIT_DIR="$T/home/.dotfiles"
export DOTFILES_OFFER_STATE_DIR="$T/offerstate"
mkdir -p "$HOME" "$DOTFILES_OFFER_STATE_DIR"

# A bare dotfiles repo tracking exactly one file, with the real allow-only
# .gitignore shape so check-ignore behaves like production.
git init -q --bare "$DOTFILES_GIT_DIR"
df() { git --git-dir="$DOTFILES_GIT_DIR" --work-tree="$HOME" "$@"; }
df config status.showUntrackedFiles no
df config user.email t@t; df config user.name t
df checkout -q -b air 2>/dev/null || df symbolic-ref HEAD refs/heads/air
printf '*\n!*/\n!.gitignore\n!.tracked\n*.pem\nid_ed25519*\n.ssh/id_*\n.gnupg/\n' > "$HOME/.gitignore"
printf 'x\n' > "$HOME/.tracked"
df add "$HOME/.gitignore" "$HOME/.tracked"
df commit -q -m init

# A sibling git repo with an allowlist .gitignore — the homeless case.
mkdir -p "$HOME/pure/backend-api/.claude/memory"
git init -q "$HOME/pure/backend-api"
# Allowlist shape: `!/.claude/*.md` matches DIRECT children of .claude only, so
# .claude/memory/project.md stays ignored — that is the homeless case.
printf '*\n!*/\n!/.claude/*.md\n!*.py\n' > "$HOME/pure/backend-api/.gitignore"
printf 'note\n' > "$HOME/pure/backend-api/.claude/memory/project.md"
printf 'code\n' > "$HOME/pure/backend-api/main.py"

# run <session> <path>: feed one PostToolUse payload, echo stdout.
run() {
  printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" "$2" \
    | bash "$HOOK" 2>/dev/null
}
offers()     { case "$(run "$1" "$2")" in *dotfiles*) return 0 ;; *) return 1 ;; esac; }
assert_offer()  { if offers "$1" "$2"; then pass "$3"; else die "$3 (expected an offer, got silence)"; fi; }
assert_silent() { if offers "$1" "$2"; then die "$3 (expected silence, got an offer)"; else pass "$3"; fi; }

# 1. Outside $HOME -> silent.
printf 'x\n' > "$T/elsewhere.conf"
assert_silent s1 "$T/elsewhere.conf" "outside \$HOME is silent"

# 2. Ban block -> silent, ALWAYS. This one is a security property, not a
#    preference: an offer to track a private key is an offer to leak it.
mkdir -p "$HOME/.ssh"
printf 'KEY\n' > "$HOME/.ssh/id_ed25519"
assert_silent s2 "$HOME/.ssh/id_ed25519" "banned path (.ssh/id_*) is silent"
printf 'CERT\n' > "$HOME/server.pem"
assert_silent s2 "$HOME/server.pem" "banned path (*.pem) is silent"

# 3. Already tracked -> silent.
assert_silent s3 "$HOME/.tracked" "already-tracked path is silent"

# 3b. Same file, but the hook runs from a cwd INSIDE the work-tree — the real
#     case, since a session's cwd is some checkout under $HOME. git resolves a
#     pathspec against the CWD, not the work-tree, so a $HOME-relative path
#     matches nothing from there and every tracked file reads as untracked.
_cwd="$PWD"
cd "$HOME/pure/backend-api" || exit 1
assert_silent s3b "$HOME/.tracked" "already-tracked path is silent from a cwd inside \$HOME"
cd "$_cwd" || exit 1

# 4a. Inside another repo and trackable there -> silent, it belongs there.
assert_silent s4 "$HOME/pure/backend-api/main.py" "normal file in a repo is silent"

# 4b. Inside another repo but gitignored there -> OFFER. The homeless case.
assert_offer s4 "$HOME/pure/backend-api/.claude/memory/project.md" \
  "gitignored-inside-a-repo file is offered"

# 5. Same path, same session -> silent the second time.
assert_silent s4 "$HOME/pure/backend-api/.claude/memory/project.md" \
  "second offer in the same session is suppressed"

# 5b. Same path, NEW session -> offered again (declines are session-scoped).
assert_offer s5 "$HOME/pure/backend-api/.claude/memory/project.md" \
  "a new session re-offers the same path"

# 5c. Build noise inside a repo is gitignored there too, but must NOT be offered
#     — otherwise the hook fires on every artifact the agent touches.
mkdir -p "$HOME/pure/backend-api/.venv/lib"
printf 'x\n' > "$HOME/pure/backend-api/.venv/lib/thing.py"
assert_silent s5b "$HOME/pure/backend-api/.venv/lib/thing.py" "build noise (.venv) is silent"
printf 'x\n' > "$HOME/pure/backend-api/debug.log"
assert_silent s5b "$HOME/pure/backend-api/debug.log" "build noise (*.log) is silent"

# 6. Plain untracked $HOME file, no repo -> OFFER.
printf 'cfg\n' > "$HOME/.someconfig"
assert_offer s6 "$HOME/.someconfig" "plain untracked \$HOME file is offered"

# 7. No dotfiles repo at all -> silent everywhere. A box not yet enrolled must
#    never be nagged about files it has nowhere to put.
mv "$DOTFILES_GIT_DIR" "$T/moved"
assert_silent s7 "$HOME/.someconfig" "no dotfiles repo means silence"
mv "$T/moved" "$DOTFILES_GIT_DIR"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
