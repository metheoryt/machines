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

# The runtime behaviour itself, asserted rather than described: the whole reason this
# file exists is that the unbraced form is fatal under `set -u` in a UTF-8 locale.
# Skipped where the locale is unavailable, since that is what decides the outcome.
if locale -a 2>/dev/null | grep -qiE '^(en_US\.utf-?8|C\.utf-?8)$'; then
  loc="$(locale -a 2>/dev/null | grep -iE '^(en_US\.utf-?8|C\.utf-?8)$' | head -1)"
  if LC_ALL="$loc" bash -c 'set -u; v=x; : "$v'$'\xe2\x80\xa6''"' 2>/dev/null; then
    die "unbraced expansion no longer fails under $loc — bash changed; re-check this rule"
  else
    pass "unbraced form still fails under $loc (the rule is still load-bearing)"
  fi
  LC_ALL="$loc" bash -c 'set -u; v=x; : "${v}'$'\xe2\x80\xa6''"' 2>/dev/null \
    && pass "braced form succeeds under $loc" \
    || die "braced form fails under $loc"
else
  echo "SKIP (no UTF-8 locale available to assert the runtime behaviour)"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
