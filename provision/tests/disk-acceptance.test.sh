#!/usr/bin/env bash
# provision/tests/disk-acceptance.test.sh — unit tests for the pure helpers and
# the write interlock in hosts/latitude/debian/disk-acceptance.sh. No root, no
# disks, no badblocks: the script is SOURCED and its helpers are called with
# state passed in.
#
# What this suite is really for: the surface phase runs `badblocks -w`, and one
# wrong device path destroys 686 GB of seeding library on a box where /dev/sdX
# reshuffles every boot. The interlock branches are therefore live cases here,
# not comments. The July 2026 fraud numbers (74 502 h, 3.02 PB) are a case too —
# a regression that lets those read as NEW is the exact failure the identity
# gate exists to catch.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/hosts/latitude/debian/disk-acceptance.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || bad "$3: expected '$2', got '$1'"; }
has()  { printf '%s\n' "$1" | grep -qF -- "$2" && pass "$3" || bad "$3: missing '$2'"; }
hasnt(){ printf '%s\n' "$1" | grep -qF -- "$2" && bad "$3: found '$2'" || pass "$3"; }
starts(){ case "$1" in "$2"*) pass "$3" ;; *) bad "$3: '$1' does not start with '$2'" ;; esac; }

[ -f "$SCRIPT" ] || { echo "FAIL script missing: $SCRIPT"; exit 1; }
# The trailing `main "$@"` guard makes a sourced load return 1 by design.
# shellcheck disable=SC1090
. "$SCRIPT" || true

# ── smart_num: raw values come in four shapes and only one is a bare integer ──
eq "$(smart_num 0)"                      0      "smart_num zero"
eq "$(smart_num 74502)"                  74502  "smart_num plain integer"
eq "$(smart_num '1234h+00m+00.000s')"    1234    "smart_num strips WD's hours suffix"
eq "$(smart_num '0/0')"                  0      "smart_num handles the x/y form"
eq "$(smart_num '')"                     0      "smart_num of empty is 0, never empty (it is compared with -gt)"

# ── smart_raw against a real -A layout ────────────────────────────────────────
cat > "$TMP/A" <<'ATTR'
SMART Attributes Data Structure revision number: 16
Vendor Specific SMART Attributes with Thresholds:
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  5 Reallocated_Sector_Ct   0x0033   200   200   140    Pre-fail  Always       -       0
  9 Power_On_Hours          0x0032   100   100   000    Old_age   Always       -       74502
 12 Power_Cycle_Count       0x0032   100   100   000    Old_age   Always       -       45
197 Current_Pending_Sector  0x0032   200   200   000    Old_age   Always       -       0
198 Offline_Uncorrectable   0x0030   100   253   000    Old_age   Offline      -       0
199 UDMA_CRC_Error_Count    0x0032   200   200   000    Old_age   Always       -       3
241 Total_LBAs_Written      0x0032   100   253   000    Old_age   Always       -       5904970852764
ATTR
eq "$(smart_attr "$TMP/A" 9)"   74502           "smart_attr reads Power_On_Hours"
eq "$(smart_attr "$TMP/A" 199)" 3               "smart_attr reads UDMA_CRC"
eq "$(smart_attr "$TMP/A" 241)" 5904970852764   "smart_attr reads Total_LBAs_Written"
eq "$(smart_attr "$TMP/A" 5)"   0               "smart_attr reads Reallocated_Sector_Ct"
# An attribute the drive does not report must read 0, not empty: every caller
# feeds the result straight into `[ -gt ]`.
eq "$(smart_attr "$TMP/A" 240)" 0               "smart_attr of an absent ID is 0"
eq "$(smart_attr /nonexistent 9)" 0             "smart_attr of an unreadable dump is 0"

# ── badblocks' 2^32-block ceiling: the whole reason for -b 4096 ───────────────
B8=8001563222016
bb_blocksize_ok "$B8" 1024 && bad "8 TB must NOT fit badblocks' default -b 1024" || pass "8 TB exceeds the 2^32 ceiling at the default -b 1024"
bb_blocksize_ok "$B8" 4096 && pass "8 TB fits at -b 4096" || bad "8 TB should fit at -b 4096"
eq "$(bb_blocks "$B8" 4096)" 1953506646 "bb_blocks at 4096"

# ── ETA carries the inner-track factor, or it under-promises ─────────────────
# 8 TB at 150 MB/s is 14.8 h one way; write+read is 29.6 h; x1.4 for the inner
# tracks is ~41 h. A bare 2x would promise ~30 h and be wrong by half a day.
starts "$(eta_hours "$B8" 150)" 41 "eta_hours applies write+read and the 1.4 inner-track factor"
eq "$(eta_hours "$B8" 0)" "?" "eta_hours refuses to divide by a zero rate"

# ── verdict_new: the July fraud must never read NEW ──────────────────────────
starts "$(verdict_new 74502 45 5904970852764 512)" USED    "the HUS726060ALE611 fraud numbers read USED"
starts "$(verdict_new 0 1 2000000)" NEW                     "a genuinely new drive reads NEW"
starts "$(verdict_new 11 1 0)" USED                         "11 power-on hours is past the factory-test allowance"
starts "$(verdict_new 2 51 0)" USED                         "51 power cycles is past the allowance"
# Low hours but terabytes written is the interesting fraud: a reseller can wipe
# and reset nothing here, but a drive pulled from a short-lived array shows it.
starts "$(verdict_new 3 2 4000000000 512)" USED             "2 TiB written outvotes a low hour count"
starts "$(verdict_new 0 0 0)" UNKNOWN                       "all-zero counters read UNKNOWN, never NEW — the bridge may be eating attributes"

# ── badlist_count: the empty file is the case that broke ─────────────────────
# A clean run leaves a ZERO-BYTE badlist, which is the common case, so the
# counter has to be right there before anywhere else. Live 2026-09-09 it
# returned "0\n0" and the verdict's own -gt test errored out.
: > "$TMP/badlist-empty"
printf '12345\n67890\n' > "$TMP/badlist-two"
eq "$(badlist_count "$TMP/badlist-empty")"        0 "badlist_count of an empty file is one 0, not two"
eq "$(badlist_count "$TMP/badlist-two")"          2 "badlist_count counts entries"
eq "$(badlist_count "$TMP/nope-does-not-exist")"  0 "badlist_count of a missing file is 0"
# The whole point: usable as an integer with NO stderr. Asserting only the
# truth value would pass either way — a `[` that errors out is false too, which
# is exactly how the live bug hid behind a PASS.
eq "$( { [ "$(badlist_count "$TMP/badlist-empty")" -gt 0 ]; } 2>&1 )" "" \
   "comparing an empty-badlist count emits no shell error"

# ── verdict_surface: platter faults vs bus faults are different verdicts ─────
starts "$(verdict_surface 0 0 0 0 0 0)" PASS   "clean run passes"
starts "$(verdict_surface 1 0 0 0 0 0)" FAIL   "one bad block fails"
starts "$(verdict_surface 0 1 0 0 0 0)" FAIL   "a reallocated sector fails"
starts "$(verdict_surface 0 0 1 0 0 0)" FAIL   "a pending sector fails"
starts "$(verdict_surface 0 0 0 1 0 0)" FAIL   "an offline-uncorrectable fails"
starts "$(verdict_surface 0 0 0 0 7 0)" BUS    "rising UDMA_CRC is the cable/dock, not the platter"
starts "$(verdict_surface 0 0 0 0 0 4)" BUS    "usb resets in the window are the dock, not the platter"
# Precedence matters: a real bad block during a bus storm is still a bad block.
starts "$(verdict_surface 2 0 0 0 9 9)" FAIL   "platter evidence outranks bus noise"

# ── the write interlock ──────────────────────────────────────────────────────
SAFE=/dev/disk/by-id/ata-WDC_WD80EAAZ-00SRMA0_ABC123
eq "$(unsafe_reasons "$SAFE" ABC123 ABC123 "" "" "" "")" "" "a blank, unmounted, serial-matched ata-* target is safe"
has "$(unsafe_reasons /dev/sdb ABC123 ABC123 "" "" "" "")" "not a /dev/disk/by-id/ata-*" "a bare /dev/sdX target is refused"
has "$(unsafe_reasons /dev/disk/by-id/usb-Kingston_XS2000-0:0 ABC123 ABC123 "" "" "" "")" "not a /dev/disk/by-id/ata-*" "even a by-id usb-* path is refused (the docks expose ata-* too)"
has "$(unsafe_reasons "$SAFE" "" ABC123 "" "" "" "")" "--serial not given" "no --serial is refused"
has "$(unsafe_reasons "$SAFE" WANTED ABC123 "" "" "" "")" "serial mismatch" "a serial mismatch is refused"
# WD prints the bare serial on the label and reports it with a "WD-" prefix over
# ATA (measured on this very drive: label RD2RRPWH, device WD-RD2RRPWH). The
# gate must not cry fraud over a vendor prefix -- a false RETURN in the one gate
# that has to be trusted is worse than no gate.
eq "$(unsafe_reasons "$SAFE" RD2RRPWH WD-RD2RRPWH "" "" "" "")" "" "the sticker serial matches the ATA serial across WD's own prefix"
eq "$(unsafe_reasons "$SAFE" WD-RD2RRPWH RD2RRPWH "" "" "" "")" "" "and in the other direction"
has "$(unsafe_reasons "$SAFE" RD2RRPWH WD-RD2RRPWI "" "" "" "")" "serial mismatch" "one character off is still a mismatch"
serial_matches "" ABC123 && bad "an empty expectation must never match" || pass "an empty expectation never matches"
has "$(unsafe_reasons "$SAFE" ABC123 ABC123 gpt "" "" "")" "partition table" "an existing partition table is refused"
has "$(unsafe_reasons "$SAFE" ABC123 ABC123 "" ext4 "" "")" "ext4 signature" "an existing filesystem is refused"
has "$(unsafe_reasons "$SAFE" ABC123 ABC123 "" ext4 /mnt/immich-2024-backup "")" "mounted at /mnt/immich-2024-backup" "a mounted device is refused"
has "$(unsafe_reasons "$SAFE" ABC123 ABC123 "" "" "" UUID=fd0b0662)" "appears in /etc/fstab" "an fstab-listed device is refused"
# All of them at once: the HGST. Same drive and same UUID as before — it was
# /mnt/servarr until 2026-09-10 and is /mnt/immich-2024-backup now, which is
# exactly why the fixture spells out a live mount rather than a placeholder.
# Every reason must be reported, because the operator reading this needs to know
# it was not one near-miss.
n=$(unsafe_reasons /dev/sdb "" JD100ACC2V5ZVK gpt ext4 /mnt/immich-2024-backup UUID=fd0b0662 | grep -c .)
[ "$n" -ge 5 ] && pass "the live HGST trips at least 5 interlocks ($n)" || bad "HGST tripped only $n interlocks"

# ── source-text assertions: what the phases may and may not do ──────────────
src="$(cat "$SCRIPT")"
code="$(printf '%s\n' "$src" | sed 's/[[:space:]]*#.*$//')"
has   "$code" 'badblocks -b 4096 -c 4096 -w -t random' "the surface pass pins -b 4096 (the ceiling) and -c 4096 (the BOT bridge)"
hasnt "$code" 'badblocks -w /dev' "badblocks is never invoked on a literal /dev path"
# The gate must precede the write in file order — a destructive command placed
# above its own interlock would still pass every unit test above.
gate_line=$(printf '%s\n' "$src" | grep -n 'reasons=$(unsafe_reasons' | head -1 | cut -d: -f1)
bb_line=$(printf '%s\n' "$src" | grep -n 'sudo badblocks' | head -1 | cut -d: -f1)
[ -n "$gate_line" ] && [ -n "$bb_line" ] && [ "$gate_line" -lt "$bb_line" ] \
  && pass "the interlock is evaluated before badblocks runs" \
  || bad "interlock at line ${gate_line:-none}, badblocks at ${bb_line:-none}"
# -go is required to write, and --detach must hand off to systemd-run: badblocks
# is not resumable, so a dead ssh session would cost the whole pass.
has "$code" 'if [ "$go" != go ]' "the surface phase writes nothing without -go"
has "$code" 'systemd-run' "--detach re-executes under systemd-run"
# Identity must not need -go, and must not write to the drive at all.
ident="$(printf '%s\n' "$src" | awk '/^phase_identity\(\)/,/^}/' | sed 's/[[:space:]]*#.*$//')"
hasnt "$ident" 'badblocks' "the identity phase never writes to the disk"
hasnt "$ident" 'smartctl -t' "the identity phase does not start a self-test (it must finish in minutes, on the return-window clock)"
has   "$ident" 'devstat' "the identity phase captures the device statistics log (or records that the bridge ate it)"
# The WWN carries the maker's OUI and is the one identifier a relabeller cannot
# touch. 5000cca (HGST) under a WD sticker IS the July 2026 fraud signature, so
# the identity phase must name both OUIs explicitly rather than just compare.
has   "$ident" '50014ee' "the identity phase recognises Western Digital's WWN OUI"
has   "$ident" '5000cca' "the identity phase calls out the HGST OUI by name (the July fraud signature)"
has   "$ident" 'WWN MISMATCH' "a WWN disagreeing with the sticker is a return reason of its own"

echo
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
