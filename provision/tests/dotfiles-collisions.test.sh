#!/usr/bin/env bash
# provision/tests/dotfiles-collisions.test.sh — the dotfiles role's checkout guard.
#
# provision/roles/dotfiles.sh backs up untracked $HOME files that sit at tracked
# paths, because the collision is structural rather than rare: `gh` writes
# ~/.config/gh/config.yml in tier_apt_dev, which runs BEFORE the dotfiles role, so
# every freshly provisioned box hits it (air 2026-07-28, latitude 2026-07-29).
#
# It also covers the role's other unattended-failure guard: the clone must never
# sit at ssh's host-key prompt (see the last section).
#
# This suite builds a REAL bare repo with a REAL work-tree in a temp directory and
# points $HOME at it. Nothing here touches the live $HOME, the live ~/.dotfiles, or
# the network — but the git behaviour being relied on (an empty index after a bare
# clone, refusal to overwrite untracked files) is the genuine article, which is the
# whole point: the guard exists to satisfy git, not a mock of it.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAIL=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (want '$2', got '$1')"; fi; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2' in '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail "$3 (unexpected '$2')" ;; *) pass "$3" ;; esac; }
# Path predicates get their own helpers rather than `[ -e x ]; eq "$?"`: the inline
# form is correct but trips shellcheck's SC2319 on every use.
exists() { if [ -e "$1" ]; then pass "$2"; else fail "$2 (missing $1)"; fi; }
absent() { if [ -e "$1" ] || [ -L "$1" ]; then fail "$2 (unexpected $1)"; else pass "$2"; fi; }
# A dangling symlink is present-but-unreadable: `-e` is false for it, `-L` true.
# The whole point of the case below is that the two differ, so the helper that
# asserts presence must not be written with `-e` alone.
is_link() { if [ -L "$1" ]; then pass "$2"; else fail "$2 (not a symlink: $1)"; fi; }

command -v git >/dev/null 2>&1 || { echo 'SKIP: no git'; exit 0; }

# shellcheck source=provision/roles/dotfiles.sh
source "$REPO/provision/roles/dotfiles.sh"

# ── _dotfiles_key_material (pure) ─────────────────────────────────────────────
for p in .ssh/id_ed25519 .ssh/id_rsa.pub .gnupg/pubring.kbx .secrets/token \
  .config/foo.pem certs/server.key .password-store/x.gpg; do
  _dotfiles_key_material "$p"; eq "$?" '0' "key material: $p is refused"
done
for p in .config/gh/config.yml .ssh/config .gitconfig .netrc .bashrc \
  .config/keyring/settings.ini; do
  _dotfiles_key_material "$p"; eq "$?" '1' "key material: $p is NOT key material"
done
# .ssh/config lives next to the keys and IS tracked on purpose; a pattern broad
# enough to catch it would break the setup this role exists to deploy.
_dotfiles_key_material .ssh/known_hosts; eq "$?" '1' 'key material: .ssh/known_hosts is fine'

# ── Fixture: a bare "remote" with one branch, cloned bare into a temp $HOME ────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
UPSTREAM="$TMP/upstream.git"
SEED="$TMP/seed"

git init --quiet --bare -b main "$UPSTREAM"
git clone --quiet "$UPSTREAM" "$SEED" 2>/dev/null
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
mkdir -p "$SEED/.config/gh" "$SEED/.ssh"
printf 'version: 1\n'        > "$SEED/.config/gh/config.yml"
printf 'export A=1\n'        > "$SEED/.bashrc"
printf 'Host x\n'            > "$SEED/.ssh/config"
git -C "$SEED" add -A >/dev/null
git -C "$SEED" commit --quiet -m seed
git -C "$SEED" push --quiet origin main 2>/dev/null

GITDIR="$HOME/.dotfiles"
git clone --quiet --bare "$UPSTREAM" "$GITDIR"
git --git-dir="$GITDIR" --work-tree="$HOME" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git --git-dir="$GITDIR" --work-tree="$HOME" fetch --quiet origin

# The pre-existing state a real box arrives in: gh already wrote its config, and
# an unrelated file that the repo does not track sits alongside it.
mkdir -p "$HOME/.config/gh"
printf 'version: 1\n# a newer gh comment\n' > "$HOME/.config/gh/config.yml"
printf 'untracked\n'                        > "$HOME/.config/gh/hosts.yml"

# ...and a DANGLING symlink at another tracked path. This is not a contrived
# case: g15-wsl arrived on 2026-08-27 with ~/.claude full of links into
# /mnt/c/.../GitHub/nix/claude, a layout deleted with the NixOS tree. `-e`
# follows symlinks and so tests FALSE here, while git lstat()s and refuses the
# checkout — so the collision was invisible to the guard and the role failed
# with "checkout refused" having moved nothing.
ln -s "$TMP/target-that-does-not-exist" "$HOME/.bashrc"

# ── _dotfiles_collisions ──────────────────────────────────────────────────────
OUT="$(_dotfiles_collisions "$GITDIR" refs/remotes/origin/main)"
has "$OUT" '.config/gh/config.yml' 'collisions: reports the file that exists in $HOME'
has "$OUT" '.bashrc'               'collisions: reports a DANGLING symlink at a tracked path'
hasnt "$OUT" '.ssh/config'         'collisions: does not report a tracked path absent from $HOME'
hasnt "$OUT" 'hosts.yml'           'collisions: does not report an untracked file at an untracked path'
eq "$(printf '%s\n' "$OUT" | grep -c .)" '2' 'collisions: exactly two collisions'

# ── _dotfiles_backup_collisions, then the checkout git previously refused ──────
# The premise first: without the guard, this is the failure every fresh box hits.
# Asserting it here means the suite fails if a future git ever stops refusing —
# at which point the whole backup pass is dead weight and should go.
git --git-dir="$GITDIR" --work-tree="$HOME" checkout --quiet -B main --track origin/main 2>/dev/null
eq "$?" '1' 'premise: git refuses the checkout while the collision stands'

OUT="$(_dotfiles_backup_collisions "$GITDIR" refs/remotes/origin/main 2>&1)"; rc=$?
eq "$rc" '0' 'backup: succeeds'
has "$OUT" '.pre-dotfiles' 'backup: names the backup it made'
exists "$HOME/.config/gh/config.yml.pre-dotfiles" 'backup: the original content is preserved at *.pre-dotfiles'
has "$(cat "$HOME/.config/gh/config.yml.pre-dotfiles")" 'a newer gh comment' \
  'backup: the backup holds the LOCAL content, not the repo content'
absent "$HOME/.config/gh/config.yml" 'backup: the tracked path is now free for git'
exists "$HOME/.config/gh/hosts.yml" 'backup: an untracked path is left alone'
is_link "$HOME/.bashrc.pre-dotfiles" 'backup: the dangling symlink was moved aside, not deleted'
absent "$HOME/.bashrc" 'backup: the dangling symlink no longer occupies the tracked path'

git --git-dir="$GITDIR" --work-tree="$HOME" checkout --quiet -B main --track origin/main 2>/dev/null
eq "$?" '0' 'checkout: git accepts it once the collisions are cleared'
has "$(cat "$HOME/.config/gh/config.yml")" 'version: 1' 'checkout: the repo content landed'

# Second run: the index now matches, so there is nothing to move.
OUT="$(_dotfiles_backup_collisions "$GITDIR" refs/remotes/origin/main 2>&1)"; rc=$?
eq "$rc" '0' 'backup: a second run succeeds'
hasnt "$OUT" '.pre-dotfiles' 'backup: a second run moves nothing (index matches the tree)'

# ── Refusals ──────────────────────────────────────────────────────────────────
# A taken backup name is the one real data-loss path: clobbering it would destroy
# the FIRST run's rescue copy, so the guard must refuse instead of overwriting.
rm -f "$HOME/.bashrc"
printf 'local\n' > "$HOME/.bashrc"
printf 'older\n' > "$HOME/.bashrc.pre-dotfiles"
git --git-dir="$GITDIR" --work-tree="$HOME" rm --quiet --cached .bashrc >/dev/null 2>&1
OUT="$(_dotfiles_backup_collisions "$GITDIR" refs/remotes/origin/main 2>&1)"; rc=$?
eq "$rc" '1' 'refusal: an existing backup fails the whole checkout'
has "$OUT" 'already exists' 'refusal: says why'
eq "$(cat "$HOME/.bashrc.pre-dotfiles")" 'older' 'refusal: the existing backup is untouched'
eq "$(cat "$HOME/.bashrc")" 'local' 'refusal: the live file is untouched too'

# Key material: never moved, whatever the tree says. Verified through the same
# entry point rather than the pattern alone, because the ordering of the two
# guards is what decides whether ~/.ssh/id_ed25519 survives a provision run.
rm -f "$HOME/.bashrc.pre-dotfiles"
git -C "$SEED" pull --quiet 2>/dev/null
printf 'PRIVATE KEY\n' > "$SEED/.ssh/id_ed25519"
git -C "$SEED" add -A >/dev/null 2>&1
git -C "$SEED" commit --quiet -m keys 2>/dev/null
git -C "$SEED" push --quiet origin main 2>/dev/null
git --git-dir="$GITDIR" --work-tree="$HOME" fetch --quiet origin
mkdir -p "$HOME/.ssh"
printf 'MY REAL KEY\n' > "$HOME/.ssh/id_ed25519"
OUT="$(_dotfiles_backup_collisions "$GITDIR" refs/remotes/origin/main 2>&1)"; rc=$?
eq "$rc" '1' 'refusal: key material in the tree fails the checkout'
has "$OUT" 'key material' 'refusal: says it is key material'
eq "$(cat "$HOME/.ssh/id_ed25519")" 'MY REAL KEY' 'refusal: the live private key is untouched'
absent "$HOME/.ssh/id_ed25519.pre-dotfiles" 'refusal: no copy of the private key was made either'

# ── The upstream fix (the other half of the 2026-07-29 gap) ───────────────────
# `git clone --bare` materialises every remote head as a LOCAL branch, so the
# role's first arm checks out an existing ref — and `checkout <branch>` sets no
# upstream, leaving `git pull` broken while the sync timer still works.
git --git-dir="$GITDIR" rev-parse --verify --quiet refs/heads/main >/dev/null
eq "$?" '0' 'clone --bare: the branch already exists locally (why the arm is taken)'
grep -q 'set-upstream-to="origin/\$branch"' "$REPO/provision/roles/dotfiles.sh"
eq "$?" '0' 'role: sets the branch upstream after checkout'

git --git-dir="$GITDIR" --work-tree="$HOME" branch --quiet --set-upstream-to=origin/main main >/dev/null 2>&1
eq "$(git --git-dir="$GITDIR" rev-parse --abbrev-ref 'main@{upstream}' 2>/dev/null)" 'origin/main' \
  'upstream: the command the role runs does resolve an upstream'

# --- The clone must never sit at ssh's host-key prompt -----------------------
# A fresh box has no github.com in known_hosts, so ssh asks the operator to
# confirm the host key. Provisioning has no TTY: the prompt is never answered and
# never times out, so the run HANGS instead of failing. On g15-wsl 2026-08-27 the
# clone sat for 12 minutes and read as a network stall.
#
# Behavioural, not a grep: a PATH-shimmed `git` records the environment it was
# handed and exits nonzero, which returns the role at the clone line before any
# other git call is reached. $HOME points at an empty dir so the `[ ! -d $gitdir ]`
# arm is the one taken.
SHIM="$TMP/shim"; CLONE_LOG="$TMP/clone-env"; CLONE_HOME="$TMP/clone-home"
mkdir -p "$SHIM" "$CLONE_HOME"
cat > "$SHIM/git" <<EOS
#!/usr/bin/env bash
{
  echo "argv=\$*"
  echo "GIT_SSH_COMMAND=\${GIT_SSH_COMMAND-<unset>}"
  echo "GIT_TERMINAL_PROMPT=\${GIT_TERMINAL_PROMPT-<unset>}"
} > "$CLONE_LOG"
exit 128
EOS
chmod +x "$SHIM/git"

# `env -u` both variables first: a developer shell can already carry
# GIT_TERMINAL_PROMPT=0, and inheriting it would make the assertion below pass
# without the role setting anything (it did, on the box this was written on).
# Sourcing into a fresh bash is what makes that clearing reachable at all.
OUT="$(env -u GIT_SSH_COMMAND -u GIT_TERMINAL_PROMPT HOME="$CLONE_HOME" PATH="$SHIM:$PATH" \
  bash -c 'source "$1"; role_dotfiles apply debian g15' _ "$REPO/provision/roles/dotfiles.sh" 2>&1)"; rc=$?
eq "$rc" '1' 'clone: a failing clone fails the role'
ENVLOG="$(cat "$CLONE_LOG" 2>/dev/null)"
has "$ENVLOG" 'argv=clone' 'clone: the shim intercepted the clone'
has "$ENVLOG" 'BatchMode=yes' \
  'clone: BatchMode=yes - a prompt becomes an exit code instead of a hang'
has "$ENVLOG" 'StrictHostKeyChecking=accept-new' \
  'clone: accept-new - a FIRST-time host key still passes unattended'
has "$ENVLOG" 'GIT_TERMINAL_PROMPT=0' "clone: git's own credential prompt is off too"
# The three causes now share one exit code, so the message has to separate them.
has "$OUT" 'host key CHANGED' 'clone: the failure names the changed-host-key cause'

# A caller's own GIT_SSH_COMMAND wins - that override is how a box with a
# non-default key path gets through, and it is what unblocked g15-wsl by hand.
env HOME="$CLONE_HOME" PATH="$SHIM:$PATH" GIT_SSH_COMMAND='ssh -i /custom/key' \
  bash -c 'source "$1"; role_dotfiles apply debian g15' _ "$REPO/provision/roles/dotfiles.sh" >/dev/null 2>&1
has "$(cat "$CLONE_LOG")" 'ssh -i /custom/key' 'clone: an explicit GIT_SSH_COMMAND is honoured'

# ...and it must not leak into the caller's environment: `local -x`, not `export`.
# An exported GIT_SSH_COMMAND would silently retune every later git call in the
# provision run, including tier_selfpull's pulls of unrelated repos.
# Behavioural, because the grep below only tests that the source LOOKS right:
# read the variable back in the caller after the role returns. PATH=/nonexistent
# makes git unresolvable, so the role fails at the clone without a shim.
LEAK="$(env -u GIT_SSH_COMMAND HOME="$TMP/leak-home" bash -c '
  source "$1"
  mkdir -p "$HOME"
  PATH=/nonexistent role_dotfiles apply debian g15 >/dev/null 2>&1
  printf "%s" "${GIT_SSH_COMMAND-<unset>}"' _ "$REPO/provision/roles/dotfiles.sh")"
eq "$LEAK" '<unset>' 'clone: GIT_SSH_COMMAND does not survive the role returning'
grep -q 'local -x GIT_SSH_COMMAND' "$REPO/provision/roles/dotfiles.sh"
eq "$?" '0' 'clone: ...because it is declared local -x, not exported'

# The Windows executor clones over the same ssh and prompts identically, so the
# posix fix alone would leave `desktop` and `g15` hanging on a fresh provision.
PS1_SRC="$(cat "$REPO/provision/roles/dotfiles.ps1")"
has "$PS1_SRC" 'BatchMode=yes' 'ps1: the Windows executor sets the same non-interactive posture'
has "$PS1_SRC" 'StrictHostKeyChecking=accept-new' 'ps1: ...including accept-new'

bash -n "$REPO/provision/roles/dotfiles.sh"; eq "$?" '0' 'role: syntax is valid'

if [ "$FAIL" -gt 0 ]; then printf 'FAILURES: %d\n' "$FAIL" >&2; exit 1; fi
printf 'PASS: %s\n' "$(basename "${BASH_SOURCE[0]}")"
