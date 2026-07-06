# Fleet Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify machine onboarding into one shared `provision/` tier with a README "start here" routing table, and add `provision/repos.sh` to clone/migrate your repos into a per-account `~/my` · `~/pure` · `~/cyphy671` layout.

**Architecture:** Promote the two generic provisioning scripts out of their mis-filed homes into a top-level `provision/` peer of `install-media/` and `agents/`; `agents/bootstrap.sh` stays the portable core both call. Rewire every reference and add a routing table. Then add a host-agnostic bash `repos.sh` that migrates existing `~/gh/` clones (owner-driven `mv`) and clones the rest via `gh` discovery.

**Tech Stack:** bash (Git Bash on Windows / native Linux), PowerShell 5.1+, `gh` CLI, `git`, `just`.

## Global Constraints

- **`machines` is a PUBLIC repo.** `provision/repos.txt` holds only repo *names* (deemed public-safe) — never tokens or credentials.
- **All file relocations use `git mv`** (history preserved); each move's diff is a pure rename plus the intended in-file edits, no spurious whole-file churn.
- **Historical docs under `docs/superpowers/` are never edited** — they record decisions at their date.
- **Clone URL form is always** `git@<ssh-alias>:<owner>/<repo>.git` so SSH key + commit identity line up (`github.com` for metheoryt/thepureapp, `github-cyphy` for cyphy671).
- **`provision/windows.ps1` repo-root resolver depth is `'..'`** (the script sits one level below the repo root, not three).
- **Scope boundary:** this plan builds and *verifies* the scripts/docs (syntax, dry-run, grep sweeps). Actually running `repos.sh` migration/clone on the live WSL distros is a separate operational step the user performs per box, `DRY_RUN=1` first — it is **not** executed by this plan.
- **Group table (single source of truth for `repos.sh`):**
  | key | dir | owner | ssh-alias | gh-account | mode |
  |---|---|---|---|---|---|
  | my | my | metheoryt | github.com | metheoryt | all |
  | pure | pure | thepureapp | github.com | metheoryt | list |
  | cyphy671 | cyphy671 | cyphy671 | github-cyphy | cyphy671 | all |

---

### Task 1: `provision/windows.ps1` (move + self-fix)

**Files:**
- Move: `hosts/g16/windows/bootstrap-agents.ps1` → `provision/windows.ps1` (`git mv`)
- Modify: `provision/windows.ps1` (repo-root resolver + header usage strings)

**Interfaces:**
- Produces: `provision/windows.ps1` — the generic Windows agent-env orchestrator, invoked as `.\provision\windows.ps1 [-Work] [-BackupRoot <path>] [-Force] [-SkipInstall]`. Resolves its repo root via `$PSScriptRoot\..`.

- [ ] **Step 1: Move the file with history preserved**

```bash
mkdir -p provision
git mv hosts/g16/windows/bootstrap-agents.ps1 provision/windows.ps1
```

- [ ] **Step 2: Fix the repo-root resolver (depth 3 → depth 1)**

In `provision/windows.ps1`, replace:

```powershell
    $guess = Resolve-Path (Join-Path $PSScriptRoot '..\..\..') -ErrorAction SilentlyContinue
```

with:

```powershell
    $guess = Resolve-Path (Join-Path $PSScriptRoot '..') -ErrorAction SilentlyContinue
```

- [ ] **Step 3: Fix the header usage examples**

In the `<# … #>` header comment block, replace the four example lines:

```powershell
      .\bootstrap-agents.ps1                                # auto-discovers the backup on any drive + restores creds/history
      .\bootstrap-agents.ps1 -BackupRoot H:\backup          # or point it at a specific <L>:\backup
      .\bootstrap-agents.ps1 -Work                          # + work profile
      .\bootstrap-agents.ps1 -Force                         # overwrite existing creds/settings.local
```

with:

```powershell
      .\provision\windows.ps1                                # auto-discovers the backup on any drive + restores creds/history
      .\provision\windows.ps1 -BackupRoot H:\backup          # or point it at a specific <L>:\backup
      .\provision\windows.ps1 -Work                          # + work profile
      .\provision\windows.ps1 -Force                         # overwrite existing creds/settings.local
```

- [ ] **Step 4: Verify the resolver is fixed and the script still parses**

Run:
```bash
grep -n "\.\.\\\\\.\.\\\\\.\." provision/windows.ps1 || echo "NO OLD DEPTH — good"
pwsh -NoProfile -Command "[void][ScriptBlock]::Create((Get-Content -Raw provision/windows.ps1)); 'PARSE OK'"
```
Expected: `NO OLD DEPTH — good`, then `PARSE OK`. (If `pwsh` is unavailable, inspect by eye — the header comment guides intent.)

- [ ] **Step 5: Commit**

```bash
git add -A provision/windows.ps1 hosts/g16/windows/bootstrap-agents.ps1
git commit -m "provision: move generic Windows orchestrator to provision/windows.ps1

git mv from hosts/g16/windows/bootstrap-agents.ps1 (it is generic — serves g16
and homeserver). Fix the repo-root resolver (depth 3 -> 1) and header usage.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `provision/linux.sh` + `README.md` + `.gitattributes` (move + reframe; remove `bootstrap/`)

**Files:**
- Move: `bootstrap/ubuntu.sh` → `provision/linux.sh`; `bootstrap/README.md` → `provision/README.md`; `bootstrap/.gitattributes` → `provision/.gitattributes` (all `git mv`)
- Modify: `provision/linux.sh` (self-references); `provision/README.md` (title/usage/reframe)

**Interfaces:**
- Produces: `provision/linux.sh` — the portable non-Nix Linux/WSL provisioner, invoked `bash provision/linux.sh`. Unchanged behaviour beyond self-reference text.

- [ ] **Step 1: Move the three files with history preserved**

```bash
git mv bootstrap/ubuntu.sh provision/linux.sh
git mv bootstrap/README.md provision/README.md
git mv bootstrap/.gitattributes provision/.gitattributes
```

- [ ] **Step 2: Fix `provision/linux.sh` self-references**

In `provision/linux.sh`, apply these exact replacements:

- `bootstrap/ubuntu.sh — provision a fresh Debian/Ubuntu box (especially a` → `provision/linux.sh — provision a fresh Debian/Ubuntu box (especially a`
- `#   bash ~/nix/bootstrap/ubuntu.sh` → `#   bash ~/nix/provision/linux.sh`
- `# See bootstrap/README.md for base-distro guidance and post-install steps.` → `# See provision/README.md for base-distro guidance and post-install steps.`
- `# ── Locate the repo (this script lives in <repo>/bootstrap/) ──────────────────` → `# ── Locate the repo (this script lives in <repo>/provision/) ──────────────────`
- `have apt-get || die "this script targets Debian/Ubuntu (apt-get not found). See bootstrap/README.md for other bases."` → `…See provision/README.md for other bases."`
- `  *) die "gortex ships x86_64-linux only; this box is $(uname -m). See bootstrap/README.md." ;;` → `…See provision/README.md." ;;`
- `# bootstrap/ubuntu.sh; mirrors modules/system/git-autofetch on the Nix fleet.` → `# provision/linux.sh; mirrors modules/system/git-autofetch on the Nix fleet.`

- [ ] **Step 3: Reframe `provision/README.md`**

- Retitle line 1 `# Disposable-distro bootstrap` → `# Non-Nix Linux / WSL provisioning (persisted or disposable)`.
- In the intro, drop the "disposable-only" framing: it provisions **any glibc apt Linux — a persisted daily box or a throwaway distro, same result** (persisted just means you don't `wsl --unregister` it). Keep the multi-account SSH / git-identity and base-distro sections verbatim.
- Update the Usage block:

  ```bash
  git clone https://github.com/<you>/machines ~/nix
  bash ~/nix/provision/linux.sh
  ```

- [ ] **Step 4: Verify syntax, no stale refs, and `bootstrap/` is gone**

Run:
```bash
bash -n provision/linux.sh && echo "BASH SYNTAX OK"
grep -rn "bootstrap/ubuntu\|bootstrap/README" provision/ && echo "STALE FOUND — fix" || echo "NO STALE REFS — good"
test -d bootstrap && echo "bootstrap/ STILL EXISTS — should be gone" || echo "bootstrap/ REMOVED — good"
```
Expected: `BASH SYNTAX OK`, `NO STALE REFS — good`, `bootstrap/ REMOVED — good`.

- [ ] **Step 5: Commit**

```bash
git add -A provision/ bootstrap/
git commit -m "provision: rename bootstrap/ -> provision/ (linux.sh, README, gitattributes)

git mv bootstrap/ubuntu.sh -> provision/linux.sh (+ README/.gitattributes).
Fix self-references; reframe README for persisted-or-disposable glibc Linux.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Rewire external references + README routing table

**Files:**
- Modify: `justfile` (lines 8, 62); `hosts/g16/windows/restore.ps1:203`; `hosts/g16/windows/backup.ps1:27`; `hosts/g16/windows/windows-reinstall-runbook.md` (lines 7, 145, 156); `modules/system/git-autofetch/README.md:13`; `README.md` (routing table + `bootstrap/` section)

**Interfaces:**
- Consumes: `provision/windows.ps1`, `provision/linux.sh` (Tasks 1–2).
- Produces: a repo where no non-doc, non-`G614JV.md` file references the old script paths, and `README.md` carries the routing table.

- [ ] **Step 1: `justfile` — repoint the two comment references**

Replace both occurrences of `hosts\g16\windows\bootstrap-agents.ps1` (lines 8 and 62) with `provision\windows.ps1`.

- [ ] **Step 2: `hosts/g16/windows/restore.ps1:203` — the printed next-step hint**

Replace:
```powershell
$G += "       .\hosts\g16\windows\bootstrap-agents.ps1 -BackupRoot $Root   # (+ -Work if the work profile is used)"
```
with:
```powershell
$G += "       .\provision\windows.ps1 -BackupRoot $Root   # (+ -Work if the work profile is used)"
```

- [ ] **Step 3: `hosts/g16/windows/backup.ps1:27` — the doc comment**

Replace `RESTORE side (restore.ps1 / bootstrap-agents.ps1) auto-discovers the backup` with `RESTORE side (restore.ps1 / provision\windows.ps1) auto-discovers the backup`.

- [ ] **Step 4: `windows-reinstall-runbook.md` — three prose references**

- Line 7: `**\`restore.ps1\` and \`bootstrap-agents.ps1\` auto-discover the backup on *any* drive letter**` → `…\`restore.ps1\` and \`provision\windows.ps1\` auto-discover…`
- Line 145: `The **restore-side scripts** (\`restore.ps1\`, \`bootstrap-agents.ps1\`, \`git-autofetch.ps1\`)` → `…(\`restore.ps1\`, \`provision\windows.ps1\`, \`git-autofetch.ps1\`)`
- Line 156: `run \`hosts\g16\windows\bootstrap-agents.ps1 -BackupRoot R:\backup\`` → `run \`provision\windows.ps1 -BackupRoot R:\backup\``

- [ ] **Step 5: `modules/system/git-autofetch/README.md:13` — reframe the WSL row**

Replace:
```
| Ubuntu/WSL (disposable box) | inlined in `bootstrap/ubuntu.sh` | Installed automatically: drops `~/.local/bin/git-autofetch` and schedules it via a systemd *user* timer (every ~10 min), falling back to cron. Scans `$HOME`. |
```
with:
```
| Ubuntu/WSL (persisted or disposable) | inlined in `provision/linux.sh` | Installed automatically: drops `~/.local/bin/git-autofetch` and schedules it via a systemd *user* timer (every ~10 min), falling back to cron. Scans `$HOME`. |
```

- [ ] **Step 6: `README.md` — replace the `bootstrap/` section with a `provision/` one and add the routing table**

Near the top (after the fleet intro), insert an **Onboarding — start here** section:

```markdown
## Onboarding — start here

| Box kind | One command |
|---|---|
| **NixOS** — g16, latitude5520 | `just switch` |
| **Windows** — ME-G614JV, methe-server | `provision\windows.ps1` (`-Work` adds the work profile) |
| **WSL / any glibc Linux** — persisted or throwaway | `bash provision/linux.sh` |

All three link your synced agent config for you (via `agents/bootstrap.sh`); to
re-link only that, run `bash agents/bootstrap.sh` (or `just agent-bootstrap`; on
NixOS `just switch`). To clone your repos into the `~/my` · `~/pure` ·
`~/cyphy671` layout, run `bash provision/repos.sh <groups>` (e.g. `my cyphy671`
on a personal box, `pure` on a work box).
```

Then replace the old lines 21–22 mention and the `**bootstrap/**` bullet block (lines ~108–113) so both name `provision/` (`provision/linux.sh`, `provision/README.md`) and describe it as "persisted or disposable," a peer of `install-media/`.

- [ ] **Step 7: Verify the grep sweep is clean and `just` still parses**

Run:
```bash
grep -rn "bootstrap-agents\|bootstrap/ubuntu\|bootstrap/README" \
  --exclude-dir=docs --exclude=G614JV.md . && echo "STALE FOUND — fix" || echo "NO STALE REFS — good"
grep -rn "hosts.g16.windows.bootstrap-agents" . --exclude-dir=docs && echo "STALE PATH — fix" || echo "NO STALE PATHS — good"
just --list >/dev/null 2>&1 && echo "JUST PARSES" || echo "(just unavailable — inspect justfile by eye)"
```
Expected: `NO STALE REFS — good`, `NO STALE PATHS — good`, `JUST PARSES` (or the inspect note). Note: `install.ps1` has **no** `bootstrap-agents.ps1` reference (verified in design) — no edit needed there.

- [ ] **Step 8: Commit**

```bash
git add -A justfile hosts/ modules/ README.md
git commit -m "provision: rewire references + add README onboarding routing table

Repoint justfile/restore.ps1/backup.ps1/runbook/git-autofetch README to
provision/windows.ps1 & provision/linux.sh; add the 'start here' table.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `provision/repos.sh` + `provision/repos.txt`

**Files:**
- Create: `provision/repos.sh`
- Create: `provision/repos.txt`

**Interfaces:**
- Consumes: the group table from Global Constraints; `provision/repos.txt` (owner/repo lines for `list`-mode groups).
- Produces: `provision/repos.sh` — `bash provision/repos.sh [group…]` (default all groups); `DRY_RUN=1` prints intended migrations + clone URLs without acting. Migrates `~/gh/` clones (owner-driven `mv`, skip-if-target-exists) then clones the rest via `gh` discovery (`all`) or `repos.txt` (`list`).

- [ ] **Step 1: Create `provision/repos.txt`**

```text
# provision/repos.txt — curated repo list for "list"-mode groups (currently: pure).
# One `owner/repo` per line; matched to a group by owner. Comments start with #.
#
# NOTE: machines is a PUBLIC repo. List only repo NAMES that are OK to expose
# publicly, and NEVER put tokens or credentials here.
#
# Replace the example below with your actual thepureapp repos:
# thepureapp/example-repo
```

- [ ] **Step 2: Create `provision/repos.sh`**

```bash
#!/usr/bin/env bash
# provision/repos.sh — clone your working repos into a per-account home-dir
# layout, migrating any existing ~/gh/ clones into it first. Host-agnostic
# (Git Bash on Windows, native Linux/macOS). Clone-if-absent; git-autofetch
# keeps them current after. Best-effort: warns + continues if gh is missing.
#
# Usage:
#   bash provision/repos.sh                 # all groups
#   bash provision/repos.sh my cyphy671     # personal box
#   bash provision/repos.sh pure            # work box
#   DRY_RUN=1 bash provision/repos.sh my    # print actions, do nothing
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-0}"
GH_ROOT="$HOME/gh"                 # legacy layout to migrate FROM
REPOS_TXT="$SCRIPT_DIR/repos.txt"  # curated 'list'-mode entries (owner/repo/line)

# key | dir | owner | ssh-alias | gh-account | mode   (mode: all=gh discovery, list=repos.txt)
GROUPS=(
  "my|my|metheoryt|github.com|metheoryt|all"
  "pure|pure|thepureapp|github.com|metheoryt|list"
  "cyphy671|cyphy671|cyphy671|github-cyphy|cyphy671|all"
)

info() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else eval "$*"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

# owner_of <clone-dir> -> GitHub owner from origin remote (handles git@host:owner/repo & https://host/owner/repo)
owner_of() {
  local url; url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"
  url="${url#*://}"      # strip scheme:// (https)
  url="${url#*@}"        # strip user@ (git@host:...)
  url="${url#*[:/]}"     # strip host + first ':' or '/'  -> owner/repo
  printf '%s' "${url%%/*}"
}

# migrate_group <dir> <owner>: mv any ~/gh clone owned by <owner> into ~/<dir>/<name>
migrate_group() {
  local dir="$1" owner="$2" gitdir clone name target
  [ -d "$GH_ROOT" ] || return 0
  while IFS= read -r gitdir; do
    clone="$(dirname "$gitdir")"
    name="$(basename "$clone")"
    case "$name" in machines|nix) continue;; esac        # never migrate the config clone
    [ "$(owner_of "$clone")" = "$owner" ] || continue
    target="$HOME/$dir/$name"
    if [ -e "$target" ]; then warn "skip migrate (target exists): $target"; continue; fi
    run "mkdir -p '$HOME/$dir'"
    run "mv '$clone' '$target'"
    info "migrated: $clone -> $target"
  done < <(find "$GH_ROOT" -maxdepth 3 -type d -name .git 2>/dev/null)
}

clone_one() {  # <alias> <owner> <repo> <dir>
  local alias="$1" owner="$2" repo="$3" dir="$4" target="$HOME/$4/$3"
  [ -e "$target" ] && { info "exists: $target"; return; }
  run "mkdir -p '$HOME/$dir'"
  run "git clone 'git@$alias:$owner/$repo.git' '$target'"
}

discover_all() {  # <owner> <account> -> non-archived repo names, one per line
  local owner="$1" account="$2"
  have gh || { warn "gh missing — cannot discover $owner"; return 1; }
  gh auth switch --user "$account" >/dev/null 2>&1 || true
  gh repo list "$owner" --no-archived --limit 1000 --json name -q '.[].name' 2>/dev/null
}

list_repos_for() {  # <owner> -> repo names from repos.txt whose owner matches
  [ -f "$REPOS_TXT" ] || return 0
  local line
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$line" ] || continue
    case "$line" in "$1"/*) printf '%s\n' "${line#*/}";; esac
  done < "$REPOS_TXT"
}

main() {
  local selected=("$@")
  [ ${#selected[@]} -eq 0 ] && selected=(my pure cyphy671)
  local key row g dir owner alias account mode repo
  for key in "${selected[@]}"; do
    row=""; for g in "${GROUPS[@]}"; do [ "${g%%|*}" = "$key" ] && row="$g"; done
    [ -n "$row" ] || { warn "unknown group: $key"; continue; }
    IFS='|' read -r _ dir owner alias account mode <<< "$row"
    printf '\n== group %s  (~/%s <- %s, mode=%s)\n' "$key" "$dir" "$owner" "$mode"
    migrate_group "$dir" "$owner"
    case "$mode" in
      all)  discover_all "$owner" "$account" | while IFS= read -r repo; do
              [ -n "$repo" ] && clone_one "$alias" "$owner" "$repo" "$dir"; done ;;
      list) list_repos_for "$owner"          | while IFS= read -r repo; do
              [ -n "$repo" ] && clone_one "$alias" "$owner" "$repo" "$dir"; done ;;
    esac
  done
  have gh && gh auth switch --user metheoryt >/dev/null 2>&1 || true   # restore default gh account
  printf '\nDone.%s\n' "$([ "$DRY_RUN" = 1 ] && printf ' (dry-run — nothing changed)')"
}

main "$@"
```

- [ ] **Step 3: Verify bash syntax**

Run: `bash -n provision/repos.sh && echo "BASH SYNTAX OK"`
Expected: `BASH SYNTAX OK`.

- [ ] **Step 4: Dry-run a group to confirm intended actions print without acting**

Run: `DRY_RUN=1 bash provision/repos.sh my`
Expected: a `== group my (~/my <- metheoryt, mode=all)` header, any `migrated:` / `[dry-run] mv …` lines for existing `~/gh` metheoryt clones, and `[dry-run] git clone 'git@github.com:metheoryt/<repo>.git' …` lines (if `gh` is authed as metheoryt) or a `! gh missing …` warning (if not). Ends with `Done. (dry-run — nothing changed)`. Confirm **no** `~/my` directory was actually created: `test -d ~/my && echo CREATED || echo "not created — good"` → `not created — good`.

- [ ] **Step 5: Commit**

```bash
git add provision/repos.sh provision/repos.txt
git commit -m "provision: add repos.sh — migrate ~/gh + clone into ~/my/~/pure/~/cyphy671

Per-box group selection (repos.sh [group...]); owner-driven ~/gh migration via
mv (dirty-tree-safe, skip-if-target-exists); gh discovery for all-mode groups,
repos.txt for the pure list. DRY_RUN=1 prints intended actions.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Update `agents/hosts/G614JV.md` to the new layout

**Files:**
- Modify: `agents/hosts/G614JV.md` (WSL section, lines ~16–19)

**Interfaces:**
- Consumes: `provision/linux.sh`, `provision/repos.sh` (Tasks 2, 4).
- Produces: host memory that names the new layout + tooling without falsely claiming the live boxes are already migrated.

- [ ] **Step 1: Fix the `bootstrap/ubuntu.sh` reference**

In `agents/hosts/G614JV.md`, replace `All wired by \`bootstrap/ubuntu.sh\`.` with `All wired by \`provision/linux.sh\`.`

- [ ] **Step 2: Record the new target layout + migration path**

Append to the WSL section a bullet describing the intended layout and how to reach it (do not rewrite the current-state facts as if migration already happened):

```markdown
- **Target repo layout (via `provision/repos.sh`, 2026-07-07):** personal repos
  under `~/my` (all non-archived `metheoryt`), `thepureapp` work repos under
  `~/pure` (curated `provision/repos.txt`), the `cyphy671` account's repo under
  `~/cyphy671`. `repos.sh` migrates existing `~/gh/` clones (owner-driven `mv`)
  then clones the rest; run it per box with the box's groups (`my cyphy671` on
  the personal distro, `pure` on the work distro), `DRY_RUN=1` first. `~/gh/`
  retires once migrated; `~/gh/exactly/*` is left as-is (archived, no access).
```

- [ ] **Step 3: Verify no stale script ref remains in the host file**

Run: `grep -n "bootstrap/ubuntu" agents/hosts/G614JV.md && echo "STALE — fix" || echo "CLEAN — good"`
Expected: `CLEAN — good`.

- [ ] **Step 4: Commit**

```bash
git add agents/hosts/G614JV.md
git commit -m "agents: record new ~/my/~/pure/~/cyphy671 layout + repos.sh migration path (G614JV)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Post-plan operational note (not part of this plan's execution)

Once merged, migrate each live WSL distro yourself, `DRY_RUN=1` first:
- personal (Ubuntu-26.04): `DRY_RUN=1 bash provision/repos.sh my cyphy671`, review, then run for real.
- work (Ubuntu-24.04): `DRY_RUN=1 bash provision/repos.sh pure`, review, then run for real.
Populate `provision/repos.txt` with the actual `thepureapp/<repo>` lines before the work-box run.

## Self-Review

- **Spec coverage:** provision/ tier + moves (Tasks 1–2) ✓; reference rewiring + routing table (Task 3) ✓; repos.sh with migration + per-box selection + gh discovery + repos.txt (Task 4) ✓; G614JV.md layout update (Task 5) ✓; `install.ps1` no-op noted (Task 3 Step 7) ✓; public-repo constraint enforced (repos.txt header, Task 4 Step 1) ✓; commit-identity `gitdir:~/pure/` correctly omitted (spec out-of-scope) ✓.
- **Placeholder scan:** `repos.txt` ships an empty (commented) list by design — the note in the operational section makes populating it an explicit user step, not a hidden TODO. No other placeholders.
- **Type/name consistency:** group keys `my`/`pure`/`cyphy671`, dirs, owners, aliases, and modes match the Global Constraints table across Task 4's script and Task 5's prose. `provision/windows.ps1` / `provision/linux.sh` names consistent across Tasks 1–3, 5.
