#!/usr/bin/env bash
# Behavior tests for worktree-setup.template.sh — the scaffold copied into a
# repo's .orca/. Asserts the non-fatal contract (always exit 0) and the opt-in
# gortex-readiness behavior, with `gortex` mocked on PATH.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$HERE/../worktree-setup.template.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

# The template must be a valid bash script that never uses `set -e` and ends at exit 0.
grep -q 'set -e' "$TEMPLATE" && die "template must not use set -e" || pass "no set -e"
grep -q 'exit 0' "$TEMPLATE" && pass "has exit 0" || die "template missing exit 0"
grep -q 'orca-setup:managed:repo-steps' "$TEMPLATE" && pass "repo-steps marker" || die "no repo-steps marker"
grep -q 'orca-setup:managed:gortex-readiness' "$TEMPLATE" && pass "gortex marker" || die "no gortex marker"

# Default (ORCA_GORTEX unset): runs clean, exit 0, no gortex invoked.
out="$(cd "$tmp" && bash "$TEMPLATE" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && pass "default exit 0" || die "default rc=$rc"

# gortex absent from PATH but ORCA_GORTEX=1: must still exit 0 (command -v guard).
out="$(cd "$tmp" && PATH="/usr/bin:/bin" ORCA_GORTEX=1 bash "$TEMPLATE" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && pass "gortex-absent exit 0" || die "gortex-absent rc=$rc"

# Mock gortex on PATH: daemon DOWN (status !=0) -> template starts it, exit 0.
mkbin="$tmp/bin"; mkdir -p "$mkbin"
cat > "$mkbin/gortex" <<'MOCK'
#!/usr/bin/env bash
# args: "daemon status" -> exit 1 (down); "daemon start --detach" -> exit 0
if [ "$1" = "daemon" ] && [ "$2" = "status" ]; then exit 1; fi
if [ "$1" = "daemon" ] && [ "$2" = "start" ]; then echo "started" ; exit 0; fi
exit 0
MOCK
chmod +x "$mkbin/gortex"
err="$(cd "$tmp" && PATH="$mkbin:$PATH" ORCA_GORTEX=1 bash "$TEMPLATE" 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && pass "gortex-down exit 0" || die "gortex-down rc=$rc"
printf '%s' "$err" | grep -q 'started gortex daemon' \
  && pass "gortex-down started daemon" || die "gortex-down did not start: $err"

# Mock gortex: daemon UP (status ==0) -> template does NOT start it, exit 0.
cat > "$mkbin/gortex" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "daemon" ] && [ "$2" = "status" ]; then exit 0; fi
if [ "$1" = "daemon" ] && [ "$2" = "start" ]; then echo "SHOULD-NOT-RUN"; exit 0; fi
exit 0
MOCK
chmod +x "$mkbin/gortex"
err="$(cd "$tmp" && PATH="$mkbin:$PATH" ORCA_GORTEX=1 bash "$TEMPLATE" 2>&1 >/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] && ! printf '%s' "$err" | grep -q 'SHOULD-NOT-RUN'; } \
  && pass "gortex-up no restart" || die "gortex-up misbehaved: rc=$rc err=$err"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
