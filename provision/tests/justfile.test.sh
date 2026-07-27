#!/usr/bin/env bash
# Unit tests for the justfile's self-documenting help.
#
# `just` (the default recipe) is `just --list`, generated from each recipe's
# [group('…')] + [doc('…')] attributes. Before that, help was a hardcoded block
# of @echo lines maintained by hand — it drifted until 24 of 41 recipes were
# undocumented. These tests make the drift impossible to reintroduce: a recipe
# without both attributes fails the suite.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../.." && pwd)"
JUSTFILE="$REPO/justfile"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

command -v just >/dev/null 2>&1 || { echo "SKIP (just absent)"; exit 0; }
[ -f "$JUSTFILE" ] || { echo "FAIL justfile not found at $JUSTFILE"; exit 1; }

# The justfile must parse at all — a syntax error here breaks every recipe.
if just --justfile "$JUSTFILE" --summary >/dev/null 2>&1; then
  pass "justfile parses"
else
  echo "FAIL justfile does not parse:"; just --justfile "$JUSTFILE" --summary 2>&1 | head -5
  exit 1
fi

listing="$(just --justfile "$JUSTFILE" --list 2>/dev/null)"

# Every public recipe must appear in the generated help WITH a description.
# --summary omits private recipes (leading _ or [private]), which is exactly the
# set that should be user-visible.
missing_doc=()
for r in $(just --justfile "$JUSTFILE" --summary 2>/dev/null); do
  # Match the recipe at the start of a listing line, then require a `# …` on it.
  line="$(printf '%s\n' "$listing" | grep -E "^[[:space:]]+${r}( |$)" | head -1)"
  if [ -z "$line" ]; then
    missing_doc+=("$r (absent from --list)")
  elif ! printf '%s' "$line" | grep -q '#'; then
    missing_doc+=("$r (no [doc])")
  fi
done
if [ "${#missing_doc[@]}" -eq 0 ]; then
  pass "every public recipe appears in the help with a description"
else
  die "recipes missing from the help: ${missing_doc[*]}"
fi

# Every public recipe must be in a group, or it lands in an untitled block at
# the top of the listing and is easy to miss.
ungrouped=()
while IFS= read -r r; do
  grep -qE "^\[group\('[a-z]+'\)\]" <<<"$(grep -B3 -E "^${r}( |:)" "$JUSTFILE" | grep -E "^\[group")" \
    || ungrouped+=("$r")
done < <(just --justfile "$JUSTFILE" --summary 2>/dev/null | tr ' ' '\n')
if [ "${#ungrouped[@]}" -eq 0 ]; then
  pass "every public recipe declares a [group]"
else
  die "recipes without [group]: ${ungrouped[*]}"
fi

# The help must be GENERATED. A reintroduced hardcoded echo block is the exact
# regression this file exists to prevent.
if grep -qE '^\s+@echo "  just ' "$JUSTFILE"; then
  die "the default recipe hardcodes recipe names again — use [doc]/[group] + just --list"
else
  pass "help is generated, not hardcoded"
fi

# Spot-check that recipes added late in the migration are actually listed —
# these were among the 24 the old hardcoded block had missed.
for r in provision-mac provision-wsl provision backup health rollback update-gortex; do
  printf '%s\n' "$listing" | grep -qE "^[[:space:]]+${r}( |$)" \
    && pass "help lists '$r'" \
    || die "help does not list '$r'"
done

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
