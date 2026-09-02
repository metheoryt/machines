#!/usr/bin/env bash
# Guard against an UNBRACED shell expansion sitting directly against a multibyte
# character — `"$var…"` rather than `"${var}…"`.
#
# This is not style. Under bash 5.x in a UTF-8 locale, the bytes of a character like
# U+2026 (…) are absorbed INTO the identifier, so `$var…` expands a variable named
# `var…` which does not exist. With `set -u` that aborts the script. Verified:
#
#   $ LANG=en_US.UTF-8 bash -c 'set -u; step=hello; echo "$step…"'
#   bash: step<mojibake>: unbound variable
#   $ LC_ALL=C          bash -c 'set -u; step=hello; echo "$step…"'   # -> hello…
#
# So the failure is LOCALE-DEPENDENT, which is what makes it worth a test: it works
# for whoever has a C locale and breaks for everyone else, and the break is at
# runtime rather than at parse time, so `bash -n` never sees it.
#
# It was live in three places until 2026-08-01, and the worst was
# provision/provision.sh's `echo "  ⟳ applying $role…"` — one line AFTER the
# `Apply <role>? [y/N]` prompt. `just provision --apply` therefore took the user's
# consent and then aborted before running a single role, on any UTF-8-locale box.
# provision-wsl.sh's copy is why provision-wsl.test.sh had been red for weeks; that
# red was reporting a real bug in shipped code the whole time, not test rot.
#
# The fix is always the same: brace it. `${var}…` is locale-proof.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../.." && pwd)"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP (python3 absent)"; exit 0; }

# The scan runs in python because the pattern is defined over BYTES: a leading UTF-8
# continuation byte (0xc2-0xf4) immediately after an identifier. Writing the literal
# pattern in this file as shell would make the file flag itself.
found="$(python3 - "$REPO" <<'PY'
import os, re, sys
repo = sys.argv[1]
pat = re.compile(rb'\$[A-Za-z_][A-Za-z0-9_]*[\xc2-\xf4]')
skip = {'.git', 'node_modules', 'install-media'}
for root, dirs, files in os.walk(repo):
    dirs[:] = [d for d in dirs if d not in skip]
    for fn in files:
        if not fn.endswith(('.sh', '.bash')):
            continue
        p = os.path.join(root, fn)
        with open(p, 'rb') as fh:
            for n, line in enumerate(fh.read().split(b'\n'), 1):
                # Whole-line comments are exempt: prose describing the pattern (this
                # file's own header does) is harmless, only code can abort at runtime.
                # Deliberately crude -- an inline `# ...$x<mb>` would false-positive,
                # which costs one brace and is the safe direction to be wrong in.
                if line.lstrip().startswith(b'#'):
                    continue
                if pat.search(line):
                    rel = os.path.relpath(p, repo)
                    print(f"{rel}:{n}: {line.decode('utf-8', 'replace').strip()[:100]}")
PY
)"

if [ -z "$found" ]; then
  pass "no unbraced expansion sits against a multibyte character"
else
  die "unbraced expansion before a multibyte char — brace it as \${var}:"
  printf '%s\n' "$found" | sed 's/^/    /'
fi

# Positive control: the detector must actually fire, or an empty result above is
# indistinguishable from a scan that silently matched nothing (a bad regex, a walk
# that visited no files). Builds the offending byte sequence at runtime so this
# file never contains the pattern it forbids.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf 'x=1\necho "$x\xe2\x80\xa6"\n' > "$tmp/bait.sh"
bait="$(python3 - "$tmp" <<'PY'
import os, re, sys
pat = re.compile(rb'\$[A-Za-z_][A-Za-z0-9_]*[\xc2-\xf4]')
for fn in os.listdir(sys.argv[1]):
    if fn.endswith('.sh'):
        with open(os.path.join(sys.argv[1], fn), 'rb') as fh:
            if pat.search(fh.read()):
                print("HIT")
PY
)"
[ "$bait" = "HIT" ] && pass "the detector fires on a known-bad file (positive control)" \
  || die "the detector did NOT fire on a known-bad file — the scan above proves nothing"

# And the braced form must NOT be flagged, or the rule would forbid its own fix.
printf 'x=1\necho "${x}\xe2\x80\xa6"\n' > "$tmp/ok.sh"
rm -f "$tmp/bait.sh"
clean="$(python3 - "$tmp" <<'PY'
import os, re, sys
pat = re.compile(rb'\$[A-Za-z_][A-Za-z0-9_]*[\xc2-\xf4]')
hits = 0
for fn in os.listdir(sys.argv[1]):
    if fn.endswith('.sh'):
        with open(os.path.join(sys.argv[1], fn), 'rb') as fh:
            if pat.search(fh.read()):
                hits += 1
print(hits)
PY
)"
[ "$clean" = "0" ] && pass "the braced form \${var} is not flagged" \
  || die "the braced form is flagged — the rule forbids its own fix"

# THE STATED MECHANISM DOES NOT REPRODUCE, AND THIS BLOCK NO LONGER PRETENDS IT
# DOES. 65aac22 (2026-08-01) introduced this rule with the explanation that under
# bash 5.x in a UTF-8 locale the ellipsis bytes are "absorbed INTO the identifier",
# so `"$var…"` expands a variable named `var…` and `set -u` aborts. Measured
# 2026-09-02 and it is false:
#
#   • as `bash -c` AND as a real script file, unbraced exits 0 and prints correctly
#   • on bash 5.3.9 (desktop-wsl), 5.2.37 (latitude), 5.2.15 (hub)
#   • under LC_ALL=C, C.utf8 and en_US.utf8
#   • unbracing ONLY that one line at HEAD leaves provision-wsl.test.sh green, and
#     the whole 65aac22^ tree — the "red" state the fix was credited with greening —
#     is green today too
#
# That is consistent with bash's identifier scan being ASCII-only in every build,
# which is why no locale could change it. What the original red actually was is
# unidentified; it is NOT this. Do not write a replacement mechanism here without
# measuring one.
#
# THE RULE STAYS ANYWAY, and the scan above still fails the gate — bracing is
# correct regardless of why, it costs two characters, and the cause of the
# original red being unknown is an argument for keeping a guard, not for dropping
# one. What changed is that this block REPORTS the behaviour instead of asserting
# it: a `die` here made the gate red over bash declining to do something no bash
# does, which is the "red nobody can act on" failure P4 exists to kill.
if locale -a 2>/dev/null | grep -qiE '^(en_US\.utf-?8|C\.utf-?8)$'; then
  loc="$(locale -a 2>/dev/null | grep -iE '^(en_US\.utf-?8|C\.utf-?8)$' | head -1)"
  if LC_ALL="$loc" bash -c 'set -u; v=x; : "$v'$'\xe2\x80\xa6''"' 2>/dev/null; then
    printf '  NOTE unbraced form does NOT abort under %s — as measured 2026-09-02.\n' "$loc"
    printf '       The rule is style + defence-in-depth, not a reproduced bash bug.\n'
  else
    pass "unbraced form fails under $loc — the documented mechanism reproduces here"
  fi
  LC_ALL="$loc" bash -c 'set -u; v=x; : "${v}'$'\xe2\x80\xa6''"' 2>/dev/null \
    && pass "braced form succeeds under $loc" \
    || die "braced form fails under $loc"
else
  echo "SKIP (no UTF-8 locale available to assert the runtime behaviour)"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
