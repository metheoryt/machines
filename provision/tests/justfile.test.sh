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
#
# `backup` and `rollback` left this list on 2026-08-01: both were Nix recipes
# (`nix-collect-garbage`/`nixos-rebuild --rollback`, plus a `cp -r` of the repo to
# a timestamped .backup dir) and went with the flake. They are named here only so
# the next reader knows they were removed on purpose rather than dropped from the
# assertion by accident. `test` replaces them as the spot-check that matters —
# it is now the repo's only gate, so it must never fall out of the help.
for r in provision-mac provision-wsl provision test health update-gortex; do
  printf '%s\n' "$listing" | grep -qE "^[[:space:]]+${r}( |$)" \
    && pass "help lists '$r'" \
    || die "help does not list '$r'"
done

# ── the gate must reach EVERY suite in the repo ────────────────────────────────
# The recipe's own comment says to keep a glob "rather than a hand-listed set: a
# new *.test.sh must be picked up without editing this recipe, or coverage
# silently stops growing." The four-directory glob it shipped with IS a
# hand-listed set, and coverage did silently stop growing: ten suites lived
# outside those directories and were run by nothing, for weeks, while the gate
# reported "all N suites passed" and everyone read that as the repo.
#
# So assert the property the comment claims, mechanically: ask the gate what it
# will run, and diff that against every tracked *.test.sh.
#
# `_test-suites` exists so this can be asked instead of inferred. Parsing the
# glob out of the recipe was the first version and it was worse in both
# directions: it broke whenever the loop changed shape, and it verified a copy of
# the recipe's intent rather than the recipe. A private recipe that emits the
# list, consumed by both `test` and this assertion, has exactly one source.
#
# Not done by running `just test` itself: this file is one of the suites it runs,
# so that recurses forever.
reached="$(cd "$REPO" && just --justfile "$JUSTFILE" _test-suites 2>/dev/null | sort -u)"
tracked="$(cd "$REPO" && git ls-files '*.test.sh' 2>/dev/null | sort -u)"
if [ -z "${reached// /}" ]; then
  die "'just _test-suites' produced nothing — the gate cannot say what it runs"
else
  # tracked - reached. The other direction is deliberately allowed: an untracked
  # suite in a working tree SHOULD run, and must not fail the gate for existing.
  unreached="$(comm -23 <(printf '%s\n' "$tracked") <(printf '%s\n' "$reached"))"
  if [ -z "$unreached" ]; then
    pass "the gate reaches every tracked *.test.sh ($(printf '%s\n' "$tracked" | wc -l | tr -d ' ') suites)"
  else
    die "suites tracked but never run by the gate:
$(printf '%s\n' "$unreached" | sed 's/^/    /')"
  fi
fi

# One naming convention, so the glob above can be exhaustive. A test script named
# test_*.sh is invisible to a *.test.sh glob no matter how wide the directory
# list gets — widening the glob and leaving the name is a half-fix that reads as
# a whole one. (test_distill.py is deliberately exempt: it needs pytest, which is
# not in the fleet toolchain. That is a judgement call recorded in the review,
# not an oversight — hence the .sh restriction here.)
strays="$(cd "$REPO" && git ls-files '*test_*.sh' 2>/dev/null)"
if [ -z "$strays" ]; then
  pass "no test_*.sh strays — every shell suite is named *.test.sh"
else
  die "shell suites named test_*.sh, which no *.test.sh glob can reach:
$(printf '%s\n' "$strays" | sed 's/^/    /')"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
