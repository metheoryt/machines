#!/usr/bin/env bash
# Behavioral tests for agents/bootstrap.sh, driven by DRY_RUN (mutates nothing).
# DRY_RUN reads the live dirs but writes NOTHING (no mkdir/ln/mv/rm).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"        # agents/
boot="$repo/bootstrap.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# Case 1: per-host memory is dotfiles-owned. bootstrap neither seeds
# agents/hosts/<id>.md nor links anything at ~/.claude/host-memory.md; it only
# retires a stale link there. MACHINES_HOST_ID is no longer consulted.
#
# Both assertions are NEGATIVE, and that is the whole contract for the primary
# profile: bootstrap must produce no output for this path. The positive half —
# that a stale link actually gets retired — is Case 4(a), which tests retire_link
# directly rather than through a bootstrap run whose output depends on whatever
# happens to be at the live path.
# Drive the PRIMARY profile, because that is whose contract this is. A fake
# profile dir would be a secondary profile, where a fan-out link at
# host-memory.md is CORRECT — asserting its absence there tests the opposite of
# the intent. The destination is printed first ("would link: DEST -> SRC"), so
# anchoring on the primary dest also tolerates the legitimate ~/.codex link.
out1="$(MACHINES_HOST_ID=testhost DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" bash "$boot" 2>&1)"
check "no per-host file is seeded in the repo" \
  '! printf "%s" "$out1" | grep -q "hosts/testhost.md"'
check "nothing is linked at the primary profile's host-memory.md" \
  '! printf "%s" "$out1" | grep -qE "would (link|back up \+ link): '"$HOME"'/\.claude/host-memory\.md"'

# Case 2: the plugin hooks tests/ dir is never linked. The Codex block that links
# plugin/hooks entry-by-entry runs ONLY on the personal profile (IS_PERSONAL=1),
# so drive $HOME/.claude with a THROWAWAY Codex dir (DRY_RUN writes nothing to it).
out2="$(DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" bash "$boot" 2>&1)"
check "tests dir excluded from hook linking" \
  '! printf "%s" "$out2" | grep -q "hooks/tests"'

# Case 3: copy_managed — the churn-free real-copy handler for settings.json /
# codex hooks.json. Source bootstrap in lib-only mode (defines helpers, runs no
# bootstrap) with CLAUDE_CONFIG_DIR pointed at a throwaway dir so the source-time
# mkdir lands there, not real ~/.claude.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
BOOTSTRAP_LIB_ONLY=1 CLAUDE_CONFIG_DIR="$tmp/claude" . "$boot" >/dev/null 2>&1

src="$tmp/base.json"; dest="$tmp/live.json"
printf 'BASE-V1\n' > "$src"

# (a) first seed: dest is a REAL file with src's content — never a symlink.
copy_managed "$src" "$dest" >/dev/null
check "copy_managed seeds a real file, not a symlink" '[ -f "$dest" ] && [ ! -L "$dest" ]'
check "copy_managed seeds baseline content"           '[ "$(cat "$dest")" = "BASE-V1" ]'

# (b) baseline UNCHANGED → local injection (Orca's block) is preserved (stamp hit).
printf 'BASE-V1\nORCA-INJECTED\n' > "$dest"
copy_managed "$src" "$dest" >/dev/null
check "copy_managed keeps local edits when baseline unchanged" 'grep -q ORCA-INJECTED "$dest"'

# (c) baseline CHANGES → re-seed, clobbering the stale local copy (Orca re-injects on launch).
printf 'BASE-V2\n' > "$src"
copy_managed "$src" "$dest" >/dev/null
check "copy_managed re-seeds when baseline changed" '[ "$(cat "$dest")" = "BASE-V2" ]'

# (d) migration: an existing SYMLINK at dest (the pre-fix state) becomes a real copy.
other="$tmp/other.json"; printf 'OTHER\n' > "$other"
lnk="$tmp/waslink.json"; ln -s "$other" "$lnk"
copy_managed "$src" "$lnk" >/dev/null
check "copy_managed migrates a symlink to a real copy"  '[ -f "$lnk" ] && [ ! -L "$lnk" ]'
check "copy_managed migration writes baseline content"  '[ "$(cat "$lnk")" = "BASE-V2" ]'

# Case 4: retire_link — drops a symlink INTO the repo, never anything else.
# Reuses the lib-only sourcing from Case 3 ($tmp and helpers are already live).
SRC_DIR="$tmp/src"; mkdir -p "$SRC_DIR"
printf 'REPO-CONTENT\n' > "$SRC_DIR/thing.md"

# (a) a symlink into $SRC_DIR is removed.
r_link="$tmp/retire-me.md"; ln -s "$SRC_DIR/thing.md" "$r_link"
retire_link "$r_link" >/dev/null
check "retire_link removes a symlink into the repo" '[ ! -e "$r_link" ] && [ ! -L "$r_link" ]'

# (b) a REAL file is never touched — this is the memory-loss guard.
r_real="$tmp/keep-me.md"; printf 'DOTFILES-OWNED\n' > "$r_real"
retire_link "$r_real" >/dev/null
check "retire_link leaves a real file alone"    '[ -f "$r_real" ]'
check "retire_link preserves real file content" '[ "$(cat "$r_real")" = "DOTFILES-OWNED" ]'

# (c) a symlink pointing OUTSIDE the repo is not ours — leave it.
r_other="$tmp/other-target.md"; printf 'SOMEONE-ELSE\n' > "$r_other"
r_foreign="$tmp/foreign-link.md"; ln -s "$r_other" "$r_foreign"
retire_link "$r_foreign" >/dev/null
check "retire_link leaves a foreign symlink alone" '[ -L "$r_foreign" ]'

# (d) missing path is a silent no-op, not an error. Capture the status in a
# variable: `$?` inside check's eval would read the eval's own predecessor, which
# makes the assertion tautological rather than a test of retire_link.
retire_link "$tmp/does-not-exist.md" >/dev/null; r_rc=$?
check "retire_link is a no-op on a missing path" '[ "$r_rc" -eq 0 ]'

# (e) DRY_RUN removes nothing.
r_dry="$tmp/dry-link.md"; ln -s "$SRC_DIR/thing.md" "$r_dry"
DRY_RUN=1 retire_link "$r_dry" >/dev/null
check "retire_link removes nothing under DRY_RUN" '[ -L "$r_dry" ]'

# (f) link_if_present — links when the source exists, no-ops when it does not.
# The no-op case is the guard against a dangling fan-out link on a box whose
# primary profile has not been converted yet.
p_dest="$tmp/present.md"
link_if_present "$SRC_DIR/thing.md" "$p_dest" >/dev/null
check "link_if_present links an existing source" '[ -L "$p_dest" ]'

a_dest="$tmp/absent.md"
link_if_present "$SRC_DIR/nope.md" "$a_dest" >/dev/null
check "link_if_present creates nothing for a missing source" '[ ! -e "$a_dest" ] && [ ! -L "$a_dest" ]'

# Case 5: the shared memory store is dotfiles-owned. bootstrap links nothing
# from agents/memory into the primary profile, and points Codex at the primary.
out5="$(DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" bash "$boot" 2>&1)"
check "nothing links agents/memory into the primary profile" \
  '! printf "%s" "$out5" | grep -qE "would (link|back up \+ link): '"$HOME"'/\.claude/memory/(global\.md|personality)"'
check "codex memory is sourced from the primary profile, not the repo" \
  '! printf "%s" "$out5" | grep -E "\.codex/memory" | grep -q "machines/agents/memory"'

# Case 6: agent instructions are dotfiles-owned; Codex reads the primary's copy.
out6="$(DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" bash "$boot" 2>&1)"
check "no link from agents/AGENTS.md into the primary profile" \
  '! printf "%s" "$out6" | grep -q "agents/AGENTS.md"'

# Case 7: statusline + balance refresh are dotfiles-owned.
out7="$(DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" bash "$boot" 2>&1)"
check "statusline is not linked from the repo" \
  '! printf "%s" "$out7" | grep -q "agents/statusline-command.sh"'
check "balance-refresh is not linked from the repo" \
  '! printf "%s" "$out7" | grep -q "agents/balance-refresh.py"'

# Case 8: refuse to bootstrap from a throwaway copy of the repo.
#
# Every link points straight at $SRC_DIR, so running this from a copy hands the
# live profile symlinks that die with the copy — and Claude Code then fails the
# statusline command SILENTLY while the dotfiles-owned memory files read as
# deleted. That happened on air 2026-07-28: an agent snapshotted agents/ into its
# scratchpad, ran bootstrap there, and five ~/.claude paths plus the
# memory/personality directory were left dangling.
wt_tmp="$(mktemp -d)"
cleanup_case8() {
  [ -d "$wt_tmp/wt" ] && git -C "$repo" worktree remove --force "$wt_tmp/wt" >/dev/null 2>&1
  git -C "$repo" worktree prune >/dev/null 2>&1
  rm -rf "$wt_tmp"
}
trap cleanup_case8 EXIT

# (a) a plain copy under a temp dir. `cp -R agents` carries no .git, so the
#     worktree probe finds nothing and the temp-path arm is what fires.
cp -R "$repo" "$wt_tmp/agents-copy"
out8a="$(DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" \
         bash "$wt_tmp/agents-copy/bootstrap.sh" 2>&1)"; rc8a=$?
check "a temp-dir copy is refused (non-zero exit)" '[ "$rc8a" -ne 0 ]'
check "the refusal names the temp-dir reason" \
  'printf "%s" "$out8a" | grep -q "under a temp directory"'
check "the refusal points at the canonical checkout" \
  'printf "%s" "$out8a" | grep -q "machines/agents/bootstrap.sh"'

# (b) a linked git worktree — the worktree-agent case. It also sits under a temp
#     root here, so this doubles as the guard that the worktree probe is checked
#     FIRST and wins the reason string.
if git -C "$repo" worktree add -q --detach "$wt_tmp/wt" HEAD >/dev/null 2>&1; then
  # The worktree checks out HEAD, so drop the WORKING-TREE script in — otherwise
  # this asserts against whatever was last committed and fails while iterating.
  # It stays a genuine linked worktree; only the script under test is refreshed.
  cp "$boot" "$wt_tmp/wt/agents/bootstrap.sh"
  out8b="$(DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" \
           bash "$wt_tmp/wt/agents/bootstrap.sh" 2>&1)"; rc8b=$?
  check "a linked worktree is refused (non-zero exit)" '[ "$rc8b" -ne 0 ]'
  check "the worktree reason wins over the temp-dir reason" \
    'printf "%s" "$out8b" | grep -q "linked git worktree"'
  # (c) the override still works — an escape hatch, not a locked door.
  MACHINES_BOOTSTRAP_ALLOW_COPY=1 DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" \
    CODEX_CONFIG_DIR="$(mktemp -d)" bash "$wt_tmp/wt/agents/bootstrap.sh" >/dev/null 2>&1
  rc8c=$?
  check "MACHINES_BOOTSTRAP_ALLOW_COPY overrides the refusal" '[ "$rc8c" -eq 0 ]'
else
  echo "skip - worktree cases (git worktree add failed)"
fi

# Case 9: gortex_merge_hooks — copies the hooks gortex writes into a profile's
# settings.local.json (where Claude Code never reads them) into its settings.json
# (where it does). Reuses the lib-only sourcing from Case 3.
#
# The contract is narrow on purpose: append-only, order-preserving, idempotent,
# and it must never disturb a key it did not add — Orca injects its own hook
# blocks into settings.json, and losing those is the failure this must not cause.
if command -v jq >/dev/null 2>&1; then
  g="$tmp/gx"; mkdir -p "$g"
  cat > "$g/settings.local.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"gortex hook"}]}],
          "PreCompact":[{"hooks":[{"type":"command","command":"gortex hook"}]}]}}
JSON
  cat > "$g/settings.json" <<'JSON'
{"model":"opus",
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"orca hook"}]}],
          "SessionStart":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}
JSON

  # (a) DRY_RUN plans the merge and writes nothing.
  before="$(cat "$g/settings.json")"
  out9a="$(DRY_RUN=1 gortex_merge_hooks "$g")"
  check "gortex_merge_hooks announces the merge under DRY_RUN" \
    'printf "%s" "$out9a" | grep -q "would merge gortex hooks"'
  check "gortex_merge_hooks writes nothing under DRY_RUN" \
    '[ "$(cat "$g/settings.json")" = "$before" ]'

  # (b) the real merge: gortex entries arrive, pre-existing ones stay put.
  gortex_merge_hooks "$g" >/dev/null
  check "gortex PreToolUse entry is merged in" \
    '[ "$(jq "[.hooks.PreToolUse[].hooks[].command] | index(\"gortex hook\")" "$g/settings.json")" != "null" ]'
  check "a hook event only gortex had is created" \
    '[ "$(jq -r ".hooks.PreCompact[0].hooks[0].command" "$g/settings.json")" = "gortex hook" ]'
  check "the pre-existing entry in that event survives" \
    '[ "$(jq -r ".hooks.PreToolUse[0].hooks[0].command" "$g/settings.json")" = "orca hook" ]'
  check "an event gortex never touched is untouched" \
    '[ "$(jq -r ".hooks.SessionStart[0].hooks[0].command" "$g/settings.json")" = "echo hi" ]'
  check "non-hook settings survive the merge" \
    '[ "$(jq -r .model "$g/settings.json")" = "opus" ]'

  # (c) idempotent — a second run is a no-op, and says so rather than rewriting.
  snap="$(jq -S -c . "$g/settings.json")"
  out9c="$(gortex_merge_hooks "$g")"
  check "second merge reports already-merged" \
    'printf "%s" "$out9c" | grep -q "already merged"'
  check "second merge changes nothing" '[ "$(jq -S -c . "$g/settings.json")" = "$snap" ]'

  # (d) a settings.local.json without gortex in it is not a merge source. This is
  # the guard against hoovering an unrelated local file into the managed one.
  h="$tmp/gx-nogortex"; mkdir -p "$h"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"something-else"}]}]}}\n' > "$h/settings.local.json"
  printf '{"model":"opus"}\n' > "$h/settings.json"
  gortex_merge_hooks "$h" >/dev/null
  check "a non-gortex settings.local.json is left alone" \
    '[ "$(jq -r ".hooks // \"none\"" "$h/settings.json")" = "none" ]'

  # (e) no settings.local.json at all → silent no-op, not an error.
  i="$tmp/gx-empty"; mkdir -p "$i"; printf '{}\n' > "$i/settings.json"
  out9e="$(gortex_merge_hooks "$i")"; rc9e=$?
  check "missing settings.local.json is a silent no-op" '[ -z "$out9e" ] && [ "$rc9e" -eq 0 ]'
else
  echo "skip - gortex_merge_hooks cases (jq not installed)"
fi

# Two assertions the cases above don't make. The first pins that a refusal is a
# refusal: an early `exit 1` that still emitted link output would mean the guard
# fired after doing damage. The second is the over-fire guard — if the probe ever
# misclassifies the canonical checkout, every box silently stops being bootstrapped.
check "a refused run links nothing" '! printf "%s" "$out8a" | grep -q "would link"'
out8d="$(DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" bash "$boot" 2>&1)"
check "the canonical checkout is NOT refused" \
  '! printf "%s" "$out8d" | grep -q "refusing to bootstrap from"'

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
