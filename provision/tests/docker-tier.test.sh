#!/usr/bin/env bash
# provision/tests/docker-tier.test.sh — unit tests for tier_docker in
# provision/lib/tiers.sh. No root, no network, no docker: the tier's four
# filesystem constants (DOCKER_TIER_*) point at a tmpdir and every external
# command it can reach is a PATH shim that records its argv.
#
# What this suite is really for: tier_docker rides in the WORKSTATION list, and
# that list is what every WSL dev distro converges on. The three branches that
# must never install a daemon (WSL, no-root, failed suite probe) are each a live
# case here, not a comment — a regression in any of them writes a broken apt
# source or fights Docker Desktop on a box in daily use.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TIERS="$REPO/provision/lib/tiers.sh"
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || bad "$3: expected '$2', got '$1'"; }
has()  { printf '%s\n' "$1" | grep -qF -- "$2" && pass "$3" || bad "$3"; }
hasnt(){ printf '%s\n' "$1" | grep -qF -- "$2" && bad "$3" || pass "$3"; }

# ── the tier's own source text ────────────────────────────────────────────────
body="$(awk '/^tier_docker\(\)/,/^}/' "$TIERS")"
whole="$(awk '/^_docker_packages\(\)/,/^tier_docker\(\)/' "$TIERS")$body"
# Comments stripped: the tier's prose deliberately NAMES the things it must not
# do (WSLInterop, `command -v docker`), so a grep over the comments would fail
# on exactly the file that documents itself best.
code="$(printf '%s\n' "$whole" | sed 's/[[:space:]]*#.*$//')"

# Absence is probed on dockerd, never on `docker`. Docker Desktop leaves a
# /usr/bin/docker symlink that outlives its target, so `command -v docker`
# succeeds on a box with no engine at all — the trap
# wsl_fixes_docker_needs_install already documents one layer down.
hasnt "$code" 'command -v docker' "tier_docker never probes \`command -v docker\`"
has   "$whole" 'DOCKER_TIER_DOCKERD' "tier_docker probes dockerd"

# WSL detection keys on /proc/version. $WSL_DISTRO_NAME is an extra OR and can
# never be the only signal: sshd does not set it, so a detached converge or a
# /ship over ssh reads it empty — and here that failure direction installs a
# daemon into the distro Docker Desktop serves.
has   "$whole" 'grep -qi microsoft /proc/version' "_docker_is_wsl reads /proc/version"
# NOT the binfmt handler: provision/wsl-fixes.sh exists because that handler
# goes missing, and a distro that has lost it is still a WSL distro.
hasnt "$code" 'WSLInterop' "_docker_is_wsl does not gate on the binfmt handler"

# The tier must never upgrade an existing engine: latitude runs immich on one,
# and `apt-get install -y docker-ce` against an older installed package would
# restart dockerd under an unattended converge.
has "$body" 'this tier never upgrades' "tier_docker states the never-upgrade contract"

# ── pure helpers ──────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
TIERS_LIB_ONLY=1 source "$TIERS"

pkgs="$(_docker_packages | tr '\n' ' ')"
eq "$pkgs" "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin " \
   "package set matches what latitude already runs"

eq "$(_docker_repo_line amd64 /k/d.asc debian trixie)" \
   "deb [arch=amd64 signed-by=/k/d.asc] https://download.docker.com/linux/debian trixie stable" \
   "repo line is distro-neutral (debian)"
eq "$(_docker_repo_line arm64 /k/d.asc ubuntu SUITE)" \
   "deb [arch=arm64 signed-by=/k/d.asc] https://download.docker.com/linux/ubuntu SUITE stable" \
   "repo line is distro-neutral (ubuntu)"
eq "$(_docker_release_url ubuntu SUITE)" \
   "https://download.docker.com/linux/ubuntu/dists/SUITE/Release" \
   "probe URL is the suite's Release file"

# No codename is written down anywhere in the tier — the probe is the authority
# on which suites Docker publishes, and a guessed codename in prose is the
# stale-fact pattern AGENTS.md keeps catching itself on.
hasnt "$code" 'resolute' "tier_docker hardcodes no codename (resolute)"
hasnt "$code" 'trixie'   "tier_docker hardcodes no codename (trixie)"
hasnt "$code" 'noble'    "tier_docker hardcodes no codename (noble)"

WSL_DISTRO_NAME=x _docker_is_wsl && pass "_docker_is_wsl honours WSL_DISTRO_NAME" \
  || bad "_docker_is_wsl must accept WSL_DISTRO_NAME as an extra signal"

# ── live branch tests ─────────────────────────────────────────────────────────
# The tier's first guard is `have apt-get`, so on macOS everything below reduces
# to that skip. Assert it there and stop rather than pretending to test more.
info() { printf 'info %s\n' "$*"; }
ok()   { printf 'ok %s\n' "$*"; }
warn() { printf 'warn %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
PRIV=1; SUDO=""

if ! command -v apt-get >/dev/null 2>&1; then
  out="$(tier_docker 2>&1)"; rc=$?
  eq "$rc" "0" "no apt-get: tier_docker returns 0"
  has "$out" "no apt-get" "no apt-get: tier_docker says so and skips"
  [ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
fi

SHIM="$(mktemp -d)"; LOG="$SHIM/calls"; : > "$LOG"
for c in apt-get usermod systemctl dpkg getent id curl; do
  cat > "$SHIM/$c" <<SH
#!/bin/sh
printf '%s %s\n' "$c" "\$*" >> "$LOG"
case "$c" in
  dpkg)   [ "\$1" = "--print-architecture" ] && { echo amd64; exit 0; } ;;
  getent) exit "\${SHIM_GETENT_RC:-0}" ;;
  id)     case "\$1" in -nG) echo "\$2 sudo" ;; -un) echo shimuser ;; esac; exit 0 ;;
  curl)   out=""; prev=""; kind=""
          for a in "\$@"; do
            [ "\$prev" = "-o" ] && out="\$a"
            case "\$a" in
              */dists/*/Release) kind=probe ;;
              */gpg)             kind=key ;;
            esac
            prev="\$a"
          done
          case "\$kind" in
            probe) exit "\${SHIM_PROBE_RC:-0}" ;;
            key)   [ "\${SHIM_KEY_RC:-0}" = 0 ] || exit "\${SHIM_KEY_RC}"
                   if [ -n "\$out" ]; then printf 'FAKE-KEY\n' > "\$out"; else printf 'FAKE-KEY\n'; fi
                   exit 0 ;;
          esac
          exit 0 ;;
  systemctl) [ "\$1" = "is-enabled" ] && exit 1 ;;
esac
exit 0
SH
  chmod +x "$SHIM/$c"
done
export PATH="$SHIM:$PATH"

# `_docker_is_wsl` is the thing under test in Case A; for every other case it is
# overridden, because this suite has to give the same verdict on a WSL distro
# (where the real predicate is true) and on latitude (where it is false).
reset() {
  : > "$LOG"
  rm -rf "$SHIM/etc"; mkdir -p "$SHIM/etc"
  DOCKER_TIER_KEYRING="$SHIM/etc/docker.asc"
  DOCKER_TIER_LIST="$SHIM/etc/docker.list"
  DOCKER_TIER_DOCKERD="$SHIM/etc/dockerd-absent"
  PRIV=1; SUDO=""
  unset SHIM_PROBE_RC SHIM_GETENT_RC SHIM_KEY_RC
  SUDO_USER=testuser
}
calls() { cut -d' ' -f1 "$LOG" | sort -u | tr '\n' ' '; }

# Case A — a WSL distro. Docker Desktop owns the engine and wsl-fixes.sh owns
# the CLI behind a dpkg-divert; a dockerd here fights both.
reset
_docker_is_wsl() { return 0; }
out="$(tier_docker 2>&1)"; rc=$?
eq "$rc" "0" "WSL: returns 0"
has "$out" "wsl-fixes.sh" "WSL: names the script that owns the CLI there"
eq "$(calls)" "" "WSL: runs NOTHING — no apt, no curl, no usermod"
[ -e "$DOCKER_TIER_LIST" ] && bad "WSL: must write no apt source" || pass "WSL: writes no apt source"

# Case B — no reachable root (a detached converge on a box needing an
# interactive sudo password). Same warn-and-skip contract as the apt tiers, and
# it must come BEFORE any network work.
reset
_docker_is_wsl() { return 1; }
PRIV=0
out="$(tier_docker 2>&1)"; rc=$?
eq "$rc" "0" "PRIV=0: returns 0"
eq "$(calls)" "" "PRIV=0: no network, no apt"

# Case C — Docker publishes no such suite (a brand-new distro release), or the
# probe has no network. THE highest-consequence branch: a sources.list.d entry
# naming a missing suite makes every later apt-get update fail, hence every
# later tier and every converge run on the box.
reset
PRIV=1
printf 'PRE-EXISTING\n' > "$DOCKER_TIER_LIST"
SHIM_PROBE_RC=22 out="$(SHIM_PROBE_RC=22 tier_docker 2>&1)"; rc=$?
eq "$rc" "0" "probe fails: returns 0"
eq "$(cat "$DOCKER_TIER_LIST")" "PRE-EXISTING" "probe fails: leaves an existing list byte-identical"
hasnt "$(calls)" "apt-get" "probe fails: never runs apt"
[ -e "$DOCKER_TIER_KEYRING" ] && bad "probe fails: must not install the key" \
  || pass "probe fails: installs no key"

# Case D — the fresh install. The list content must be exactly what
# _docker_repo_line renders from THIS box's os-release, and the index refresh is
# unconditional: a new source file cannot be in the cached index.
reset
out="$(tier_docker 2>&1)"; rc=$?
eq "$rc" "0" "fresh install: returns 0"
want="$(_docker_repo_line "amd64" "$DOCKER_TIER_KEYRING" \
  "$(. /etc/os-release && printf '%s' "$ID")" \
  "$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")")"
eq "$(cat "$DOCKER_TIER_LIST" 2>/dev/null)" "$want" "fresh install: list line matches the helper"
has "$(cat "$DOCKER_TIER_KEYRING" 2>/dev/null)" "FAKE-KEY" "fresh install: keyring written"
has "$(cat "$LOG")" "apt-get update" "fresh install: refreshes the index"
for p in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
  has "$(grep '^apt-get install' "$LOG")" "$p" "fresh install: installs $p"
done
has "$(cat "$LOG")" "usermod -aG docker testuser" "fresh install: grants the docker group to SUDO_USER"

# Case E — an engine already present. This is latitude every converge: the tier
# must not run apt AT ALL, while still converging the group and the unit.
reset
printf '#!/bin/sh\n' > "$SHIM/etc/dockerd-here"; chmod +x "$SHIM/etc/dockerd-here"
DOCKER_TIER_DOCKERD="$SHIM/etc/dockerd-here"
out="$(tier_docker 2>&1)"; rc=$?
eq "$rc" "0" "engine present: returns 0"
hasnt "$(calls)" "apt-get" "engine present: runs NO apt (never upgrades)"
[ -e "$DOCKER_TIER_LIST" ] && bad "engine present: must not rewrite the apt source" \
  || pass "engine present: leaves the apt source alone"
has "$(cat "$LOG")" "usermod -aG docker testuser" "engine present: still converges the group"
has "$(cat "$LOG")" "systemctl enable --now docker.service" "engine present: still converges the unit"

# Case F — a hand-run `sudo bash linux.sh` with no SUDO_USER. Adding root to the
# docker group is useless and confusing, so the grant must be skipped.
reset
printf '#!/bin/sh\n' > "$SHIM/etc/dockerd-here"; chmod +x "$SHIM/etc/dockerd-here"
DOCKER_TIER_DOCKERD="$SHIM/etc/dockerd-here"
SUDO_USER=root
out="$(tier_docker 2>&1)"; rc=$?
eq "$rc" "0" "root: returns 0"
hasnt "$(cat "$LOG")" "usermod" "root: never adds root to the docker group"

# Case G — the docker group does not exist (the install was skipped upstream).
# usermod must not be called with a group that is not there.
reset
printf '#!/bin/sh\n' > "$SHIM/etc/dockerd-here"; chmod +x "$SHIM/etc/dockerd-here"
DOCKER_TIER_DOCKERD="$SHIM/etc/dockerd-here"
out="$(SHIM_GETENT_RC=2 tier_docker 2>&1)"; rc=$?
eq "$rc" "0" "no docker group: returns 0"
hasnt "$(cat "$LOG")" "usermod" "no docker group: no usermod"

# Case H — the suite exists but the KEY fetch fails (404, or a mid-fetch drop).
# The mirror of Case C, and the reason the tier fetches to a temp file instead
# of `curl … | $SUDO tee "$keyring"`: the driver runs without pipefail, so a
# pipeline's status is tee's, and a failed fetch would report success and go on
# to write docker.list against an unusable key — leaving the box with a docker
# source that breaks every later apt-get update, which is exactly what Case C
# exists to prevent.
reset
out="$(SHIM_KEY_RC=22 tier_docker 2>&1)"; rc=$?
eq "$rc" "0" "key fetch fails: returns 0"
has "$out" "cannot fetch the docker apt key" "key fetch fails: says so"
[ -e "$DOCKER_TIER_LIST" ] && bad "key fetch fails: must write NO apt source" \
  || pass "key fetch fails: writes no apt source"
[ -s "$DOCKER_TIER_KEYRING" ] && bad "key fetch fails: must leave no keyring" \
  || pass "key fetch fails: leaves no keyring"
hasnt "$(calls)" "apt-get" "key fetch fails: never runs apt"

rm -rf "$SHIM"
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
