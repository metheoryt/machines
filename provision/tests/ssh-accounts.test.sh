#!/usr/bin/env bash
# Unit tests for tier_ssh_accounts (provision/lib/tiers.sh) — the multi-account
# GitHub story: one SSH key per account, one Host alias per key, and a per-account
# commit identity keyed on the remote URL.
#
# Runs the REAL tier against a throwaway $HOME so it exercises the actual
# ssh-keygen + git-config writes rather than a re-implementation. No network.
#
# Why this suite exists: the two failure modes here are both SILENT.
#   1. A key on the wrong account still authenticates — as the wrong person.
#      Both aliases resolve to HostName github.com, so GitHub picks the account
#      purely from the offered key; nothing errors.
#   2. The commit identity is keyed on the ALIAS STRING inside the includeIf
#      ("hasconfig:remote.*.url:git@<alias>:*/**"). Rename an alias without
#      updating GIT_IDENTITIES and every repo cloned through it silently authors
#      as the default account instead.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../.." && pwd)"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
has()  { printf '%s\n' "$1" | grep -qE "$2" && pass "$3" || die "$3"; }
hasnt(){ printf '%s\n' "$1" | grep -qE "$2" && die "$3" || pass "$3"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Drive the tier with the driver contract the tier library expects, a fake HOME,
# and NO XDG_CONFIG_HOME — git --global honours $XDG_CONFIG_HOME/git/config when
# set, so a leaked XDG would defeat the HOME override and hijack the write.
run_tier() {
  env -u XDG_CONFIG_HOME HOME="$TMP" bash -c '
    REPO="$1"
    info(){ :; }; ok(){ :; }; warn(){ printf "WARN %s\n" "$*" >&2; }
    die(){ printf "DIE %s\n" "$*" >&2; exit 1; }
    have(){ command -v "$1" >/dev/null 2>&1; }
    WARNINGS=0; SUDO=""; PRIV=1; APT_UPDATED=""
    TIERS_LIB_ONLY=1 source "$REPO/provision/lib/tiers.sh"
    tier_ssh_accounts
  ' _ "$REPO" 2>&1
}

out="$(run_tier)"
CFG="$TMP/.ssh/config"
[ -f "$CFG" ] && pass "writes ~/.ssh/config" || die "no ~/.ssh/config written"
cfg="$(cat "$CFG" 2>/dev/null || true)"

# ── Keys: one per ACCOUNT, not one per alias ───────────────────────────────────
# The key path derives from the github user (id_<user>), so several aliases can
# share one account's key. If this ever became per-alias, `github.com` and
# `metheoryt.github.com` would mint two unrelated keys for one account and only
# one of them would be registered.
[ -f "$TMP/.ssh/id_metheoryt" ] && pass "generates ~/.ssh/id_metheoryt" || die "no id_metheoryt"
[ -f "$TMP/.ssh/id_cyphy671" ]  && pass "generates ~/.ssh/id_cyphy671"  || die "no id_cyphy671"
n_keys="$(find "$TMP/.ssh" -maxdepth 1 -name 'id_*' ! -name '*.pub' | wc -l | tr -d ' ')"
[ "$n_keys" = 2 ] && pass "exactly 2 keys for 3 aliases (key is per-account)" \
  || die "expected 2 private keys, got $n_keys"

# ── Aliases ───────────────────────────────────────────────────────────────────
# `github.com` MUST stay: it is what the GitHub clone button, `gh repo clone`,
# READMEs and submodule URLs all emit. Without this block those clones fall back
# to default key order instead of a pinned identity.
has "$cfg" '^Host github\.com$'           "canonical Host github.com is present"
has "$cfg" '^Host metheoryt\.github\.com$' "readable alias metheoryt.github.com is present"
has "$cfg" '^Host cyphy671\.github\.com$'  "readable alias cyphy671.github.com is present"

# The retired alias must be gone — kept as an assertion so a revert is loud.
hasnt "$cfg" '^Host github-cyphy$' "the retired github-cyphy alias is absent"

# Every alias points at github.com and pins exactly one key. IdentitiesOnly is
# what makes account resolution deterministic: without it ssh offers every key it
# knows and GitHub answers as whichever one happens to match first.
n_hostname="$(grep -c '^    HostName github.com$' "$CFG")"
[ "$n_hostname" = 3 ] && pass "all 3 aliases set HostName github.com" \
  || die "expected 3 HostName lines, got $n_hostname"
n_only="$(grep -c '^    IdentitiesOnly yes$' "$CFG")"
[ "$n_only" = 3 ] && pass "all 3 aliases set IdentitiesOnly yes" \
  || die "expected 3 IdentitiesOnly lines, got $n_only"

# Each alias pins the key belonging to ITS account.
awk '/^Host /{h=$2} /IdentityFile/{print h" "$2}' "$CFG" > "$TMP/pairs"
grep -qx 'github.com ~/.ssh/id_metheoryt' "$TMP/pairs" \
  && pass "github.com pins id_metheoryt" || die "github.com does not pin id_metheoryt"
grep -qx 'metheoryt.github.com ~/.ssh/id_metheoryt' "$TMP/pairs" \
  && pass "metheoryt.github.com pins id_metheoryt" || die "metheoryt.github.com mispinned"
grep -qx 'cyphy671.github.com ~/.ssh/id_cyphy671' "$TMP/pairs" \
  && pass "cyphy671.github.com pins id_cyphy671" || die "cyphy671.github.com mispinned"

# A freshly generated key nobody registered yet must say so — an unregistered key
# behind IdentitiesOnly breaks every clone/push through that alias.
has "$out" 'register id_' "warns that new keys need registering on GitHub"

# 0600 or ssh refuses the file outright.
perm="$(stat -c '%a' "$CFG" 2>/dev/null || stat -f '%Lp' "$CFG" 2>/dev/null)"
[ "$perm" = 600 ] && pass "config is 0600" || die "config perms are $perm"

# ── Commit identity ───────────────────────────────────────────────────────────
# Keyed on the remote URL, so it must name the CURRENT alias. A stale alias here
# is the silent-misattribution bug this file's header describes.
gc="$(cat "$TMP/.gitconfig" 2>/dev/null || true)"
has "$gc" 'remote\.\*\.url:git@cyphy671\.github\.com:\*/\*\*' \
  "includeIf keys off the cyphy671.github.com remote URL"
hasnt "$gc" 'git@github-cyphy:' "no includeIf left pointing at the retired alias"
has "$gc" 'identity-cyphy671\.github\.com' "includeIf points at the alias-named identity file"

idf="$TMP/.config/git/identity-cyphy671.github.com"
[ -f "$idf" ] && pass "writes the cyphy671 identity file" || die "no identity file at $idf"
idc="$(cat "$idf" 2>/dev/null || true)"
has "$idc" 'name = cyphy671' "identity carries the cyphy671 author name"
# GitHub's private noreply form, so a real address never leaks and pushes are not
# rejected by "keep my email address private".
has "$idc" 'email = [0-9]+\+cyphy671@users\.noreply\.github\.com' \
  "identity uses the private noreply email"

# ── Idempotence ───────────────────────────────────────────────────────────────
# The tier replaces its marked block and re-adds the includeIf only if absent;
# a re-run must not duplicate either.
run_tier >/dev/null
cfg2="$(cat "$CFG")"
[ "$(printf '%s\n' "$cfg2" | grep -c '^Host cyphy671\.github\.com$')" = 1 ] \
  && pass "re-run does not duplicate alias blocks" || die "re-run duplicated alias blocks"
gc2="$(cat "$TMP/.gitconfig" 2>/dev/null || true)"
[ "$(printf '%s\n' "$gc2" | grep -c 'identity-cyphy671\.github\.com')" = 1 ] \
  && pass "re-run does not duplicate the includeIf" || die "re-run duplicated the includeIf"
printf '%s\n' "$(run_tier)" | grep -q 'register id_' \
  && die "re-run re-warned about registration despite existing keys" \
  || pass "re-run reuses existing keys silently"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
