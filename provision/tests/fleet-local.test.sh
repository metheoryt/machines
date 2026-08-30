#!/usr/bin/env bash
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../fleet-local.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/machines"

# fresh write
bash "$SCRIPT" --nickname desktop-ubuntu26 --platform linux --repo "$tmp/machines"
f="$tmp/machines/fleet.local.json"
[ -f "$f" ] && pass "marker written" || die "no marker file"
[ "$(jq -r '.self.nickname' "$f")" = desktop-ubuntu26 ] && pass "nickname" || die "nickname wrong: $(cat "$f")"
[ "$(jq -r '.self.fleet' "$f")" = true ] && pass "fleet:true" || die "fleet not true"
[ "$(jq -r '.self.platform' "$f")" = linux ] && pass "platform" || die "platform wrong"

# idempotent + preserves other keys
jq '. + {"other":{"k":1}}' "$f" > "$f.new" && mv "$f.new" "$f"
bash "$SCRIPT" --nickname desktop-ubuntu26 --repo "$tmp/machines"
[ "$(jq -r '.other.k' "$f")" = 1 ] && pass "preserves other keys" || die "clobbered other keys: $(cat "$f")"
[ "$(jq -r '.self.nickname' "$f")" = desktop-ubuntu26 ] && pass "re-write nickname stable" || die "nickname changed"

# ── .self.dispatch (spec 2026-08-01) ──────────────────────────────────────────
tmp2="$(mktemp -d)"; mkdir -p "$tmp2/machines"

# Default is direct — every existing fleet.local.json predates this field, and
# the personal distro's current direct-SSH behavior must not change.
bash "$SCRIPT" --nickname desktop-wsl --repo "$tmp2/machines" >/dev/null
got="$(jq -r '.self.dispatch' "$tmp2/machines/fleet.local.json")"
[ "$got" = direct ] && pass "dispatch defaults to direct" \
  || die "dispatch default: expected 'direct', got '$got'"

# Explicit parent routing for a distro with no tailnet node.
bash "$SCRIPT" --nickname desktop-pure --dispatch parent --repo "$tmp2/machines" >/dev/null
got="$(jq -r '.self.dispatch' "$tmp2/machines/fleet.local.json")"
[ "$got" = parent ] && pass "dispatch parent written" \
  || die "dispatch parent: expected 'parent', got '$got'"

# Nickname and fleet flag must survive the new field.
got="$(jq -r '.self.nickname' "$tmp2/machines/fleet.local.json")"
[ "$got" = desktop-pure ] && pass "nickname preserved alongside dispatch" \
  || die "nickname: expected 'desktop-pure', got '$got'"
got="$(jq -r '.self.fleet' "$tmp2/machines/fleet.local.json")"
[ "$got" = true ] && pass "fleet flag preserved alongside dispatch" \
  || die "fleet: expected 'true', got '$got'"

# Garbage is rejected rather than written — a typo'd mode would silently make
# the distro unreachable.
if bash "$SCRIPT" --nickname x --dispatch sideways --repo "$tmp2/machines" >/dev/null 2>&1; then
  die "invalid --dispatch must be rejected"
else
  pass "invalid --dispatch rejected"
fi
rm -rf "$tmp2"

# ── .self.parent (2026-08-30) ────────────────────────────────────────────────
# Names the Windows member this distro runs on, so fleet-dispatch reaches that
# one member through WSL interop rather than over a tailnet node it cannot
# hairpin to. Optional: absent means "no parent", the pre-2026-08-30 behavior.
tmp3="$(mktemp -d)"; mkdir -p "$tmp3/machines"
g="$tmp3/machines/fleet.local.json"

bash "$SCRIPT" --nickname desktop-wsl --repo "$tmp3/machines" >/dev/null
[ "$(jq -r '.self | has("parent")' "$g")" = false ] && pass "no --parent → key absent" \
  || die "parent key should be absent: $(cat "$g")"

bash "$SCRIPT" --nickname desktop-wsl --parent desktop --repo "$tmp3/machines" >/dev/null
[ "$(jq -r '.self.parent' "$g")" = desktop ] && pass "--parent written" \
  || die "parent: expected 'desktop', got '$(jq -r '.self.parent' "$g")'"

# A later run without the flag must not silently drop it — provision-wsl.sh
# omits --parent whenever the caller does, and losing it re-breaks dispatch.
bash "$SCRIPT" --nickname desktop-wsl --repo "$tmp3/machines" >/dev/null
[ "$(jq -r '.self.parent' "$g")" = desktop ] && pass "--parent survives a re-run without the flag" \
  || die "parent lost on re-write: $(cat "$g")"

# But an explicit new value replaces it.
bash "$SCRIPT" --nickname desktop-wsl --parent g15 --repo "$tmp3/machines" >/dev/null
[ "$(jq -r '.self.parent' "$g")" = g15 ] && pass "--parent overwrites the old value" \
  || die "parent not overwritten: $(cat "$g")"
rm -rf "$tmp3"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
