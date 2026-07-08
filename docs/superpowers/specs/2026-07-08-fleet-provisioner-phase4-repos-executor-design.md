# Fleet Provisioner — Phase 4: `repos` role executor — Design Spec

## 1. Summary

Make `repos` the fleet's third real role executor. It wraps the existing
`provision/repos.sh` (a host-agnostic, already `DRY_RUN`-capable bash script that
clones your working repos into the per-account home-dir layout) behind the Phase 2
dispatch pattern — with **zero edits to `repos.sh` itself**. Add two per-platform
executors under `provision/roles/` plus one `$RoleExecutors` map entry in
`provision.ps1`; `provision.sh` needs no change.

This is the same "wrap a `DRY_RUN`-capable script + wire dispatch" shape as Phase 2
(`agents`), with **one deliberate difference**: `repos` is **not** a NixOS no-op.
Cloning your working repos is imperative and is not something home-manager manages
declaratively, and `repos.sh` runs fine on native Linux, so it runs on every known
platform.

## 2. Context

- **`fleet.json` role assignment:** `repos` is on `latitude5520` (nixos),
  `g16` (nixos), and `g614jv` (windows) only — not `vps` (27608, debian) nor
  `methe-server` (windows). All three repos-role boxes are personal.
- **`provision/repos.sh` (unchanged, wrapped as-is):**
  - Host-agnostic (Git Bash on Windows, native Linux/macOS). Executed, not sourced
    (`main "$@"` at the bottom), exactly like `agents/bootstrap.sh`.
  - Groups: `my` (metheoryt), `pure` (thepureapp, work), `cyphy671`. Positional
    args select groups; **no args = all three** (`main` defaults to `my pure cyphy671`).
  - `DRY_RUN=1` prints clone/migrate actions and clones nothing — BUT still queries
    `gh` (network) and transiently switches gh's active account, restored to
    `metheoryt` at the end. So dry-run is **not inert** (differs from agents/dotfiles).
  - `apply` is **interactive**: per group it discovers non-archived repos via `gh`,
    then an `fzf` multi-select picks which absent repos to clone. Without a
    TTY / `fzf` / with `DRY_RUN` it lists candidates on stderr and clones nothing.
  - Degrades gracefully: `gh` missing → warn + continue; also migrates legacy
    `~/gh/` clones into the per-account layout first.
- **Phase 2 dispatch (reused verbatim):** `provision.sh` sources every
  `provision/roles/*.sh` then dispatches `role_${role//-/_}`; `provision.ps1` uses a
  `$RoleExecutors` name→scriptblock map. Both wrap `apply` in a per-role
  `Apply <role>? [y/N]` confirm gate and exit with the worst executor status.

## 3. Approach — pure wrap (chosen)

Wrap `repos.sh` unchanged behind the dispatcher. Rejected alternatives:
- **NixOS no-op** (like agents/dotfiles) — rejected: repo cloning isn't
  home-manager-managed; nothing else would clone repos on nixos.
- **`repo_groups[]` in `fleet.json`** (declarative per-machine groups) — deferred
  (out of scope): would require a manifest schema change plus plumbing role-specific
  config through the dispatcher (which today passes only mode/platform/machine).
  The interactive `fzf` select + dry-run listing already act as the per-box filter.
- **Inert dry-run** (skip `gh` in dry-run) — rejected: accept `repos.sh`'s existing
  behavior to keep this a pure, edit-free wrap; the plan preview genuinely shows
  what would be cloned.
- **Auto-install `gh`/`fzf`** (like dotfiles auto-installs chezmoi) — rejected:
  `repos.sh` already degrades gracefully; `gh`/`fzf` are documented Runbook prereqs.

## 4. Components

### 4.1 `provision/roles/repos.sh` — posix executor (new)

Defines `role_repos <mode> <platform> <machine>` (sourced by `provision.sh`, not
executed). Resolves the repo root two levels up from `provision/roles/` (matching
`role_agents`), then:

- `nixos | wsl | debian` → run the script from the repo root:
  - `apply`  → `bash "$repo/provision/repos.sh"` (interactive if a TTY + fzf exist).
  - `dry-run`→ `DRY_RUN=1 bash "$repo/provision/repos.sh"`.
  - **No group args** (repos.sh default = all three groups).
  - Missing `repos.sh` → error line to stderr, return 1.
- `*` (any other platform) → `"  repos: no posix executor for platform '<p>' (skipped)."`,
  return 0.

Folds nixos into the run branch (no home-manager no-op) — the one divergence from
`role_agents`.

### 4.2 `provision/roles/repos.ps1` — windows executor (new)

Defines `Invoke-RoleRepos -Mode <dry-run|apply> -Platform <p> -Machine <m>`
(dot-sourced by `provision.ps1`). Near-verbatim copy of `Invoke-RoleAgents`:

- Non-`windows` platform → generic skip line, return.
- `windows` → resolve repo root two levels up, resolve Git Bash
  (`C:/Program Files/Git/bin/bash.exe`, else `Get-Command bash`; warn + return if
  absent), verify `repos.sh` exists, set `$env:DRY_RUN='1'` for dry-run (unset for
  apply), run `& $bash <repo>/provision/repos.sh` (forward-slashed path), throw on
  non-zero `$LASTEXITCODE`, always clear `$env:DRY_RUN` in a `finally`.

### 4.3 `provision/provision.ps1` — dispatch wiring (modify: one line)

Add to `$RoleExecutors`:

```powershell
'repos' = { param($Mode, $Platform, $Machine) Invoke-RoleRepos -Mode $Mode -Platform $Platform -Machine $Machine }
```

`provision.sh` is **unchanged** — its `roles/*.sh` loop + `role_${role//-/_}` dispatch
already pick up `role_repos` (verified by smoke, not edited).

## 5. Data / control flow

`provision.{sh,ps1} --machine <m>` → detect platform → for each role in the machine's
`fleet.json` roles, if an executor exists, run it (dry-run for plan; apply behind the
`[y/N]` gate). For `repos`: dispatch → `role_repos` / `Invoke-RoleRepos` → execute
`repos.sh` (`DRY_RUN=1` for preview) → per-group `gh` discovery → list (dry-run/no-TTY)
or `fzf` select + `git clone` (interactive apply) → restore gh account → done.

## 6. Error handling

- Missing `repos.sh` → posix: stderr line + return 1; windows: `Write-Warning` +
  return. (A repos-role box should always have the repo cloned.)
- `gh` / `fzf` absent, or no TTY → `repos.sh`'s own warnings; clones nothing; the
  role still exits 0 (best-effort, matching `repos.sh`).
- Windows apply non-zero → `Invoke-RoleRepos` throws so the dispatcher flags the role.
- Dispatcher exit status = worst role status, inherited from Phase 2 (unchanged).

## 7. Testing (session-verifiable smokes; no unit tests — glue/config)

Per the parent spec and Phases 1–3, "tests" are `bash -n`, `pwsh` parse, and smoke
runs with exact expected output.

1. `bash -n provision/roles/repos.sh` → `syntax-ok`; `pwsh` ParseFile on
   `repos.ps1` and `provision.ps1` → `ok`.
2. **Dispatcher→executor wiring (nixos, via `provision.sh`):**
   `provision.sh --machine latitude5520` — `▸ repos — plan:` dispatched through
   `role_repos` (not the generic stub). Because nixos is now a *run* branch (no
   no-op), this actually executes `DRY_RUN=1 repos.sh` in the smoke host (WSL):
   it discovers via `gh` and clones nothing, OR — if `gh` is absent in WSL —
   prints repos.sh's `gh missing` warning and still exits 0. Either way proves
   dispatch + the run branch. **Touches live network + gh** when `gh` is present
   (accepted trade-off).
3. **Direct debian-branch call:** no repos-role box in `fleet.json` is debian/wsl,
   so exercise that branch directly (as Phase 3 did for dotfiles):
   `source provision/roles/repos.sh; role_repos dry-run debian testbox` — runs
   `DRY_RUN=1 repos.sh`, lists clonable repos (or degrades on missing gh), clones
   nothing, `exit=0`.
4. `provision.ps1 -Machine g614jv` dry-run — `> repos - plan:` dispatched via the map.
5. ps1 apply-confirm gate, answer `n` → `repos` shows a preview block then
   `- repos skipped.`, `rc=0`. Driven via **Git Bash piped stdin**
   (`printf 'n\n…' | pwsh -File …`) — the PowerShell tool's `-NonInteractive` mode
   makes `Read-Host` throw (Phase 2 gotcha).

Mutation safety: dry-run clones nothing by construction; smokes need not redirect
`HOME` (nothing is written), but DO exercise the real `gh`/network path when `gh`
is installed. The nixos/windows apply-confirm smokes answer `n`, so no clone runs.

## 8. Runbook (real-box, not fully session-verifiable)

- **Prereqs on a repos-role box:** `gh` (authenticated for all needed accounts:
  `metheoryt`, `cyphy671`) and `fzf` for interactive selection; the SSH aliases
  (`github.com`, `github-cyphy`) configured. Missing `gh`/`fzf` → clones nothing.
- **Real apply (interactive):** run `provision.sh --machine <m> --apply` (nixos/linux)
  or `provision.ps1 -Machine <m> -Apply` (windows) from a **real terminal**, answer
  `y` at the `repos` gate → per group, `fzf` multi-select the absent repos to clone
  (TAB mark, ENTER clone, ESC none). Legacy `~/gh/` clones are migrated first.
- Boxes without the role (`vps`, `methe-server`) show `repos` only if listed; they
  aren't, so no repos step runs there.

## 9. Out of scope

- Any edit to `provision/repos.sh` (pure wrap).
- `repo_groups[]` in `fleet.json` / per-machine group scoping (deferred).
- Auto-installing `gh` or `fzf`.
- The `pure` (work) group appearing on personal boxes — harmless noise, filtered by
  interactive select / ignored in dry-run listing.
