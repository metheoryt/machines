# Dotfiles: private bare repo, branch-per-machine — design spec

**Date:** 2026-07-28
**Status:** approved in brainstorming, not yet implemented
**Supersedes:** `2026-07-08-fleet-provisioner-phase3-dotfiles-chezmoi-design.md`

## 1. Goal & scope

Make `metheoryt/dotfiles` (private, bare-repo technique) the **single** engine for
`$HOME` configuration across the fleet, with a branch per machine, automatic
sync, and an explicit promote step. Retire chezmoi entirely.

**In scope:** branch/identity model; the derived shared-vs-host rule; the sync
timer; the `promote` command; the proactive tracking-offer hook; the rewrite of
the `dotfiles` provision role; migration off chezmoi.

**Out of scope (each deserves its own brainstorm):**

- **NixOS retirement.** Decided in principle 2026-07-28 — one machine, high
  support cost, no felt upside. Collides with Phase C of
  `2026-07-27-fleet-migration-mac-primary-latitude-server.md`, which has
  `latitude` staying NixOS as the always-on services host. This spec is
  deliberately built so that retirement requires **no rework** here (see §7).
- **Claude profile retirement.** Decided in principle 2026-07-28 — profile
  switching is already auth-only (it swaps `~/.claude/.credentials.json` +
  `~/.claude.json`'s `oauthAccount`, not the config dir), and only one profile
  is committed today. One open question gates it: whether `enabledPlugins` is
  honored in a **project-scope** `.claude/settings.json`. Probe before designing.
- **age-encrypted secrets.** A private repo is the answer to secrets for now.

## 2. Why not chezmoi (reversing the 2026-07-08 decision)

The Phase 3 spec chose `machines/dotfiles/` as the chezmoi source, reasoning
"one source of truth, synced by the same `git pull`". That reasoning holds only
while dotfiles carry no secrets.

`metheoryt/machines` is **PUBLIC**; `metheoryt/dotfiles` is **PRIVATE**. Tracking
credentials requires a private home, and the Phase 3 answer to that
(age-encryption, deferred) was never built. A private repo is the simpler
solution to the same problem.

Second reason: the chezmoi role is a **no-op on NixOS** by design, so it never
covered the whole fleet. The bare-repo technique works identically everywhere.

## 3. Decisions

| # | Decision |
|---|---|
| D1 | Single engine: private `metheoryt/dotfiles`, bare repo, work-tree `$HOME`. chezmoi retired. |
| D2 | Branch per machine, branched from `main`, named by **logical fleet name** (not OS hostname). |
| D3 | Tracked-or-not = the existing **allow-only `.gitignore`**. Unchanged. |
| D4 | Shared-or-host = **derived from git**, not stored. On `main` ⇒ shared; absent ⇒ host-local. No routing manifest. |
| D5 | **Invariant: a path is shared XOR host-local.** Never both. No per-host overrides of a shared path. |
| D6 | Autocommit always targets the **machine branch**. No decision at commit time. |
| D7 | Sync is **timer-driven** (10 min), reusing the `fleet-selfpull` idiom. Not a filesystem watcher. |
| D8 | `promote` is **manual and explicit**. Never automatic. |
| D9 | Secrets: **rotatable credentials yes, private keys never.** The `.gitignore` ban block stays. |
| D10 | A `PostToolUse` hook **proactively offers** to track a homeless `$HOME` file. Declines are **session-scoped**, no persisted state. |
| D11 | The `promote` skill lives in the **dotfiles repo** (`~/.claude/skills/dotfiles-promote/`), tracked on `main`. The sync script stays in `machines`. |

## 4. Architecture

### 4.1 Identity

Branch name = **logical fleet name**, resolved by the existing fleet identity
chain: `fleet.local.json` nickname if present (self-declared WSL hosts), else
`fleet.json` lookup by OS hostname.

| logical | OS hostname | branch |
|---|---|---|
| `latitude` | `latitude5520` | `latitude` — **rename** the existing `latitude5520` branch |
| `air` | `air` | `air` — new |
| `desktop` | `g614jv` | `desktop` |
| `server` | `g513ie` | `server` |
| `hub` | `27608` | `hub` |

Logical names are used because OS hostnames churn (`methe-server` → `g513ie`,
2026-07-20) and a rename would orphan the branch.

### 4.2 The two lists

**Tracked-or-not — the allow-only `.gitignore`** (already in the repo):

```gitignore
*                            # ignore everything; the work-tree is all of $HOME
!*/                          # descend into dirs so !rules below can match
!.gitignore !README.md !CLAUDE.md
!.ssh/config                 # one !line per tracked file
!.config/gh/config.yml
*.pem  id_ed25519*  .gnupg/  .aws/credentials    # ban block LAST, last-match-wins
```

plus `status.showUntrackedFiles = no`. Nothing is tracked unless explicitly
opted in — a stray `add -A` cannot leak an unlisted file.

**Shared-or-host — derived, not stored:**

```sh
dotfiles cat-file -e main:<path>   # exit 0 => on main => shared
                                   # non-zero => host-local
```

A stored manifest would be redundant with git and could desync. This cannot.

### 4.3 The invariant (D5)

A path is on `main` (shared, byte-identical everywhere) **or** on host branches
only (host-local). Never both. If any host needs different content at a path,
that path leaves `main` entirely and each host branch carries its own copy.

**Consequence — the NixOS collision resolves itself.** `modules/home/ssh.nix`
does not merely generate `~/.ssh/config`; it **deletes** an existing one on
activation:

```nix
if [ -e "$HOME/.ssh/config" ] && [ ! -L "$HOME/.ssh/config" ]; then
  $DRY_RUN_CMD rm -f "$HOME/.ssh/config"
```

and `programs.git` (`modules/home/me.nix:112`) owns `~/.gitconfig`. Under D5
those paths are simply host-local: allow-listed on non-Nix host branches, absent
from `latitude`'s branch and from `main`. No exclusion mechanism is needed. The
only rule this creates: **`promote` must warn before pushing a home-manager-owned
path to `main`** (§5.2), since every branch would then inherit it and `latitude`
would fight it on each `just switch`.

## 5. Components

### 5.1 `provision/dotfiles-sync.sh` (+ `.ps1` twin) — the timer

Lives in `machines` (public, tested, matches `fleet-selfpull`). Runs every
10 min, matching the deliberately-aligned `fleet-selfpull` / `git-autofetch`
cadence.

**Governing safety property:** the work-tree is `$HOME`. A conflicted merge
would write `<<<<<<<` markers into *live* `~/.ssh/config`, `~/.gitconfig`,
`~/.netrc` — breaking ssh and git, possibly including the ability to fix it
remotely. The script must never leave a conflict on disk, and must never start a
merge it cannot finish.

```sh
0. flock                    # overlapping ticks are a no-op, not a race
1. guard                    # ~/.dotfiles exists; no merge/rebase in progress;
                            # HEAD is on the expected logical branch.
                            # Wrong branch => STOP loudly, commit nothing.
2. commit  dotfiles add -u  # tracked modifications + deletions ONLY
           dotfiles commit -m "auto(<machine>): <paths, truncated>"
3. push    dotfiles push origin <machine>
                            # offline/auth failure is NON-fatal; retries next tick
4. fetch   dotfiles fetch origin main
5. preflight
           dotfiles merge-tree --write-tree <machine> origin/main
                            # computes the merge in the object store; touches NO
                            # working file. Conflict => marker + STOP, $HOME clean.
6. merge   dotfiles merge --ff origin/main      # only if preflight was clean
```

Step 5 is load-bearing: `merge-tree` detects a conflict *before* anything on
disk changes — strictly safer than merge-then-`--abort`, which writes markers
first and only then rolls back.

**Accepted behaviors:**

- **New files are invisible.** `add -u` never stages an untracked file and
  `showUntrackedFiles=no` hides it, so tracking stays a deliberate act. The
  offer-hook (§5.3) is what surfaces candidates instead.
- **Half-written saves get committed.** A tick can land mid-edit; the next tick
  commits the finished version, and promotion is manual so nothing half-baked
  reaches `main` unreviewed.

### 5.2 `~/.claude/skills/dotfiles-promote/SKILL.md` — promote

Tracked in the **dotfiles repo** on `main` (D11), so a clone+checkout delivers
it. Doubles as a worked example of tracking a `$HOME` path that is not a classic
dotfile. Note `~/.claude/skills/` is a real directory — `cyphy` is a symlink
*inside* it into `machines`, so a real tracked file sits beside it without
conflict.

It is a user-scope skill (`/dotfiles-promote`, not `/cyphy:dotfiles-promote`)
and arrives via checkout rather than plugin bootstrap.

**Never switch the `$HOME` work-tree.** The obvious implementation —
`dotfiles checkout main`, take files, switch back — would **delete every
host-local file from `$HOME`** for the duration, because those paths are tracked
on the machine branch and absent from `main`. An interrupted run leaves a
stripped `$HOME` with no ssh config. Instead, build `main` in a throwaway linked
worktree:

```sh
dotfiles worktree add /tmp/dotfiles-promote origin/main   # $HOME untouched
cd /tmp/dotfiles-promote
git checkout <machine> -- <selected paths>
git commit -m "promote from <machine>: <paths>"
git push origin main
cd - && dotfiles worktree remove /tmp/dotfiles-promote
dotfiles fetch origin main && dotfiles merge --ff origin/main
```

The final merge is always clean because both sides then hold byte-identical
content — which is why promote takes file *content* rather than cherry-picking
commits.

**What it presents**, both classes derived, no stored state:

| class | test | prompt |
|---|---|---|
| shared drift | on `main`, differs from branch | none — by D5 it belongs on `main`. Listed, applied. |
| host-only | tracked on branch, absent from `main` | asked per path: promote, or keep host-local |

Warn-list: `.ssh/config`, `.gitconfig` — home-manager-owned on `latitude` today
(§4.3). A warning, not a hard block; it becomes moot when NixOS goes.

`promote` also reports a standing sync-conflict marker, since that is when it
would be noticed.

### 5.3 `agents/plugin/hooks/dotfiles-offer.sh` — proactive tracking offers

`PostToolUse` on `Edit` / `Write` / `NotebookEdit`, in the `machines` plugin.
Emits a system-reminder surfaced as a non-blocking offer. Never a permission
prompt.

```sh
1. under $HOME?                                    no  -> silent
2. matches ban block (id_*, *.pem, .gnupg/, *.key) yes -> silent, ALWAYS
3. already tracked?                                yes -> silent
   dotfiles ls-files --error-unmatch <path>
4. inside another git repo?
     trackable there                               yes -> silent (belongs there)
     gitignored there                                  -> CANDIDATE
5. declined this session?                          yes -> silent
6. otherwise                                           -> OFFER
```

Step 4 is what catches the homeless case: `~/pure/backend-api/.claude/memory/project.md`
is inside a git repo but gitignored there (allowlist `.gitignore`), so it has no
home except dotfiles. A normal source file in that repo stays silent.

Accepting runs the documented two-step: append the `!path` line to `.gitignore`,
then `dotfiles add <path>`. It lands on the machine branch like everything else.

Declines are session-scoped and in-memory (D10) — no file, no sync. A repeatedly
declined path is re-offered in a later session; self-limiting in practice.

### 5.4 `provision/roles/dotfiles.{sh,ps1}` — rewritten

Role name and dispatcher registration survive; the engine swaps. The role now
runs on **all** platforms — it is currently a deliberate no-op on NixOS, and the
bare-repo technique has no reason to skip it.

Three jobs:

1. Clone the bare repo to `~/.dotfiles` (if absent); set
   `status.showUntrackedFiles no`.
2. Check out this host's branch, creating it from `main` if it does not exist.
3. Install the per-OS timer unit for `dotfiles-sync`.

**Timer wiring is a plain systemd *user* unit on Linux — not a Nix module** —
installed by the role, same code path as every other POSIX box. This works on
NixOS today and survives its retirement untouched. Precedent: `bootstrap.sh`
already deploys outside the nix generation deliberately. macOS uses the existing
`launchctl bootout`/`bootstrap` helpers in `provision/lib/tiers.sh`; Windows
uses `schtasks`, as `fleet-selfpull.ps1` does.

## 6. Failure modes

| failure | behavior |
|---|---|
| merge conflict | preflight catches it; `$HOME` untouched; marker at `~/.local/state/dotfiles-sync/conflict`; merging stops until resolved. Steps 2–3 keep running, so local work is never at risk of loss. |
| offline / auth failure on push | non-fatal; commit stays local, retried next tick |
| HEAD on the wrong branch | stop loudly, commit nothing — protects against a stray `checkout main` |
| overlapping timer ticks | `flock`; second tick is a no-op |
| `promote` interrupted mid-run | throwaway worktree is the only casualty; `$HOME` never changed |
| repo not cloned yet | role clones it; sync script exits silently if `~/.dotfiles` is absent |

## 7. Why this survives NixOS retirement with no rework

- The role already runs on every platform; removing NixOS removes a case, not a
  mechanism.
- The home-manager carve-out is expressed purely as "those paths aren't on
  `main`". If home-manager stops owning them, moving them to shared **is** the
  promote operation — already supported.
- The timer is a plain systemd user unit, not a Nix module. Nothing to tear out.

## 8. Testing

- `provision/tests/roles.test.sh` — currently asserts NixOS *deliberately*
  defers `dotfiles` to home-manager. **That assertion must be inverted:** NixOS
  now reaches a real arm.
- Sync script, against a scratch bare repo with `--destination`-style temp
  `$HOME`: clean tick is a no-op; dirty tick commits and pushes; conflicting
  `main` leaves the temp `$HOME` byte-identical and drops the marker; wrong
  branch exits non-zero having committed nothing.
- `merge-tree` preflight: assert no working file changes mtime on a conflicting
  merge.
- Promote: assert `$HOME` is untouched throughout, and that a host-local path
  absent from `main` still exists after a full run.
- Offer-hook: table-driven over the six branches of §5.3, including the
  gitignored-inside-a-repo case.

## 9. Migration

1. **Rename** the remote branch `latitude5520` → `latitude`.
2. **Create** `air` from `main`; clone the bare repo onto this MacBook (it has
   no `~/.dotfiles` today).
3. **Move** `dotfiles/pure/backend-api/dot_claude/memory/project.md` (staged in
   `machines` on 2026-07-28) into the dotfiles repo as
   `pure/backend-api/.claude/memory/project.md`, allow-listed, host-local at
   first. Its provenance header must be rewritten — it currently documents the
   chezmoi mechanism.
4. **Delete** `machines/dotfiles/` and the chezmoi paths in
   `provision/roles/dotfiles.{sh,ps1}`. `dot_gitconfig.tmpl` is **not** migrated
   as-is: it has drifted hard from the live `~/.gitconfig` (it would drop
   `pager = delta`, the `[delta]` block, the `gh auth git-credential` helper,
   `pull.rebase = true`, and rewrite `user.name`). Track the live file instead.
5. **Update** the dotfiles repo's own `README.md` and `CLAUDE.md`: logical-name
   branches, the derived shared/host rule, the sync timer, `promote`.
6. **Mark** the Phase 3 chezmoi spec superseded, pointing here.
7. **Update** memory: the `machines` project-memory bullets written 2026-07-28
   describing `dotfiles/` as a chezmoi source and the blanket-`chezmoi apply`
   warning both become historical once §9.4 lands.

## 10. Open questions

- Does a **project-scope** `.claude/settings.json` honor `enabledPlugins`? Gates
  the profile-retirement work, not this spec. Probe: add
  `"enabledPlugins": {"cyphy@cyphy": true}` to `machines/.claude/settings.json`,
  then check whether `cyphy:` skills are absent in a fresh session in a repo
  without that key.
- Which host branches, if any, should track `.gitconfig` / `.ssh/config` before
  NixOS retires? Answerable per box during §9 rather than up front.
