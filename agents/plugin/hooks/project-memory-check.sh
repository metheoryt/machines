#!/usr/bin/env bash
# Claude Code SessionStart hook — load (or offer to start tracking) repo-local
# memory.
#
# Fires at the start of every session, only when cwd is inside a git repo. Two
# mutually-exclusive behaviors:
#   1. <repo>/.claude/memory/project.md EXISTS → inject its contents as session
#      context. This is the LOADER: it's what makes per-repo memory merge with
#      the global + per-host memory that the sibling global-memory-load.sh hook
#      injects, with zero per-repo wiring (nothing needed in the repo's own
#      CLAUDE.md).
#   2. It does NOT exist → ask Claude ONCE to OFFER the user to start tracking
#      repo-local memory (create the file, git-add it). The hook itself never
#      creates anything — it only adds guidance to the session.
#
# Per-repo opt-out: an empty .claude/memory/.skip file silences the case-2 nudge
# permanently for that repo. Stays completely silent outside a git repo.
set -u

# Claude passes the session JSON on stdin; pull cwd from it, fall back to $PWD.
cwd="$(jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"

# Only relevant inside a git repo.
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$root" ] || exit 0

mem="$root/.claude/memory/project.md"

# --- Case 1: repo-local memory exists → load it into the session --------------
if [ -f "$mem" ]; then
  printf '%s\n\n' "Repo-local Claude memory for this project ($mem) — git-tracked in the repo and merged here with the user's global + per-host memory. Treat it like the rest of your loaded memory:"
  cat "$mem"
  exit 0
fi

# --- Case 2: not tracked yet → offer to start ---------------------------------
[ -e "$root/.claude/memory/.skip" ] && exit 0

cat <<EOF
This repository ($root) has no repo-local Claude memory yet
(.claude/memory/project.md). Repo-local memory is git-tracked inside the repo and
auto-loaded at session start (merged with the user's global + per-host memory), so
durable project-specific facts — conventions, gotchas, decisions, constraints —
survive across sessions and machines. Ask the user ONCE, early, whether they'd
like to start tracking it for this repo. If they say yes:
  - create .claude/memory/project.md with a short topical starter (one bullet per
    fact under '##' headings; no secrets);
  - confirm it isn't gitignored, then 'git add' it so it's version-controlled;
  - record per-project memories there from now on (instead of the harness's
    default per-project memory dir).
Do NOT create the file without their explicit confirmation. If they decline, drop
the topic for this session — they can create an empty .claude/memory/.skip file
in the repo to silence this nudge permanently for this repo.
EOF
