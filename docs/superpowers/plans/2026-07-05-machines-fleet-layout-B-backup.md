# Machines Fleet Layout — Plan B: cross-repo backup relocation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the restic backup system from the `vps` repo into `machines` as a top-level `backup/` subtree with machine-named profile dirs, without perturbing any stateful restic repository URL or profile name.

**Architecture:** A cross-repo relocation (two repos, two commits). Because `git mv` cannot cross repo boundaries, content is byte-copied from `~/gh/vps/backup/` into `machines/backup/`, profile *directories* are renamed to fleet machine names, and the originals are `git rm`'d from `vps`. The only couplings are a network endpoint (`rest://…`, unaffected by a repo move) and a soft semantic link to Immich (edits together, not a build break). This plan is independent of Plan A — either can land first.

**Update 2026-07-07:** g16's `laptop/` profile (`music`) has already been retired from `vps/backup/` — music is no longer stored on g16, so there's nothing left to relocate for it. Only two profile dirs remain to move: `homeserver/` and `wsl/` (→ `g16-wsl/`). Steps below are updated accordingly.

**Tech Stack:** restic + resticprofile (YAML profiles inheriting a shared `base.yaml`), Windows `.bat` / WSL `.sh` scheduled-task installers, git across two repos.

## Global Constraints

- **Reference spec:** `docs/superpowers/specs/2026-07-05-machines-fleet-layout-design.md` §2, §2b-adjacent.
- **FROZEN — never change:** the restic **repository URLs/paths** inside `profiles.yaml` (`G:\backup-homeserver\…`, `rest:http://server.lan:8001/wsl`) and the **profile names**. These name stateful backends and scheduled tasks; changing them orphans existing snapshots. Only *directory* names change.
- **Content is copied byte-for-byte** from `vps`; the machines copy of each file (other than the dir path) must be identical to the vps original. Verify with `diff`.
- **Repos:** source `~/gh/vps`, destination `/home/me/gh/machines`.
- **Machine mapping:** `homeserver/` = g16-2023 (Immich); `wsl/` → `g16-wsl/` = WSL inside g16-2024 (daily driver). (g16's own `laptop/` music profile was retired — no longer relocated.)

---

### Task 1: Copy the backup subtree into `machines/backup/` with renamed dirs

**Files:**
- Create (copied from `~/gh/vps/backup/`): `machines/backup/base.yaml`, `machines/backup/restic-install.bat`, `machines/backup/restic-install.sh`
- Create: `machines/backup/homeserver/{install-tasks.bat,profiles.yaml}`
- Create (renamed from `wsl/`): `machines/backup/g16-wsl/{.resticignore,install-tasks.sh,profiles.yaml}`
- Modify: `machines/.gitignore` (backup secret globs, if missing)

**Interfaces:**
- Consumes: the `vps` repo's `backup/` subtree as read-only source.
- Produces: `machines/backup/` with `base.yaml`, `restic-install.*`, and profile dirs `homeserver/`, `g16-wsl/`. Profile names and repo URLs inside are unchanged from `vps`.

- [ ] **Step 1: Copy the whole subtree, then rename the one dir**

```bash
cd /home/me/gh/machines
cp -r /home/me/gh/vps/backup ./backup
git mv backup/wsl     backup/g16-wsl
```

(`cp` first so untracked files like `.resticignore` come along; the `git mv` renames+stages the subdir. `git add` in step 4 picks up the rest.)

- [ ] **Step 2: Prove the copied content is byte-identical to the vps originals**

Only directory names may differ — file contents must match exactly (this is the frozen-URL guarantee):

```bash
cd /home/me/gh/machines
diff /home/me/gh/vps/backup/base.yaml           backup/base.yaml           && echo "base.yaml OK"
diff /home/me/gh/vps/backup/restic-install.bat  backup/restic-install.bat  && echo "restic-install.bat OK"
diff /home/me/gh/vps/backup/restic-install.sh   backup/restic-install.sh   && echo "restic-install.sh OK"
diff -r /home/me/gh/vps/backup/homeserver backup/homeserver && echo "homeserver/ OK"
diff -r /home/me/gh/vps/backup/wsl        backup/g16-wsl    && echo "g16-wsl/ (was wsl) OK"
```

Expected: every `diff` empty, every `... OK` printed.

- [ ] **Step 3: Confirm the frozen strings are present and unchanged**

```bash
cd /home/me/gh/machines
git grep -n 'rest:http://server.lan:8001/wsl'          backup/g16-wsl/  ; echo "^ URL preserved"
git grep -nE 'backup-homeserver' backup/homeserver/                     ; echo "^ URL preserved"
# Profile names must be unchanged — spot-check the profile keys still match vps:
grep -hE '^\s*[a-z0-9-]+:\s*$' /home/me/gh/vps/backup/wsl/profiles.yaml
grep -hE '^\s*[a-z0-9-]+:\s*$' backup/g16-wsl/profiles.yaml
# ^ the two profile-name lists must be identical
```

- [ ] **Step 4: Confirm base.yaml inheritance path still resolves**

The profile dirs stayed at the same depth (`backup/<name>/`), so any `../base.yaml`-style include in a `profiles.yaml` is unaffected by the sibling rename. Verify no `profiles.yaml` references `base.yaml` by an *absolute* or `wsl/`-embedded path:

```bash
cd /home/me/gh/machines
git grep -nE 'base\.yaml|/wsl/' backup/*/profiles.yaml
# any base.yaml include must be relative (e.g. ../base.yaml) and contain no old dir name
```

- [ ] **Step 5: Carry the backup-secret gitignore globs**

Ensure `machines/.gitignore` ignores restic passwords and env files (these live beside the profiles and must never be committed):

```bash
cd /home/me/gh/machines
grep -qE '(^|/)\*\*/pass\.txt$|pass\.txt' .gitignore || printf '\n# restic backup secrets\n**/pass.txt\n' >> .gitignore
grep -qE '\*\*/\.env' .gitignore || printf '**/.env\n' >> .gitignore
git check-ignore backup/homeserver/pass.txt   # expect it to print the path (i.e. ignored)
```

- [ ] **Step 6: Commit (machines side)**

```bash
cd /home/me/gh/machines
git add -A
git commit -m "backup: relocate restic system from vps into machines/backup/ (wsl->g16-wsl); freeze repo URLs + profile names"
```

---

### Task 2: Remove `backup/` from `vps` and repoint its docs

**Files (in the `vps` repo):**
- Delete: `vps/backup/` (whole subtree)
- Modify: `vps` `README.md` and `CLAUDE.md` (remove the "Backups" section; add a pointer)

**Interfaces:**
- Consumes: nothing from Task 1 at the file level (independent repo), but should land *after* Task 1 is committed so the content exists in `machines` before it leaves `vps`.
- Produces: `vps` no longer carries backup clients; it keeps only the restic REST *server* service (`homeserver/restic-server/`).

- [ ] **Step 1: Delete the subtree from vps**

```bash
cd /home/me/gh/vps
git rm -r backup
```

- [ ] **Step 2: Repoint the vps docs**

In `~/gh/vps/CLAUDE.md` and `~/gh/vps/README.md` (whichever carry the "Backups" section — CLAUDE.md does), remove the `## Backups` section and replace with a one-line pointer:

```markdown
## Backups

Backup **clients/schedules** (restic + resticprofile) now live in the
[`machines`](../machines) repo at `backup/`. This repo runs the restic REST
**server** as a service (`homeserver/restic-server/`) — the clients back up to
it over the WireGuard tunnel.
```

Verify no stale references to the deleted paths remain in vps docs:

```bash
cd /home/me/gh/vps
git grep -nE 'backup/(base\.yaml|homeserver|wsl)|restic-install' -- '*.md' ; echo "^ must be EMPTY"
```

- [ ] **Step 3: Confirm the restic server service is untouched**

```bash
cd /home/me/gh/vps
git status --short homeserver/restic-server/   # expect: no changes
test -f homeserver/restic-server/compose.yml && echo "restic-server service intact"
```

- [ ] **Step 4: Commit (vps side)**

```bash
cd /home/me/gh/vps
git add -A
git commit -m "backup: move restic clients to the machines repo; keep restic-server service"
```

---

## Post-deploy operational note (not a repo step)

On each affected machine (g16-2024's WSL, and the homeserver for Immich), the
restic scheduled tasks were registered against the old working-copy path
(`…\vps\backup\…`). After that machine pulls this relocation, **re-run the
installer from the new location** so the scheduled tasks point at
`…\machines\backup\<machine>\`:

- Windows (homeserver): from the new dir, `install-tasks.bat`.
- WSL (g16-wsl): from the new dir, `bash install-tasks.sh`.

Existing snapshots are untouched — the repository URLs never changed, so restic
continues the same backend history.

## Final verification (whole plan)

- [ ] `machines/backup/` contents `diff`-identical to the pre-move `vps/backup/` except the two renamed dir names.
- [ ] `git grep` in `machines/backup/` shows the three restic URLs and all profile names byte-for-byte as they were in `vps`.
- [ ] `machines/.gitignore` ignores `**/pass.txt` and `**/.env`; `git check-ignore` confirms.
- [ ] `vps` no longer contains `backup/`; its docs point at `machines`; `homeserver/restic-server/` is unchanged.
