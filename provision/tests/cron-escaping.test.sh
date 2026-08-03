#!/usr/bin/env bash
# Every cron line the tier_* functions install must survive crontab(5)'s parser.
#
# THE BUG THIS EXISTS FOR: crontab(5) gives `%` a meaning inside the command
# field — it terminates the command, and everything after it becomes the job's
# stdin. `tier_selfpull` and `tier_dotfiles_sync` both wrote their jitter as
# `sleep $((RANDOM %% 120))`, which printf renders as a bare `%`, so cron stored
#
#     */10 * * * * sleep $((RANDOM
#
# as the command and fed ` 120)); /usr/bin/env bash …` to it on stdin. The line
# installs without complaint, `crontab -l` shows it in full, and the job silently
# never runs. Measured live on desktop-wsl, whose journal logs
# `CMD (sleep $((RANDOM )`. `tier_autofetch`'s line has no `%` at all, which is
# the only reason one of the three fallbacks worked.
#
# The escape was specified and then lost: the design at
# docs/superpowers/plans/2026-07-21-fleet-converge-self-healing-sync.md:827
# writes `\\%`, and the implementation dropped the backslash.
#
# WHY THIS IS A STATIC CHECK, unlike git-autofetch.test.sh's behavioural cases:
# the property is "what we hand to crontab", and a test may not touch the real
# crontab of the box running it. So this reconstructs the exact bytes the tier
# would emit — by extracting the printf format from tiers.sh, not by restating
# it — and then applies crontab(5)'s own truncation rule to them. The assertion
# is on the command cron would actually execute, not on the presence of a
# character.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIERS="$HERE/../lib/tiers.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

[ -r "$TIERS" ] || { echo "FAIL cannot read $TIERS"; exit 1; }

# cron_command <line> — what crontab(5) would actually run: the command field up
# to the first UNESCAPED `%`, with `\%` unescaped back to a literal `%`.
cron_command() {
    local line="$1" out="" i=0 c n
    while [ "$i" -lt "${#line}" ]; do
        c="${line:$i:1}"
        if [ "$c" = '\' ]; then
            n="${line:$((i+1)):1}"
            if [ "$n" = '%' ]; then out="$out%"; i=$((i+2)); continue; fi
            out="$out\\"; i=$((i+1)); continue
        fi
        [ "$c" = '%' ] && break          # cron: command ends here, rest is stdin
        out="$out$c"; i=$((i+1))
    done
    printf '%s' "$out"
}

# Sanity-check the simulator itself before trusting a verdict from it, so a bug
# in cron_command cannot read as a green suite.
[ "$(cron_command 'a%b')"  = "a"   ] && pass "simulator: a bare % truncates"        || die "simulator: bare % did not truncate"
[ "$(cron_command 'a\%b')" = "a%b" ] && pass "simulator: an escaped % survives"     || die "simulator: escaped % did not survive"
[ "$(cron_command 'ab')"   = "ab"  ] && pass "simulator: a %-free line is verbatim" || die "simulator: %-free line was altered"

# ── Reconstruct every cron line tiers.sh installs ─────────────────────────────
# Matched by shape (a five-field schedule inside a printf), so a NEW cron line
# added later is covered without touching this test. The format string is taken
# verbatim from the file; only the %s arguments are stand-ins.
mapfile -t fmts < <(grep -n "printf '[^']*\* \* \* \*" "$TIERS" \
                    | sed "s/^\([0-9]*\):.*printf '\([^']*\)'.*/\1 \2/")

[ "${#fmts[@]}" -gt 0 ] \
  && pass "found ${#fmts[@]} cron line(s) in tiers.sh to check" \
  || { die "found NO cron lines in tiers.sh — this test has stopped testing anything"; }

for entry in "${fmts[@]}"; do
    lineno="${entry%% *}"
    fmt="${entry#* }"
    # printf renders %% -> % and consumes the %s placeholders. Supply EXACTLY as
    # many arguments as the format has, or printf reuses the format and emits the
    # line twice — the script path is always the last one, so pad in front of it.
    stripped="${fmt//%s/}"
    nargs=$(( (${#fmt} - ${#stripped}) / 2 ))
    args=()
    while [ "${#args[@]}" -lt $((nargs - 1)) ]; do args+=("CRONENV=1 "); done
    [ "$nargs" -gt 0 ] && args+=("/opt/SCRIPT-MARKER")
    line="$(printf -- "$fmt" "${args[@]+"${args[@]}"}" 2>/dev/null)"
    line="${line%$'\n'}"

    cmd="$(cron_command "$line")"

    case "$line" in
        *SCRIPT-MARKER*) ;;
        *) pass "tiers.sh:$lineno — no script argument to check"; continue ;;
    esac

    case "$cmd" in
        *SCRIPT-MARKER*)
            pass "tiers.sh:$lineno — the whole command survives crontab(5) parsing"
            ;;
        *)
            die "tiers.sh:$lineno — cron truncates this line before the command it is supposed to run
     installed: $line
     cron runs: $cmd"
            ;;
    esac

    # The jitter is the reason a `%` is in these lines at all. If a fix removes
    # the truncation by removing the jitter, that is a different change and this
    # says so rather than passing silently.
    # Must check for the CLOSING bound, not the word RANDOM: a line truncated at
    # `sleep $((RANDOM ` still contains RANDOM, so that weaker assertion passed
    # against the very bug this file was written for.
    case "$line" in
        *'$((RANDOM'*)
            case "$cmd" in
                *'120))'*) pass "tiers.sh:$lineno — the RANDOM jitter survives intact" ;;
                *) die "tiers.sh:$lineno — the jitter is cut mid-expression: $cmd" ;;
            esac
            ;;
    esac
done

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
