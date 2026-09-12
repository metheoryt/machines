#!/usr/bin/env bash
# provision/tests/orca-skills-tier.test.sh — unit tests for tier_orca_skills in
# provision/lib/tiers.sh. No network, no Orca, no npx: the two store paths
# (ORCA_SKILLS_*_DIR) point at a tmpdir and every external command the tier can
# reach is a PATH shim that records its argv one argument per line.
#
# What this suite is really for: two mutations, and the SECOND is the worse one
# because it fails with a correctly-resolved CLI and exit 0.
#
#   1. Resolution returning bare `orca`. /usr/bin/orca is the GNOME screen
#      reader on every Ubuntu desktop install, so a provisioning run that types
#      it starts speech synthesis on the user's machine.
#   2. `--agent claude-code,universal` split back into two `--agent` flags. The
#      WRAPPER's --agent is last-wins (measured with --dry-run on g15), so the
#      split silently drops claude-code, installs ~/.agents/skills with no link
#      in ~/.claude/skills, and manufactures the exact drift this tier closes —
#      rc 0, no output, nothing to notice. Note the RAW npx form is the
#      opposite and takes the repeated flag; asserting one shape everywhere
#      would be wrong.
#
# Mutation-tested by editing a COPY under a tmpdir and pointing $TIERS at it,
# never by reverting the real file.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TIERS="${TIERS:-$REPO/provision/lib/tiers.sh}"
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || bad "$3: expected '$2', got '$1'"; }
has()  { printf '%s\n' "$1" | grep -qF -- "$2" && pass "$3" || bad "$3"; }
hasnt(){ printf '%s\n' "$1" | grep -qF -- "$2" && bad "$3" || pass "$3"; }

# ── the tier's own source text ────────────────────────────────────────────────
# Comments stripped: the prose deliberately NAMES the things the code must not
# do (bare `orca`, the screen reader, --all), so a grep over comments would fail
# on the file that documents itself best.
whole="$(awk '/^_orca_cli\(\)/,/^}/' "$TIERS")
$(awk '/^_orca_skill_present\(\)/,/^}/' "$TIERS")
$(awk '/^tier_orca_skills\(\)/,/^}/' "$TIERS")"
code="$(printf '%s\n' "$whole" | sed 's/[[:space:]]*#.*$//')"

hasnt "$code" '--all'    "tier_orca_skills never installs --all (the Linear/emulator bundle)"
has   "$code" 'orca-ide' "resolution names orca-ide"

# ── pure helpers ──────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
TIERS_LIB_ONLY=1 source "$TIERS"

# The desired set is exactly four names, from two sources, and carries none of
# the bundle `--all` would drag in.
eq "$ORCA_SKILLS_BUNDLED $ORCA_SKILLS_EXTRA" \
   "computer-use orca-cli orchestration find-skills" \
   "desired set is exactly the four skills this fleet uses"
for unwanted in orca-linear linear-tickets orca-emulator orca-per-workspace-env; do
  hasnt "$ORCA_SKILLS_BUNDLED $ORCA_SKILLS_EXTRA" "$unwanted" \
    "desired set excludes $unwanted"
done

# ── CLI resolution ────────────────────────────────────────────────────────────
SHIM="$(mktemp -d)"; LOG="$SHIM/calls"; : > "$LOG"
# One invocation per LINE, arguments joined by \037 — so an assertion can tell
# `--agent claude-code,universal` (one argument) from `--agent claude-code
# --agent universal` (two flags), which is the whole point of mutation 2.
mkshim() {
  cat > "$2/$1" <<SH
#!/bin/sh
# printf, not string concatenation: "\037" inside double quotes is four literal
# characters in POSIX sh, and a separator that is not one character cannot tell
# argument boundaries apart — which is the only thing this log is for.
printf '%s' "\$(basename "\$0")" >> "$LOG"
for a in "\$@"; do printf '\037%s' "\$a" >> "$LOG"; done
printf '\n' >> "$LOG"
exit \${SHIM_RC:-0}
SH
  chmod +x "$2/$1"
}
REAL_PATH="$PATH"
# Three progressively-populated directories, all built while the real PATH is
# still intact: resolution is then tested against one of them ALONE, because
# this box has a real orca-ide in ~/.local/bin and inheriting it would make
# every case below pass for the wrong reason.
mkdir -p "$SHIM/s1" "$SHIM/s2" "$SHIM/s3" "$SHIM/empty"
mkshim orca     "$SHIM/s1"
mkshim orca     "$SHIM/s2"; mkshim orca-cli "$SHIM/s2"
mkshim orca     "$SHIM/s3"; mkshim orca-cli "$SHIM/s3"; mkshim orca-ide "$SHIM/s3"
mkshim npx      "$SHIM/s3"

# A box with the screen reader and nothing else: resolution must find NOTHING
# rather than fall through to it. This is mutation 1.
PATH="$SHIM/s1"
out="$(_orca_cli)"; rc=$?
eq "$rc" "1" "only bare orca present: resolution fails"
eq "$out" ""  "only bare orca present: resolution prints nothing (never the screen reader)"

# orca-cli is accepted as a second candidate (a box where a different installer
# got there before Orca's own CliInstaller).
PATH="$SHIM/s2"
eq "$(_orca_cli)" "orca-cli" "orca-cli accepted when orca-ide is absent"

# orca-ide wins over both.
PATH="$SHIM/s3"
eq "$(_orca_cli)" "orca-ide" "orca-ide preferred over orca-cli and bare orca"
PATH="$SHIM/s3:$REAL_PATH"; export PATH

# ── the two-store presence probe ──────────────────────────────────────────────
ORCA_SKILLS_AGENTS_DIR="$SHIM/agents"
ORCA_SKILLS_CLAUDE_DIR="$SHIM/claude"
mkdir -p "$ORCA_SKILLS_AGENTS_DIR" "$ORCA_SKILLS_CLAUDE_DIR"

# Present on both, the way a real install writes it: a real directory in
# ~/.agents/skills and a RELATIVE symlink to it from ~/.claude/skills.
mkdir -p "$ORCA_SKILLS_AGENTS_DIR/orchestration"
: > "$ORCA_SKILLS_AGENTS_DIR/orchestration/SKILL.md"
ln -s "../agents/orchestration" "$ORCA_SKILLS_CLAUDE_DIR/orchestration"
_orca_skill_present orchestration && pass "present on both stores → present" \
  || bad "a real dir plus a relative link must count as present"

# air's live drift: the real directory exists, nothing links it, so the agent
# that reads skills in a session cannot see it. Must NOT count as present.
mkdir -p "$ORCA_SKILLS_AGENTS_DIR/find-skills"
: > "$ORCA_SKILLS_AGENTS_DIR/find-skills/SKILL.md"
_orca_skill_present find-skills && bad "~/.agents-only must NOT count as present (air's drift)" \
  || pass "~/.agents-only → absent (the drift class this tier closes)"

# A dangling link is absent too — probed THROUGH the link, not by readlink text.
ln -s "../agents/nope" "$ORCA_SKILLS_CLAUDE_DIR/computer-use"
_orca_skill_present computer-use && bad "a dangling link must not count as present" \
  || pass "dangling ~/.claude link → absent"

# ── live branch tests ─────────────────────────────────────────────────────────
info() { printf 'info %s\n' "$*"; }
ok()   { printf 'ok %s\n' "$*"; }
warn() { printf 'warn %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

reset() {
  : > "$LOG"
  rm -rf "$ORCA_SKILLS_AGENTS_DIR" "$ORCA_SKILLS_CLAUDE_DIR"
  mkdir -p "$ORCA_SKILLS_AGENTS_DIR" "$ORCA_SKILLS_CLAUDE_DIR"
  unset SHIM_RC
}
# one recorded invocation, by the command that made it
argv() { grep "^$1" "$LOG" || true; }
install_skill() {  # <name> — write both stores the way a real install does
  mkdir -p "$ORCA_SKILLS_AGENTS_DIR/$1"; : > "$ORCA_SKILLS_AGENTS_DIR/$1/SKILL.md"
  ln -sfn "../agents/$1" "$ORCA_SKILLS_CLAUDE_DIR/$1"
}

# Case A — darwin. air is hand-installed; the tier must not even resolve a CLI.
reset
_is_darwin() { return 0; }
out="$(tier_orca_skills 2>&1)"; rc=$?
eq "$rc" "0" "darwin: returns 0"
has "$out" "hand" "darwin: says air is hand-installed"
eq "$(wc -c < "$LOG")" "0" "darwin: runs NOTHING"
_is_darwin() { return 1; }

# Case B — no Orca CLI at all (latitude, hub). Expected state → info, not warn.
reset
# The shim directory ALONE, with no /usr/bin behind it. This is not tidiness:
# /usr/bin/orca is the real GNOME screen reader on this box, and a mutation that
# lets resolution fall through to bare `orca` then makes the SUITE start speech
# synthesis on the user's machine. It did, once, while mutation-testing this
# file on g15 (2026-09-12). A test for a hazard must not be able to trigger it.
# The tier needs no external command to reach either guard — `have` and
# resolution are both `command -v`, and info/ok/warn are the driver's functions.
PATH_SAVED="$PATH"; PATH="$SHIM/empty"
out="$(tier_orca_skills 2>&1)"; rc=$?
PATH="$PATH_SAVED"
eq "$rc" "0" "no Orca CLI: returns 0"
has "$out" "info" "no Orca CLI: info register, not warn (latitude and hub are fine)"
eq "$(wc -c < "$LOG")" "0" "no Orca CLI: runs NOTHING"

# Case C — CLI present, npx missing. This one wanted to and could not → warn.
reset
have() { [ "$1" != npx ] && command -v "$1" >/dev/null 2>&1; }
out="$(tier_orca_skills 2>&1)"; rc=$?
have() { command -v "$1" >/dev/null 2>&1; }
eq "$rc" "0" "no npx: returns 0"
has "$out" "warn" "no npx: warn register"
has "$out" "npx" "no npx: names what is missing"
eq "$(wc -c < "$LOG")" "0" "no npx: installs nothing"

# Case D — a bare box: all four missing. Two adds, no updates, and the wrapper
# call must carry the comma-joined --agent as ONE argument. This is mutation 2.
reset
out="$(tier_orca_skills 2>&1)"; rc=$?
eq "$rc" "0" "bare box: returns 0"
argv_all="$(cat "$LOG")"
has "$argv_all" "claude-code,universal" "bare box: wrapper gets ONE comma-joined --agent value"
# The split form is what last-wins silently eats. Scoped to the WRAPPER's own
# invocation: the raw npx line below legitimately carries the repeated flag.
argv "orca-ide" | tr '\037' '\n' | grep -qx 'claude-code' \
  && bad "bare box: --agent must not be split into repeated flags for the wrapper" \
  || pass "bare box: --agent is never split for the wrapper"
has "$argv_all" "computer-use" "bare box: installs computer-use (WSL included — it bridges to orca.exe)"
has "$argv_all" "orca-cli"      "bare box: installs orca-cli"
has "$argv_all" "orchestration" "bare box: installs orchestration"
has "$argv_all" "find-skills"   "bare box: installs find-skills"
has "$argv_all" "vercel-labs/skills" "bare box: find-skills comes from its own source"
has "$argv_all" "install" "bare box: install, not update"
# A bare-`orca` shim sits in the same directory as orca-ide for every live case.
# Nothing may ever invoke it — on a real box that argv is the screen reader.
argv orca$'\037' >/dev/null 2>&1
grep -q "^orca$(printf '\037')" "$LOG" \
  && bad "bare box: bare \`orca\` was invoked — that is the screen reader" \
  || pass "bare box: bare \`orca\` is never invoked"
hasnt "$argv_all" "update" "bare box: nothing to update"
# The RAW npx form is the opposite of the wrapper's: it takes the repeated flag,
# which is how all four skills came to be dual-store on g15.
npxargs="$(argv npx | tr '\037' ' ')"
has "$npxargs" "--agent claude-code --agent universal" \
  "bare box: raw npx add gets the REPEATED --agent form"

# Case E — everything present on both stores: updates only, no installs.
reset
for s in computer-use orca-cli orchestration find-skills; do install_skill "$s"; done
out="$(tier_orca_skills 2>&1)"; rc=$?
eq "$rc" "0" "all present: returns 0"
argv_all="$(cat "$LOG")"
has  "$argv_all" "update" "all present: updates"
hasnt "$argv_all" "install" "all present: installs nothing"

# Case F — the air shape: real dirs, no links. Must INSTALL, not update — the
# update path takes no --agent and so can never create the missing link.
reset
for s in computer-use orca-cli orchestration find-skills; do
  mkdir -p "$ORCA_SKILLS_AGENTS_DIR/$s"; : > "$ORCA_SKILLS_AGENTS_DIR/$s/SKILL.md"
done
out="$(tier_orca_skills 2>&1)"; rc=$?
argv_all="$(cat "$LOG")"
has  "$argv_all" "install" "half-installed: re-installs to create the missing ~/.claude links"
hasnt "$argv_all" "update" "half-installed: never update (it cannot create a link)"

# Case G — a failing installer. Best-effort: warn, keep going, still rc 0.
reset
export SHIM_RC=7
out="$(tier_orca_skills 2>&1)"; rc=$?
unset SHIM_RC
eq "$rc" "0" "install failure: tier still returns 0 (best-effort)"
has "$out" "warn" "install failure: warns"
has "$out" "retry" "install failure: prints the command to retry by hand"

rm -rf "$SHIM"
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
