#!/usr/bin/env bash
# Tests for lib-memory.sh, the shared emitters behind the memory hooks.
#
# It had no suite of its own, which is how the comment-stripping bug below stayed
# invisible: mem_strip_comments is what decides whether the REGISTER-REINJECT
# span survives into a session, and nothing in `just test` asserted it. The first
# two cases are the regression guard — a future "simplify" back to a single sed
# range silently deletes the marked block from every SessionStart.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# shellcheck source=../lib-memory.sh
. "$HERE/../lib-memory.sh"

# --- mem_strip_comments: the one-line-comment trap ---
cat > "$T/oneline.md" <<'MD'
- before
<!-- a one-line note -->
- after the one-liner
MD
out="$(mem_strip_comments "$T/oneline.md")"
if printf '%s' "$out" | grep -q 'after the one-liner' && ! printf '%s' "$out" | grep -q 'one-line note'; then
  pass "a one-line comment is dropped without swallowing the line after it"
else
  die "one-line comment ate following content (sed range looks for --> from the NEXT line): got '$out'"
fi

# --- mem_strip_comments: the exact register-reinject shape ---
cat > "$T/markers.md" <<'MD'
<!--
a multi-line human note
-->
## Register

<!-- REGISTER-REINJECT:START -->
- **Answer first.** the rule
<!-- REGISTER-REINJECT:END -->
- **kept** trailing bullet
MD
out="$(mem_strip_comments "$T/markers.md")"
if printf '%s' "$out" | grep -q 'Answer first' \
   && printf '%s' "$out" | grep -q 'kept' \
   && ! printf '%s' "$out" | grep -q 'REGISTER-REINJECT' \
   && ! printf '%s' "$out" | grep -q 'multi-line human note'; then
  pass "marker pair is stripped, the bullets between them survive"
else
  die "marker/block stripping wrong: got '$out'"
fi

# --- mem_has_content ---
: > "$T/empty.md"
printf '   \n\t\n' > "$T/blank.md"
printf 'x\n'        > "$T/full.md"
if ! mem_has_content "$T/empty.md" && ! mem_has_content "$T/blank.md" \
   && ! mem_has_content "$T/nope.md" && mem_has_content "$T/full.md"; then
  pass "mem_has_content rejects empty, whitespace-only and absent files"
else
  die "mem_has_content misclassified one of empty/blank/absent/full"
fi

# --- mem_human ---
if [ "$(mem_human 512)" = "512B" ] && [ "$(mem_human 2048)" = "2KB" ]; then
  pass "mem_human switches from B to KB at 1024"
else
  die "mem_human: got '$(mem_human 512)' and '$(mem_human 2048)'"
fi

# --- mem_emit_full: header, stripped body, silence on an empty store ---
out="$(mem_emit_full "$T/markers.md" "HEADER:")"
if printf '%s' "$out" | grep -q '^HEADER:$' && printf '%s' "$out" | grep -q 'Answer first'; then
  pass "mem_emit_full prints the header and the stripped body"
else
  die "mem_emit_full body/header wrong: got '$out'"
fi
if [ -z "$(mem_emit_full "$T/empty.md" "HEADER:")" ]; then
  pass "mem_emit_full is silent for an empty store"
else
  die "mem_emit_full emitted a header for an empty store"
fi

# --- mem_emit_index: path, size, and '## ' headings with line numbers ---
printf '# t\n\n## First\nbody\n\n## Second\nbody\n' > "$T/idx.md"
out="$(mem_emit_index "$T/idx.md" "  LABEL")"
if printf '%s' "$out" | grep -q '^  LABEL ([0-9]*B)$' \
   && printf '%s' "$out" | grep -q 'L3  First' \
   && printf '%s' "$out" | grep -q 'L6  Second'; then
  pass "mem_emit_index maps '## ' headings to their line numbers"
else
  die "mem_emit_index wrong: got '$out'"
fi

# --- mem_warn_if_over: stderr only, and it counts BYTES not characters ---
# The stores are largely Cyrillic at 2 bytes per character, so a ${#var}
# character count reads ~40% under the byte size the harness actually caps on.
o="$T/o"; e="$T/e"
MEM_TOTAL_BUDGET=8 mem_warn_if_over "абвгде" "t" >"$o" 2>"$e"   # 6 chars, 12 bytes
if [ ! -s "$o" ] && grep -q 'over the 8 B budget' "$e"; then
  pass "mem_warn_if_over counts bytes (not characters) and warns on stderr only"
else
  die "mem_warn_if_over: stdout='$(cat "$o")' stderr='$(cat "$e")' — a character count would not have tripped"
fi
MEM_TOTAL_BUDGET=100 mem_warn_if_over "short" "t" >"$o" 2>"$e"
if [ ! -s "$o" ] && [ ! -s "$e" ]; then
  pass "mem_warn_if_over is silent under budget"
else
  die "mem_warn_if_over warned under budget"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS"
exit "$fail"
