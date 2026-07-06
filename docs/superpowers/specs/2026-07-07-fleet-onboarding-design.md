# Fleet onboarding — unified provisioning tier + routing index — design

**Date:** 2026-07-07
**Status:** approved (design), pending implementation plan
**Scope:** one repo — `machines`. (1) Renames/moves + doc coherence for the
provisioning tier — no behaviour change to the moved scripts beyond
self-reference fixes. (2) A new `provision/repos.sh` that clones your repos into
a declared per-account home-dir layout.
**Supersedes:** decision #9 of `2026-07-05-machines-fleet-layout-design.md`
(WSL provisioning home `hosts/g16/wsl/`).

## Problem

Onboarding a machine currently has a different entry point per box, and two of
them are mis-placed:

| Box kind | Today's entry point | Problem |
|----------|---------------------|---------|
| NixOS (g16, latitude5520) | `just switch` | fine |
| Windows (ME-G614JV, methe-server) | `hosts/g16/windows/bootstrap-agents.ps1` | **fully generic**, yet filed under one host; homeserver is Windows too |
| WSL / non-Nix Linux | `bootstrap/ubuntu.sh` | framed "disposable-only"; persisted boxes not modelled |
| agent config only | `agents/bootstrap.sh` | the portable core the others call |

The word "bootstrap" names **three** different things (the `bootstrap/` dir,
`agents/bootstrap.sh`, the Windows `bootstrap-agents.ps1`) — the collision is
itself part of the confusion. There is no single place that answers "new box —
what do I run?"

The git-autofetch work just added to `bootstrap/ubuntu.sh` (`e6ceaf7`: systemd
user timer / cron fallback, refs-only) only makes sense on a box you keep —
confirming a persisted WSL distro is meant to be a first-class fleet
participant, not a throwaway.

## Decisions taken (brainstorm)

1. **Persisted WSL = lightweight imperative, no Nix.** No home-manager-standalone
   on WSL. It stays apt + `agents/bootstrap.sh` + best-effort CLI tools.
2. **Persisted vs disposable = same script, differ only in lifespan.** One WSL
   bootstrap, identical result everywhere; "persisted" just means you don't
   `wsl --unregister` it. No tiers, no flags.
3. **Shared provisioning tier + routing index.** Promote the generic scripts to
   one shared top-level home; a README table routes each box kind to one command.

## Organizing idea

Provisioning the portable agent/dev layer is a **cross-cutting, shared** concern
— generic across hosts and distros — not a per-host one. It becomes a top-level
tier (`provision/`), a peer of `install-media/` (the OS-install phase) and
`agents/` (the config it links). The per-host `hosts/<h>/` dirs keep only what is
genuinely machine-specific (NixOS hardware config; that box's Windows reinstall
runbook, backup, restore). This mirrors the 2026-07-05 spec's own move of
promoting the generic `autounattend.xml` out of `hosts/g16/` into shared
`install-media/`.

Naming: the tier is **`provision/`** (a distinct verb — resolves the triple
"bootstrap" collision; `agents/bootstrap.sh` keeps its name in its own scope).
The Linux script is **`linux.sh`** (runs on any glibc apt Linux; WSL is the
primary use — the README says so).

## Target tree

```
machines/
  provision/                 # NEW shared tier (renamed from bootstrap/) — post-OS-install agent/dev layer
    windows.ps1              #   git mv  hosts/g16/windows/bootstrap-agents.ps1  (generic; serves g16 AND homeserver)
    linux.sh                 #   git mv  bootstrap/ubuntu.sh                      (any glibc apt Linux; persisted or throwaway; incl. git-autofetch)
    README.md                #   git mv  bootstrap/README.md                     (reframed: not "disposable-only")
    .gitattributes           #   git mv  bootstrap/.gitattributes
    repos.sh                 #   NEW — clone repos into ~/my, ~/pure, ~/cyphy671 via gh discovery
    repos.txt                #   NEW — committed; the curated thepureapp ("pure") repo list (names public-safe)
  agents/bootstrap.sh        # UNCHANGED — the portable core both scripts call (links agent config)
  install-media/             # UNCHANGED — the OS-install phase; peer of provision/
  hosts/
    g16/windows/             # keeps ONLY genuinely g16-Windows-specific bits:
                             #   backup.ps1  restore.ps1  install.ps1  winget-packages.json
                             #   windows-reinstall-runbook.md  git-autofetch.ps1
  README.md                  # NEW "Onboarding — start here" routing table near the top
```

## Routing index (the actual cure for "what do I run where")

Added near the top of `README.md`:

| Box kind | One command |
|---|---|
| **NixOS** — g16, latitude5520 | `just switch` (home-manager owns the agent links) |
| **Windows** — ME-G614JV, methe-server | `provision\windows.ps1` (`-Work` adds the work profile) |
| **WSL / any glibc Linux** — persisted *or* throwaway (incl. Ubuntu 26.04) | `bash provision/linux.sh` |

> *All three already link your synced agent config for you (via
> `agents/bootstrap.sh`). To re-link only that — e.g. after editing config — run
> `bash agents/bootstrap.sh` (or `just agent-bootstrap`); on NixOS `just switch`
> handles it. To clone your working repos into the `~/my` · `~/pure` ·
> `~/cyphy671` layout, run `bash provision/repos.sh` (also offered as the last,
> best-effort step of `linux.sh` / `windows.ps1`).*

## Change set

### 1. Moves (all `git mv`, history preserved)

- `hosts/g16/windows/bootstrap-agents.ps1` → `provision/windows.ps1`
- `bootstrap/ubuntu.sh`   → `provision/linux.sh`
- `bootstrap/README.md`   → `provision/README.md`
- `bootstrap/.gitattributes` → `provision/.gitattributes`
- `bootstrap/` directory is removed (now empty).

`hosts/g16/windows/` keeps `backup.ps1`, `restore.ps1`, `install.ps1`,
`winget-packages.json`, `windows-reinstall-runbook.md`, `git-autofetch.ps1` —
these are genuinely g16-Windows-specific (that box's reinstall/backup flow).

### 2. `provision/windows.ps1` internal fixes (was at depth 3, now depth 1)

- Repo-root resolver: `Resolve-Path (Join-Path $PSScriptRoot '..\..\..')` →
  `'..'` (the script now lives one level below the repo root, not three). This
  is the one **behavioural** edit — verify the new path resolves to the repo
  root that contains `agents\bootstrap.sh`.
- Usage examples in the header comment: `.\bootstrap-agents.ps1 …` →
  `.\provision\windows.ps1 …`.
- The `agents\bootstrap.sh` not-found guard and the Git-Bash invocation are
  path-independent (they derive from `$RepoDir`) — unchanged.

### 3. `provision/linux.sh` + `provision/README.md` reframe

- Self-references inside `linux.sh` (`bootstrap/ubuntu.sh`, "this script lives in
  `<repo>/bootstrap/`", the three `See bootstrap/README.md` die messages, the
  git-autofetch comment header) → `provision/linux.sh` / `provision/README.md`.
- `provision/README.md`: retitle from "Disposable-distro bootstrap" to cover
  **persisted or disposable** glibc Linux (same script either way; persisted just
  means you keep it). Update the `git clone … && bash …/bootstrap/ubuntu.sh`
  usage to `provision/linux.sh`. Keep the multi-account SSH / git-identity and
  base-distro sections as-is (content unchanged).

### 4. Wiring the moves force (grep-verified before applying)

References that must be repointed (from the reference sweep):

- `justfile` lines 8 & 62 (comment): `hosts\g16\windows\bootstrap-agents.ps1` →
  `provision\windows.ps1`.
- `hosts/g16/windows/restore.ps1:203` (printed next-step hint):
  `.\hosts\g16\windows\bootstrap-agents.ps1 -BackupRoot …` →
  `.\provision\windows.ps1 -BackupRoot …`.
- `hosts/g16/windows/backup.ps1:27` (doc comment naming the restore-side script)
  → `provision\windows.ps1`.
- `hosts/g16/windows/install.ps1`: any `bootstrap-agents.ps1` /
  `hosts\g16\windows\…` path or raw-githubusercontent URL that pointed at the
  moved script → `provision\windows.ps1`.
- `hosts/g16/windows/windows-reinstall-runbook.md`: `bootstrap-agents.ps1`
  step(s) → `provision\windows.ps1`.
- `README.md` lines ~21 and ~108–112 (the `bootstrap/` description + section) →
  the new `provision/` framing (folded into the new routing table + section).
- `modules/system/git-autofetch/README.md:13`: `inlined in bootstrap/ubuntu.sh`
  and the `(disposable box)` label → `provision/linux.sh`, "persisted or
  disposable".
- `agents/hosts/G614JV.md:17`: if it names the old script/path, update it.
- `CLAUDE.md` / `AGENTS.md`: if they carry a `bootstrap/` or Windows-onboarding
  path, fold into the routing framing.

Historical specs under `docs/superpowers/` are **left unchanged** (they record
what was decided at their date; this spec supersedes #9 in prose above).

### 5. Doc coherence

- `README.md`: add the **Onboarding — start here** routing table near the top;
  replace the old `bootstrap/` bullet/section with a `provision/` one; note
  `provision/` is a peer of `install-media/` (post-install vs install phase).

## Component: `provision/repos.sh` — clone repos into a declared layout

Host-agnostic bash (Git Bash on Windows, native on Linux/macOS). Clones the repos
you work in into a per-account home-dir layout, each via the SSH alias that
matches its GitHub account so key **and** commit identity line up. Clone-if-absent
only — git-autofetch keeps them current after. Best-effort: if `gh` is missing or
unauthed, warn and continue (like `linux.sh`'s other optional steps).

### Groups

| Dir (`~/…`) | GitHub owner | gh account / SSH alias | Selection |
|---|---|---|---|
| `my`       | `metheoryt` (personal) | metheoryt / `github.com`   | all non-archived |
| `pure`     | `thepureapp` (org)     | metheoryt / `github.com`   | curated few (committed `repos.txt`) |
| `cyphy671` | `cyphy671` (2nd acct)  | cyphy671 / `github-cyphy`  | all non-archived (its one project) |

`exactly` is intentionally absent — archived namespace, no access.

### Discovery

For an all-non-archived group: `gh repo list <owner> --no-archived --json name`
→ clone each as `git@<alias>:<owner>/<name>.git` into `~/<dir>/<name>`. `gh` must
be authed as the owning account; the script runs `gh auth switch --user
<account>` before listing a group whose account differs from the current one
(`linux.sh` already logs `gh` into every declared account). Config is a small
declared table at the top of the script, in the same style as `linux.sh`'s
`SSH_ACCOUNTS` / `GIT_IDENTITIES` arrays.

### The `pure` list (`repos.txt`)

The two all-non-archived groups (`my`, `cyphy671`) commit **zero** names —
discovery reads them live from GitHub. The `pure` group is a curated few, listed
in a committed **`provision/repos.txt`** (one `owner/repo` or bare repo name per
line; comments with `#`). Decision: the `thepureapp` repo names are **public-safe**,
so the list is tracked normally and syncs across machines like the rest of the
config — no gitignore/`repos.local` seam. `repos.sh` reads `repos.txt` for the
`pure` group and skips it cleanly if the file is empty/absent. (Only repo *names*
live here — never tokens or credentials.)

### Commit-identity note (flagged, not built here)

`my` and `pure` share the `github.com` SSH alias, so the existing remote-URL
`includeIf` cannot separate them. If `thepureapp` commits need a distinct author
email, that requires a directory-based `includeIf "gitdir:~/pure/"`; otherwise
`pure` uses the global `metheoryt@gmail.com` identity. `cyphy671` keeps its
remote-alias identity from the existing machinery. The identity *wiring* lives in
`linux.sh`'s SSH/identity section — `repos.sh` only places the clones. Adding the
`gitdir:~/pure/` include is out of scope unless requested.

### Invocation

Standalone (`bash provision/repos.sh`) and, best-effort, the last step of
`provision/linux.sh` and `provision/windows.ps1` (after `gh` auth). Optional on a
Windows host where you may only want repos inside WSL — never forced.

## Explicitly out of scope

- **No Nix on WSL / no home-manager-standalone** (decided).
- **`exactly` namespace** — archived, no access; not cloned.
- **`gitdir:~/pure/` commit identity** — flagged above; add only if requested.
- **No `just onboard`** universal command (rejected — `just` is finicky on
  Windows, NixOS needs the flake path; over-engineered for the goal).
- **`linux.sh` contents unchanged** beyond self-reference fixes — it already
  installs the toolset and (as of `e6ceaf7`) git-autofetch.
- **Homeserver OS-reinstall runbook** stays deferred (per 2026-07-05 spec §5);
  this design only makes `provision/windows.ps1` reusable *for* it.
- **`backup/g16-wsl/`** (the WSL backup profile) is untouched — that is the
  genuinely per-host WSL artifact and stays in the fleet backup tree.

## Verification

- `git mv` for all four moves — each file's diff is a pure rename plus the
  intended in-file reference edits; no spurious whole-file churn.
- Grep sweep confirms **zero** remaining references to `bootstrap-agents.ps1`,
  `bootstrap/ubuntu.sh`, or the `bootstrap/` directory outside `docs/`.
- `provision/windows.ps1`: the `'..'` root resolver reaches a dir containing
  `agents\bootstrap.sh` (the script's own existing guard throws otherwise —
  confirm by inspection; not executed here, no clean Windows box in this
  session).
- `just quick` still passes (the justfile edits are comment-only).
- README routing table lists exactly one command per box kind, each pointing at
  a path that now exists.
- `provision/repos.sh`: dry-run prints the intended `git@<alias>:<owner>/<name>`
  clone URLs per group and target dir without cloning; `provision/repos.txt`
  parses (comments/blank lines skipped); no token/credential appears in any
  committed file (grep for token-shaped strings across tracked files → none).

## Decisions log

1. Provisioning is a shared cross-cutting tier, not per-host → top-level
   `provision/`, peer of `install-media/` and `agents/`.
2. Tier name **`provision/`** (resolves the triple-"bootstrap" collision).
3. Linux script **`linux.sh`** (any glibc apt Linux; WSL primary).
4. Persisted WSL is lightweight imperative, no Nix; same script as disposable,
   differ only in lifespan.
5. Move the generic Windows orchestrator out of `hosts/g16/windows/`; leave the
   genuinely-g16 reinstall/backup/restore scripts there.
6. **Supersede** 2026-07-05 decision #9: WSL provisioning lives in shared
   `provision/linux.sh`, not `hosts/g16/wsl/` — it is generic. The per-host WSL
   artifact that remains is `backup/g16-wsl/` (data).
7. A README "start here" routing table is the primary deliverable — one command
   per box kind.
8. No `just onboard`; no Nix on WSL. YAGNI.
9. New `provision/repos.sh`: clone repos into `~/my` (metheoryt, all),
   `~/pure` (thepureapp, curated few), `~/cyphy671` (cyphy671 acct, all). `gh`
   discovery for the "all" groups → zero names committed. `exactly` dropped.
10. The `thepureapp` ("pure") subset is committed to `provision/repos.txt`
    (names deemed public-safe) and syncs like the rest of the config — no
    gitignore/`repos.local` seam. Only names, never tokens.
11. Commit identity for `pure` (`gitdir:~/pure/` include) flagged, out of scope
    unless requested — `my`/`pure` share the `github.com` alias.
