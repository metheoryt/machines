# Fleet Hostname Normalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every fleet host's naming consistent — logical name (role) for the fleet key / SSH alias / tailnet node / repo dir, and the hardware-model as the OS hostname (`detect.hostname`) — by renaming the server box `methe-server`→`g513ie` and the repo dirs `hosts/g16`→`hosts/desktop`, `hosts/homeserver`→`hosts/server`.

**Architecture:** A repo-side rename spanning `fleet.json`, per-host memory, docs, and provision scripts, coordinated with one physical Windows box rename + reboot. Because the box rename is user-executed and time-gated, the work splits into two independently-mergeable phases with the reboot as the pivot.

**Tech Stack:** Nix flake (single NixOS host `latitude`), `fleet.json` manifest, bash/PowerShell provision scripts, git-tracked Markdown memory tiers.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-19-fleet-hostname-normalization-design.md`. Read it first.
- **Two-layer convention:** logical name = fleet key = SSH alias = tailnet node = repo `hosts/<dir>` (`latitude`, `desktop`, `server`, `hub`); model name = OS hostname = `detect.hostname` = hardware model lowercased (`latitude5520`, `g614jv`, `g513ie`, `27608`).
- **Verified hardware models (`Win32_ComputerSystem.Model`, 2026-07-19):** server = `ROG Strix G513IE`; desktop = `ROG Strix G614JV`.
- **`hub` stays `27608`** — a VPS, no laptop model. Do not rename.
- **NEVER touch `docs/superpowers/plans/**` or `docs/superpowers/specs/**`** except this plan file — they are dated history.
- **`fleet_detect()` matches `detect.hostname` against the live OS hostname** (`hostname` on Linux, `$env:COMPUTERNAME` on Windows). Therefore `fleet.json`'s `detect.hostname` MUST equal what the box actually reports — this is the single value coupled to the physical box, and the reason for the phase split.
- **Nix gate runs only on a NixOS box.** `just quick` / `nix build --dry-run` must run on `latitude5520` (the only NixOS member) — this worktree is on it. Windows/VPS members have no Nix.
- **Do NOT `set -e`-style blind-sweep hostnames.** Some statements are point-in-time empirical records ("verified live … `methe-server`") that stay true until the box reboots; only convention/target statements flip in Phase 1.

---

## Phase split — merge boundary (read before executing)

- **Phase 1 (Tasks 1–4): box-independent. Merge back to `main` immediately.** Nothing here changes what the server currently reports; safe to land while the box is still `methe-server`. This is the FF-merge-back checkpoint.
- **Phase 2 (Tasks 6–7): the atomic flip. MUST NOT land on `main` before the box reboot (Task 5).** While `fleet.json` says `g513ie` and the box says `methe-server`, `fleet_detect()` returns empty AND `fleet-gather.sh`'s self-exclusion (live `hostname` vs fleet identity) misfires and treats the server as a remote. Task 6 rides with the reboot.
- **Task 5 is the user-executed pivot** (rename + reboot the Windows box).

---

## Phase 1 — box-independent (merge now)

### Task 1: Rename `hosts/homeserver` → `hosts/server`

**Files:**
- Move: `hosts/homeserver/` → `hosts/server/` (contains `README.md`, `windows/winget-packages.json`)
- Modify: every live file referencing the path `hosts/homeserver`

**Interfaces:**
- Produces: repo dir `hosts/server` matching fleet key `server`.

- [ ] **Step 1: Move the dir with git**

```bash
git mv hosts/homeserver hosts/server
```

- [ ] **Step 2: Find remaining path references (baseline)**

Run:
```bash
grep -rn 'hosts/homeserver' . --exclude-dir=.git ':!docs/superpowers/'
```
Expected: hits in live docs only (e.g. `README.md`, `AGENTS.md`, `.claude/memory/project.md`, `agents/hosts/*.md`). Note each file:line.

- [ ] **Step 3: Rewrite each `hosts/homeserver` → `hosts/server`**

For every file from Step 2, replace the literal path `hosts/homeserver` with `hosts/server`. These are plain doc/path references — no logic. Do NOT touch anything under `docs/superpowers/`.

- [ ] **Step 4: Verify no live references remain**

Run:
```bash
grep -rn 'hosts/homeserver' . --exclude-dir=.git ':!docs/superpowers/'
```
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(hosts): rename hosts/homeserver -> hosts/server (repo dir = fleet key)"
```

---

### Task 2: Rename `hosts/g16` → `hosts/desktop` (incl. bootstrap URL)

**Files:**
- Move: `hosts/g16/` → `hosts/desktop/` (contains `windows/` — `install.ps1`, `backup.ps1`, `restore.ps1`, `windows-reinstall-runbook.md`, `winget-packages.json`)
- Modify: `hosts/desktop/windows/install.ps1` (self-referential bootstrap URL), and every other live file referencing `hosts/g16`

**Interfaces:**
- Produces: repo dir `hosts/desktop` matching fleet key `desktop`; the public bootstrap URL now points at `hosts/desktop/windows/install.ps1`.

- [ ] **Step 1: Move the dir with git**

```bash
git mv hosts/g16 hosts/desktop
```

- [ ] **Step 2: Rewrite the self-referential bootstrap URL**

In `hosts/desktop/windows/install.ps1`, the fetch-me comment currently reads:
```
irm https://raw.githubusercontent.com/metheoryt/machines/main/hosts/g16/windows/install.ps1 | iex
```
Change the path segment `hosts/g16/windows/` → `hosts/desktop/windows/`:
```
irm https://raw.githubusercontent.com/metheoryt/machines/main/hosts/desktop/windows/install.ps1 | iex
```
(Note: this URL resolves only after Phase 1 is merged to `main` — that's expected.)

- [ ] **Step 3: Find remaining path references (baseline)**

Run:
```bash
grep -rn 'hosts/g16' . --exclude-dir=.git ':!docs/superpowers/'
```
Expected: hits in `hosts/desktop/windows/backup.ps1`, `hosts/desktop/windows/windows-reinstall-runbook.md`, `install-media/README.md`, `README.md`, `AGENTS.md`, `justfile`, `.claude/memory/project.md`, `agents/hosts/*.md`. Note each.

- [ ] **Step 4: Rewrite each `hosts/g16` → `hosts/desktop`**

Replace the literal path `hosts/g16` with `hosts/desktop` in every file from Step 3. Plain path references. Do NOT touch `docs/superpowers/`. Leave the *word* `g16` where it denotes the retired NixOS identity in prose (e.g. "its old NixOS identity `g16`") — only the `hosts/g16` **path** changes.

- [ ] **Step 5: Verify no live path references remain**

Run:
```bash
grep -rn 'hosts/g16' . --exclude-dir=.git ':!docs/superpowers/'
```
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(hosts): rename hosts/g16 -> hosts/desktop; update bootstrap URL"
```

---

### Task 3: Introduce `g513ie` per-host memory via the symlink trick

**Files:**
- Move: `agents/hosts/methe-server.md` → `agents/hosts/g513ie.md`
- Create: `agents/hosts/methe-server.md` (symlink → `g513ie.md`)
- Modify: `agents/hosts/g513ie.md` (title + self-referential prose so it reads under either hostname)

**Interfaces:**
- Consumes: the `ME-G614JV.md → g614jv.md` precedent (bootstrap follows the symlink; host-memory loads by whichever hostname the box reports).
- Produces: host-memory that loads under BOTH `methe-server` (current) and `g513ie` (post-rename), so Task 5's reboot starves nothing.

- [ ] **Step 1: Rename the real file**

```bash
git mv agents/hosts/methe-server.md agents/hosts/g513ie.md
```

- [ ] **Step 2: Create the compat symlink**

```bash
ln -s g513ie.md agents/hosts/methe-server.md
git add agents/hosts/methe-server.md
```

- [ ] **Step 3: Verify the symlink resolves**

Run:
```bash
readlink agents/hosts/methe-server.md; cat agents/hosts/methe-server.md | head -1
```
Expected: `g513ie.md` then `# Host: g513ie …` (after Step 4).

- [ ] **Step 4: Update the title + dual-name prose in `agents/hosts/g513ie.md`**

Change the H1 and the "This box" line so both names are covered (mirroring `g614jv.md`'s "g614jv / ME-G614JV" style). Set the title to:
```markdown
# Host: g513ie / methe-server — ASUS ROG Strix G513IE (homeserver)
```
and ensure the Environment bullet names both: the box is the ROG Strix **G513IE** homeserver; OS hostname is `methe-server` today, **being renamed to `g513ie`** (the model code) per the hostname-normalization spec. Keep the existing G513IE model line and the Notes section intact.

- [ ] **Step 5: Verify the memory tier is consistent**

Run:
```bash
ls -l agents/hosts/
```
Expected: real files `g513ie.md`, `g614jv.md`, `latitude5520.md`; symlinks `methe-server.md → g513ie.md` and `ME-G614JV.md → g614jv.md`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(hosts-memory): g513ie.md as primary; methe-server.md -> symlink (loads under either hostname)"
```

---

### Task 4: Convention + model docs (box-independent statements only)

**Files:**
- Modify: `CLAUDE.md` (repo overview + hardware context)
- Modify: `README.md`, `AGENTS.md`, `hosts/server/README.md` — where they describe the naming convention or the server's model
- Modify: `.claude/memory/project.md` — the in-flight bullet already exists (added 2026-07-19); confirm it still reads correctly after the dir renames

**Interfaces:**
- Produces: docs that state the two-layer convention and the verified model codes, WITHOUT asserting `g513ie` as the server's *current* OS hostname (that flips in Phase 2).

- [ ] **Step 1: Update `CLAUDE.md` server line to name the model + pending rename**

In the Repository Overview, the `homeserver` bullet currently ends `… hostname methe-server; runs the cyphy.kz service platform`. Change the hostname clause to make the convention explicit and the rename visible, e.g.:
```
… — ASUS ROG **G15** 2023 (model **G513IE**), RTX 3050 Ti, Windows 11 + Docker Desktop; logical name `server`, OS hostname `methe-server` (**being renamed to `g513ie`** — the model code; see the hostname-normalization spec).
```
Leave the desktop bullet's model (`G614JV`) and the `hub` bullet as-is.

- [ ] **Step 2: Add the two-layer convention to `CLAUDE.md` Hardware Context**

Add a short subsection stating the rule: logical name (fleet key · ssh · tailnet · `hosts/<dir>`) is role-based and stable; OS hostname = `detect.hostname` = hardware model (`latitude5520`, `g614jv`, `g513ie`, `27608`); `hub`/`27608` is the VPS special-case.

- [ ] **Step 3: Reconcile `README.md`, `AGENTS.md`, `hosts/server/README.md`**

Run:
```bash
grep -rn 'methe-server' README.md AGENTS.md hosts/server/README.md
```
For each hit: if it names the *convention* or the *target*, state `g513ie` (with `methe-server` as the current/pre-rename name). If it asserts the *current verified* hostname, leave it `methe-server` (flips in Phase 2). Fix stale "ROG G16 2023" model claims for the server → "ROG G15 / G513IE".

- [ ] **Step 4: Verify project.md in-flight bullet survived the dir renames**

Run:
```bash
grep -n 'hostname-normalization\|g513ie\|hosts/desktop\|hosts/server' .claude/memory/project.md
```
Expected: the in-flight bullet references `g513ie` and the new dir names; fix any lingering `hosts/g16`/`hosts/homeserver` in it.

- [ ] **Step 5: Nix gate + full path-sweep**

Run:
```bash
bash scripts/quick-check.sh
grep -rn 'hosts/g16\|hosts/homeserver' . --exclude-dir=.git ':!docs/superpowers/'
```
Expected: quick-check passes its required-file + dry-build gate; grep returns no output.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs: state two-layer hostname convention + verified models; flag pending server rename"
```

---

### Phase 1 checkpoint

- [ ] **Offer FF merge-back of Phase 1 to `main`** (user-gated), per worktree rules, from the base checkout `/home/me/machines`:

```bash
git -C /home/me/machines merge --ff-only orca-setup-script-hint
```
First confirm the base checkout is on `main` and clean. Phase 1 is safe to land now; **do not proceed to Phase 2 tasks on `main` until Task 5 is done.**

---

## Phase 2 — the atomic flip (rides with the box reboot)

### Task 5: Rename the Windows box (USER-EXECUTED, operational)

**Files:** none in-repo. This runs on the `server` box.

**Interfaces:**
- Consumes: Phase 1 merged to `main`.
- Produces: the box now reports `$env:COMPUTERNAME = g513ie`, unblocking the Task 6 `fleet.json` flip.

- [ ] **Step 1: Pre-check restic `--host` pinning BEFORE renaming**

The homeserver is backup-hub AND backup-client. `Rename-Computer` changes the box's restic `--host` snapshot identity wherever backups run (the `vps` repo's restic config and/or Windows scheduled tasks), which forks snapshot history and breaks retention/prune filtering. Confirm how `--host` is set:
- If pinned to a fixed value (not the OS hostname) → safe to proceed.
- If it defaults to the OS hostname → decide first: pin `--host` to a stable value, or accept/curate the snapshot-host change. Do this BEFORE the reboot.

- [ ] **Step 2: Rename + reboot the box**

On `server`, elevated PowerShell:
```powershell
Rename-Computer -NewName g513ie -Restart
```

- [ ] **Step 3: Verify the new identity (after reboot)**

From any fleet box:
```bash
ssh server hostname
```
Expected: `g513ie`. (SSH/tailnet are unaffected — `server` addresses the tailnet node name, not COMPUTERNAME.)

---

### Task 6: Flip `fleet.json` + empirical statements to `g513ie`

**Files:**
- Modify: `fleet.json` (`server.detect.hostname`)
- Modify: `agents/memory/global.md` (the "verified live … OS hostnames" bullet)
- Modify: `CLAUDE.md` (drop the "being renamed" clause → state `g513ie` as current)
- Modify: `provision/fleet-authorized-keys` (key comment `methe@methe-server` → `methe@g513ie`, cosmetic)
- Modify: `.claude/memory/project.md` (mark the in-flight rename DONE)

**Interfaces:**
- Consumes: Task 5 complete (box reports `g513ie`).
- Produces: `fleet_detect()` on the server resolves to `server` again; kb reflects verified reality.

- [ ] **Step 1: Flip `detect.hostname`**

In `fleet.json`, under `machines.server.detect`, change `"hostname": "methe-server"` → `"hostname": "g513ie"`.

- [ ] **Step 2: Verify the manifest**

Run:
```bash
jq -r '.machines.server.detect.hostname' fleet.json
```
Expected: `g513ie`.

- [ ] **Step 3: Flip the empirical global.md bullet**

In `agents/memory/global.md`, the tailnet-gotcha bullet lists the real OS hostnames as `… / methe-server / 27608 (verified live 2026-07-19 …)`. Update `methe-server` → `g513ie` and bump the verified date to Task 5's date. (This statement was correct-as-of-Phase-1; it flips now that reality changed.)

- [ ] **Step 4: Finalize CLAUDE.md + provision key comment + project.md**

- `CLAUDE.md`: change the server bullet's hostname clause from "OS hostname `methe-server` (being renamed to `g513ie`)" → "OS hostname `g513ie`".
- `provision/fleet-authorized-keys`: `methe@methe-server` → `methe@g513ie` (comment only; auth is unaffected).
- `.claude/memory/project.md`: change the in-flight bullet's "PENDING … rename `methe-server` → `g513ie`" to record it as DONE (with date), keeping the convention description.

- [ ] **Step 5: Verify no stale `methe-server` remains (except intentional history)**

Run:
```bash
grep -rn 'methe-server' . --exclude-dir=.git ':!docs/superpowers/'
```
Expected: only the compat symlink `agents/hosts/methe-server.md` (kept intentionally, like `ME-G614JV.md`) and any deliberate "formerly methe-server" prose. No live assertion of `methe-server` as the current OS hostname.

- [ ] **Step 6: Nix gate**

Run:
```bash
bash scripts/quick-check.sh
```
Expected: passes (flake refs only `hosts/latitude`; unaffected).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(fleet): flip server OS hostname methe-server -> g513ie (box renamed)"
```

---

### Task 7: Verify end-to-end + integrate

- [ ] **Step 1: `fleet_detect` resolves on the renamed box**

From the `server` box (via `ssh server bash -s`), run the detect path and confirm it returns `server`:
```bash
ssh server bash -s <<'EOF'
cd ~/machines 2>/dev/null || cd /mnt/c/Users/methe/machines
source provision/lib/fleet.sh 2>/dev/null && fleet_detect
EOF
```
Expected: `server`. (Adjust the repo path to wherever `machines` is checked out on that box.)

- [ ] **Step 2: Final invariant sweep**

Run:
```bash
grep -rn 'hosts/g16\|hosts/homeserver' . --exclude-dir=.git ':!docs/superpowers/'   # -> empty
jq -r '.machines | to_entries[] | "\(.key)\t\(.value.detect.hostname)"' fleet.json   # server -> g513ie
ls -l agents/hosts/   # g513ie.md real; methe-server.md -> g513ie.md
```

- [ ] **Step 3: FF merge-back of Phase 2 to `main`** (user-gated), from the base checkout, then offer to push and to remove the worktree.

---

## Self-Review

**Spec coverage:**
- fleet.json `detect.hostname` server→g513ie → Task 6. ✓
- `agents/hosts/methe-server.md`→`g513ie.md` (+ symlink, revised from spec's "delete") → Task 3. ✓
- `ME-G614JV.md` already a symlink (no action) → honored (untouched). ✓
- Live-doc reconcile (CLAUDE.md, README, AGENTS.md, hosts/*/README, project.md, fleet-roadmap.md) → Tasks 4 + 6. ✓ (`docs/fleet-roadmap.md` folded into the Task 4 Step 3 grep-and-reconcile rule.)
- Provision literal `methe-server` → Task 6 Step 4 (only occurrence is the key comment). ✓
- Dir renames g16→desktop, homeserver→server + bootstrap URL → Tasks 1–2. ✓
- Runbook step (Rename-Computer + reboot) + restic pre-check → Task 5. ✓
- Hub `27608` untouched → honored. ✓
- `docs/superpowers/**` left as history → excluded in every grep. ✓

**Placeholder scan:** verification steps use exact grep/jq/ps commands with expected output; no "TBD"/"handle edge cases". Doc-sweep tasks specify the transformation *rule* + the verifying grep rather than pre-listing every line (correct for a mechanical rename). ✓

**Type/name consistency:** `g513ie` (OS hostname), `server` (logical/fleet key/dir), `hosts/desktop`/`hosts/server` used consistently across tasks. ✓
