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

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
