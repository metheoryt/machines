# Fleet Provisioner — Phase 2: the `agents` role as the first real executor — design spec

> **Status:** design approved via brainstorming 2026-07-08; pending user review of
> this written spec, then → `writing-plans`.
> **Parent design:** `docs/superpowers/specs/2026-07-08-unified-fleet-provisioner-design.md` (§6, §8, §10).
> **Builds on:** Phase 1 (`docs/superpowers/plans/2026-07-08-fleet-provisioner-phase1-manifest-dispatcher.md`),
> which shipped `fleet.json`, the shared libs, the launchers, and `just provision` — all dry-run/plan only.

## 1. Goal & scope

Flip `--apply` from a hard stub into actually converging **exactly one** role — `agents` —
on the non-Nix boxes, with a **true dry-run preview** and a **per-role confirm gate**.
The point is not the role itself (it is deliberately the smallest, safest one) but to
establish the **role → per-platform executor** pattern, the **plan → confirm → apply**
loop, and the **dry-run mechanism** that every later role reuses.

**In scope:** a real executor for `agents` only; a `DRY_RUN` mode in `agents/bootstrap.sh`;
the dispatcher wiring that runs an executor when one exists and stubs the rest; a per-role
apply confirm.

**Out of scope (later phases, unchanged by this one):** chezmoi adoption and `~/.dotfiles`
retirement (Phase 3-era), every other role's executor, NixOS import generation, mesh
reconcile, agenix, backup/restore. Those keep the Phase 1 "not yet implemented" stub.

**Why `agents` first:** `agents/bootstrap.sh` is already idempotent, cross-platform, and
prints a per-file diff on every run; it is in every machine's role list; its blast radius
is symlinks into `~/.claude` / `~/.codex` with backups of any displaced real files. Lowest
risk for the first executor that actually mutates a box.

## 2. Target boxes

`agents` is carried by every machine, but the executor resolves per platform:

| Machine | Platform | `agents` executor behavior |
|---|---|---|
| `g614jv`, `homeserver` | windows | **real** — invoke Git Bash on `bootstrap.sh` |
| `vps` | debian | **real** — `bash bootstrap.sh` |
| `latitude5520`, `g16` | nixos | **no-op** — print "owned by home-manager (`just switch`); dispatcher skips" |

The NixOS no-op is load-bearing, not laziness: `modules/home/claude.nix` /
`codex.nix` already own those symlinks; running `bootstrap.sh` over home-manager-managed
paths is double ownership. `bootstrap.sh`'s own `-ef` check already refuses to clobber
Nix-managed links, but the dispatcher should not even call it on nixos.

## 3. `bootstrap.sh` gains a `DRY_RUN` mode

The one substantive edit to existing code.

- **Contract:** with `DRY_RUN` set (non-empty), `bootstrap.sh` runs its existing
  **detection** logic (`-ef`, `-L`, `readlink`, existence checks) but performs **no
  mutation** — no `ln`, `mv`, `rm`, `mkdir -p`, no host-stub seeding, no
  `git config core.hooksPath`. It prints what it *would* do (`~ would link`,
  `~ would back up`, `= already linked`, `! would seed host stub`) and a summary
  (`would-link=N would-back-up=N already-linked=N`). Exit 0 (dry-run never "fails" on
  the Windows symlink-permission path — it hasn't attempted a symlink).
- **Default unchanged:** with `DRY_RUN` unset, behavior is byte-for-byte what it is today.
  `just agent-bootstrap`, the git-hook auto-refresh, and NixOS parity are unaffected.
- **Mechanism:** guard the mutating statements. The cleanest form is a tiny helper the
  mutations route through (e.g. `_run() { if [ -n "${DRY_RUN:-}" ]; then printf '    (dry-run) %s\n' "$*"; else "$@"; fi; }`)
  plus mode-aware messages in `link()` / `backup_target()` / the host-stub and git-hook
  blocks. The detection branches (already-linked / wrong-target) are read-only and stay
  as-is.
- **Counters:** in dry-run, increment `would_link` / `would_backup` instead of
  `linked` / `backed`, so the summary reads as a preview.

## 4. Executor structure — `provision/roles/`

One file per platform-family, each independently readable and testable:

- `provision/roles/agents.sh` — defines `role_agents <mode> <platform> <machine>`:
  - `nixos` → print the home-manager-owned skip line; return 0.
  - `wsl` | `debian` → resolve repo root (two levels up), then
    `DRY_RUN=1 bash "$repo/agents/bootstrap.sh"` for `dry-run`, plain `bash …` for `apply`.
  - unknown platform → print "no agents executor for <platform>"; return 0.
- `provision/roles/agents.ps1` — defines `Invoke-RoleAgents -Mode -Platform -Machine`:
  - `windows` → invoke Git Bash (`C:/Program Files/Git/bin/bash.exe`, matching the
    justfile's `windows-shell` path) on `agents/bootstrap.sh`, setting `$env:DRY_RUN='1'`
    for `dry-run` and clearing it for `apply`.
  - `nixos` (a Windows launcher would never hit this, but keep symmetry) → skip line.

Both are pure functions over (mode, platform, machine) with no manifest knowledge — they
receive the resolved platform from the dispatcher.

## 5. Dispatcher wiring + apply UX

In the `provision.sh` / `provision.ps1` role loop, replace the flat stub with a dispatch:

- **bash** (`provision.sh` sources `roles/*.sh`): sanitize the role name
  (`agents` → `role_agents`, future `mesh-member` → `role_mesh_member` via `${role//-/_}`).
  If `declare -F role_<name>` exists → call it with `<mode> <platform> <machine>`; else
  print the existing stub line.
- **PowerShell** (`provision.ps1` dot-sources `roles/*.ps1`): a small role→scriptblock
  map (`@{ agents = { param($Mode,$Platform,$Machine) Invoke-RoleAgents ... } }`) avoids
  name-mangling; if the role is a key → invoke; else stub.

**Apply UX (per-role confirm — chosen over one up-front prompt):**
- `--dry-run` (default): for each role, print its preview. For `agents` this is now the
  real `DRY_RUN=1 bootstrap.sh` output; other roles print the stub. Stop after previews.
- `--apply` (was: always error + exit 1): for each role **with an executor**, print the
  dry-run preview first, then prompt `Apply <role>? [y/N]`; on `y`, run it for real; on
  anything else, skip it. Roles **without** an executor print
  `apply: not yet implemented (skipped)`. The run exits 0 if every executor that ran
  succeeded, non-zero if any failed. (So `--apply` is no longer a blanket safe-stub; it
  is safe because it previews + confirms each mutation and only `agents` can mutate.)

Non-interactive note: the confirm reads stdin; a `--yes`/`-Yes` flag to auto-confirm is a
*possible* small add for scripted runs, but is **not required** for Phase 2 and is left to
whoever needs it (YAGNI).

## 6. Tests (smoke — per parent spec §"tests", no pytest-style units)

Run on the environments available: WSL Ubuntu-26.04 (bash+jq) and this Windows box (g614jv,
pwsh + Git Bash). Real-box confirmations that need `homeserver`/`vps`/nixos go to a Runbook.

1. **Dry-run mutates nothing:** `DRY_RUN=1 CLAUDE_CONFIG_DIR=<tmp> bash agents/bootstrap.sh`
   → the tmp dir has **zero** symlinks afterward; output shows `would link`. (WSL)
2. **Converged = clean preview:** real `CLAUDE_CONFIG_DIR=<tmp> bootstrap.sh`, then
   `DRY_RUN=1` re-run → all `= already linked`, `would-link=0`. (WSL)
3. **Default unchanged:** a plain `CLAUDE_CONFIG_DIR=<tmp> bootstrap.sh` still links
   (regression guard that the guards did not alter default behavior). (WSL)
4. **Dispatcher dry-run:** `provision.sh --machine vps` → real `agents` preview + stub
   lines for the other roles. (WSL)
5. **NixOS no-op:** `provision.sh --machine latitude5520` → `agents` prints the
   home-manager skip, no bootstrap invocation. (WSL)
6. **Windows executor:** `provision.ps1 -Machine g614jv` → `agents` preview via Git Bash;
   `-Apply` walks the `Apply agents? [y/N]` gate (answer `n` → skipped, exit 0). (g614jv)

**Runbook (needs the real boxes):** `--apply` answering `y` on `g614jv` actually
(re)links `~/.claude`; same on `homeserver` and `vps` after a `git pull`.

## 7. Files

- **Modify** `agents/bootstrap.sh` — add `DRY_RUN` mode (guards + preview messages + counters).
- **Create** `provision/roles/agents.sh` — `role_agents` (nixos/wsl/debian).
- **Create** `provision/roles/agents.ps1` — `Invoke-RoleAgents` (windows).
- **Modify** `provision/provision.sh` — source `roles/*.sh`; dispatch + per-role apply confirm.
- **Modify** `provision/provision.ps1` — dot-source `roles/*.ps1`; dispatch + per-role apply confirm.

`fleet.json`, `fleet.sh`, `Fleet.psm1`, and the `just provision` recipe are unchanged.

## 8. Self-review

- **Placeholders:** none — every component has a concrete mechanism.
- **Consistency:** the NixOS no-op appears in §2/§4/§6 identically; `DRY_RUN` semantics in
  §3 match the executor calls in §4 and the tests in §6; `--apply` behavior in §5 matches
  test 6.
- **Scope:** single role, single new concept (executor + dry-run), fits one plan. Larger
  pieces (chezmoi, other roles) are explicitly deferred.
- **Ambiguity:** "no-op on nixos" is defined as *do not invoke bootstrap.sh, print the
  skip line*; "dry-run" is defined as *detection runs, mutation does not*; apply confirm is
  *per-role*, not run-wide.
