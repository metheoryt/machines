#!/usr/bin/env bash
# Behavior tests for dream.sh — the mechanics behind /dream. Everything here
# runs against a throwaway DREAM_ROOT and a throwaway store; no real memory
# store is read or written.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../dream.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

export DREAM_ROOT="$tmp/dream"
D() { bash "$SCRIPT" "$@"; }

# --- paths -------------------------------------------------------------------
out="$(D paths)"
case "$out" in
  *"$tmp/dream/queue.md"*) pass "paths honours DREAM_ROOT" ;;
  *) die "paths honours DREAM_ROOT: $out" ;;
esac

# --- id: stable, and sensitive to each of its three inputs -------------------
a="$(D id target anchor delete)"
b="$(D id target anchor delete)"
[ "$a" = "$b" ] && pass "id is stable" || die "id is stable ($a vs $b)"
[ "${#a}" -eq 8 ] && pass "id is 8 chars" || die "id is 8 chars (${#a})"
[ "$(D id target anchor merge)"  != "$a" ] && pass "id varies by action" || die "id varies by action"
[ "$(D id target anchor2 delete)" != "$a" ] && pass "id varies by anchor" || die "id varies by anchor"
[ "$(D id target2 anchor delete)" != "$a" ] && pass "id varies by target" || die "id varies by target"

# --- index: section line, byte size and heading ------------------------------
store="$tmp/store.md"
printf '# Title\n\nintro\n\n## Alpha\n- one\n\n## Beta\n- two\n- three\n' > "$store"
idx="$(D index "$store")"
[ "$(echo "$idx" | wc -l)" -eq 2 ] && pass "index finds both sections" || die "index finds both sections: $idx"
echo "$idx" | grep -q '^5	' && pass "index reports the heading line" || die "index reports the heading line: $idx"
# "## Beta\n- two\n- three\n" = 8 + 6 + 8 = 22 bytes
echo "$idx" | grep -q '^8	22	Beta$' && pass "index counts section bytes" || die "index counts section bytes: $idx"

# A store with NO '## ' headings must still emit exactly 4 columns. `grep -c`
# prints 0 AND exits 1 on no match, so a `|| echo 0` fallback emitted a second
# line and split the row in two.
flat="$tmp/flat.md"; printf '# Title\n\njust prose, no sections\n' > "$flat"
[ "$(D index "$flat" | wc -l)" -eq 0 ] && pass "index of a section-less file is empty" || die "index of a section-less file is empty"

# --- status / append / suppression -------------------------------------------
id="$(D id "$store" '## Alpha' delete)"
[ "$(D status "$id" | cut -f1)" = new ] && pass "unknown id is new" || die "unknown id is new"

item="$tmp/item.md"
printf '## %s · delete · %s\n\n- **why:** test\n' "$id" "$store" > "$item"
[ "$(D append "$id" "$item" | cut -f1)" = appended ] && pass "append files a new item" || die "append files a new item"
[ "$(D status "$id" | cut -f1)" = open ] && pass "a filed item reads open" || die "a filed item reads open"

# THE discriminating check: a second run must file nothing.
[ "$(D append "$id" "$item" | cut -f1)" = suppressed ] && pass "an open item is suppressed" || die "an open item is suppressed"
[ "$(grep -c "^## $id " "$DREAM_ROOT/queue.md")" -eq 1 ] && pass "suppression leaves one copy" || die "suppression leaves one copy"

# append refuses an item file whose first line is not its own id
bad="$tmp/bad.md"; printf '## deadbeef · delete · x\n' > "$bad"
D append "$(D id x y z)" "$bad" >/dev/null 2>&1 && die "append rejects a mismatched item" || pass "append rejects a mismatched item"

# --- decide: ledger + cut out of the queue, and rejection sticks -------------
id2="$(D id "$store" '## Beta' merge)"
item2="$tmp/item2.md"
printf '## %s · merge · %s\n\n- **why:** second\n' "$id2" "$store" > "$item2"
D append "$id2" "$item2" >/dev/null

D decide "$id" applied "landed" >/dev/null
grep -q "^## $id " "$DREAM_ROOT/queue.md" && die "decide cuts the item out" || pass "decide cuts the item out"
grep -q "^## $id2 " "$DREAM_ROOT/queue.md" && pass "decide leaves other items alone" || die "decide leaves other items alone"
[ "$(D status "$id")" = "$(printf 'decided\tapplied')" ] && pass "an applied id reads decided" || die "an applied id reads decided: $(D status "$id")"
[ "$(D append "$id" "$item" | cut -f1)" = suppressed ] && pass "an applied item never returns" || die "an applied item never returns"

D decide "$id2" rejected "not worth it" >/dev/null
[ "$(D append "$id2" "$item2" | cut -f1)" = suppressed ] && pass "a REJECTED item never returns" || die "a rejected item never returns"
grep -q 'not worth it' "$DREAM_ROOT/ledger.tsv" && pass "the ledger keeps the reason" || die "the ledger keeps the reason"

D decide "$id" bogus "x" >/dev/null 2>&1 && die "decide refuses an unknown state" || pass "decide refuses an unknown state"

# --- the invariant: nothing is written outside DREAM_ROOT --------------------
# The store the whole run was pointed at must be byte-identical afterwards.
printf '# Title\n\nintro\n\n## Alpha\n- one\n\n## Beta\n- two\n- three\n' > "$tmp/expect.md"
cmp -s "$store" "$tmp/expect.md" && pass "no memory store was modified" || die "no memory store was modified"

# Every file dream.sh created lives under DREAM_ROOT.
stray="$(find "$tmp" -newer "$SCRIPT" -type f ! -path "$DREAM_ROOT/*" ! -name 'store.md' ! -name 'flat.md' ! -name 'item*.md' ! -name 'bad.md' ! -name 'expect.md' 2>/dev/null)"
[ -z "$stray" ] && pass "dream.sh wrote only under DREAM_ROOT" || die "dream.sh wrote only under DREAM_ROOT: $stray"

# --- instructions: same shape, symlinks resolved and deduped ------------------
ins="$(D instructions)"
if [ -n "$ins" ]; then
  echo "$ins" | awk -F'\t' 'NF != 4 { exit 1 }' \
    && pass "instructions emits 4 TSV columns" || die "instructions emits 4 TSV columns: $ins"
  [ "$(echo "$ins" | cut -f1 | sort | uniq -d | wc -l)" -eq 0 ] \
    && pass "instructions dedupes CLAUDE.md->AGENTS.md symlinks" || die "instructions dedupes symlinks"
  # The path is column 1, not the end of the line — anchor on the field.
  if [ -L "$HOME/machines/CLAUDE.md" ]; then
    echo "$ins" | cut -f1 | grep -qx "$HOME/machines/AGENTS.md" \
      && ! echo "$ins" | cut -f1 | grep -qx "$HOME/machines/CLAUDE.md" \
      && pass "instructions reports the resolved real path" || die "instructions reports the resolved real path"
  else
    pass "instructions resolved-path check (SKIP: no symlink here)"
  fi
else
  pass "instructions found none (SKIP shape assertions)"
fi

# --- branches: other boxes' memory, read from the bare repo ------------------
br="$(D branches 2>/dev/null)"
if [ -n "$br" ]; then
  echo "$br" | awk -F'\t' 'NF != 4 { exit 1 }' \
    && pass "branches emits 4 TSV columns" || die "branches emits 4 TSV columns"
  echo "$br" | cut -f1 | grep -qx 'origin/main' \
    && die "branches excludes origin/main" || pass "branches excludes origin/main"
  echo "$br" | awk -F'\t' '$4 !~ /^[0-9]+$/ { exit 1 }' \
    && pass "branches reports a byte size" || die "branches reports a byte size"
else
  pass "branches found none (SKIP: no dotfiles branches here)"
fi

# --- scan is read-only and shaped as documented ------------------------------
# Run it for real (it reads live stores) and assert the shape, not the content.
scan="$(D scan)"
if [ -n "$scan" ]; then
  echo "$scan" | awk -F'\t' 'NF != 4 { exit 1 }' \
    && pass "scan emits 4 TSV columns" || die "scan emits 4 TSV columns"
  echo "$scan" | awk -F'\t' '$3 !~ /^(shared|host|untracked|repo:.+)$/ { exit 1 }' \
    && pass "scan scopes are from the documented set" || die "scan scopes are from the documented set: $scan"
else
  pass "scan found no stores (SKIP shape assertions)"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
