# Move pure work repos to desktop; air becomes a thin Orca client

**Date:** 2026-07-31
**Status:** Phases A and D done; Phase B is the user's; teardown gated

## Progress

- **Phase A — done.** `pure/backend-api/.claude/memory/project.md` promoted from
  the `air` branch to dotfiles `main` (`f8fabab..f308bfc`). `main` now holds the
  219-line version; `main` merged back down into `air`, tree clean.
  Desktop-ubuntu26 inherits it on its next sync tick.
- **Phase D — done** for the two repo-level session dirs. 8 transcripts
  (`backend-api` 3, `claude-plugins` 5) copied to desktop under rewritten slugs,
  all 8 verified as parseable JSON on arrival. The 7 Orca-worktree session dirs
  remain on air, awaiting the user's fresh worktree names.
- **Phase B — done by the user.** All 4 repos cloned into
  `/home/me/pure` and registered with Orca's Windows runtime at
  `\\wsl.localhost\Ubuntu-26.04\home\me\pure\…`, worktree setup/teardown
  configured for each. Note the Orca registry is per-runtime: `orca repo list`
  from a WSL shell returns empty: it must be queried from the Windows side.
- **Session slug convention — verified.** The harness derives the project dir as
  a literal path-to-dashes transform, confirmed against 7 dirs it generated
  itself on desktop (`/home/me/machines` → `-home-me-machines`,
  `/home/me/my/buton` → `-home-me-my-buton`). The hand-built
  `-home-me-pure-backend-api` matches, and its 3 transcripts are in place.
- **Teardown — blocked** on the cutover gate below.

## Side effect: dotfiles promote (2026-07-31)

With air's work winding down, its drifted shared paths were surveyed and
promoted to dotfiles `main` (`f308bfc..244e37e`):

| path | change |
|---|---|
| `.claude/statusline-command.sh` | +7/−1 — `timeout` is GNU coreutils and absent on stock macOS, where it exits 127 and the empty output reads as "daemon down", showing a false ✗. Falls back to `gtimeout`, then bare. |
| `.claude/memory/global.md` | +32 — local-path plugin marketplaces snapshot rather than live-link; `sentry.thepure.team` is public while Teleport still needs the VPN |
| `.claude/memory/personality/practices.md` | +23 — "Proportion" section |
| `.claude/memory/personality/tone.md` | +5 — never cite commit SHAs in human-facing output |

Deliberately **not** promoted: `.gitconfig`, `.ssh/config`,
`.claude/host-memory.md` (host-local by design), and the `.gitignore` drift,
which consists entirely of the allow-lines for those three. air now shows zero
drift against `main`.

## Goal

Run Pure work — chiefly the heavy `backend-api` stack — on `desktop`, and drive
it from `air` through Orca's existing remote pairing, so that closing the
MacBook lid does not interrupt long-running agent sessions.

## Findings that shaped the design

Established by live probe on 2026-07-31, not assumed:

- **The agent runtime already lives on desktop.** Orca listens on
  `0.0.0.0:6768`; `orca-terminal-daemon` and native `claude` processes run
  there. Orca panes spawn as
  `wsl.exe -d Ubuntu-26.04 -- sh -c "cd '/home/me/…'"` — real Linux shells at
  native paths, *not* Git Bash over a `\\wsl.localhost\` UNC path. So lid-close
  on air was already safe; the move is about **where the repos live**, not about
  changing the execution model.
- **desktop stays awake.** `g614jv` is a laptop, but AC standby idle is
  `0x00000000` (never). Battery is 300s. Lid action is hidden in the active
  scheme — unverified, but empirically the box already hosts agent sessions.
- **Docker is live in Ubuntu-26.04** — client+server 29.6.2, compose v5.3.1, via
  Docker Desktop's WSL integration. No engine work needed.
- **Ubuntu-26.04 is the right distro.** Every Orca-registered repo on desktop is
  already `\\wsl.localhost\Ubuntu-26.04\home\me\…` (10 repos). Ubuntu-24.04 holds
  an older work checkout; consolidating on 26.04 retires it.
- **No `.venv` anywhere** — the backend-api stack is all-Docker. Nothing to
  rebuild per-platform.
- **Docker volumes on air are empty** (all postgres 0 B, one 1.7 MB media). No
  database state to migrate.
- **Resource case for the move:** desktop is 20 cores / 31 GB against air's
  16 GB, for a stack of 11 shared infra services (`postgres` ×2, `mongo`,
  `redis` single + replica + 3 sentinels, `rabbitmq`, `centrifugo`) plus
  per-worktree `pure-api-app` / `celery` / `celery-beat`.

### Non-blockers, explicitly retracted

- Ubuntu-26.04 root is 91% full (4.2 GB free of 48 GB). Initially flagged as a
  blocker; it is not. The payload is < 500 MB and Docker images live in Docker
  Desktop's own vhdx. C: has 1.17 TB free, so `wsl --manage Ubuntu-26.04
  --resize` is available whenever it becomes worth doing. Tight, not blocking.

## Target architecture

```
air (MacBook, 16GB)                desktop / g614jv (20 cores, 31GB, AC=never-sleep)
┌──────────────────┐               ┌──────────────────────────────────────────────┐
│ Orca.app         │──ws://────────▶│ Orca.exe (Windows)  0.0.0.0:6768             │
│  thin UI only    │ 100.64.0.4     │  orca-terminal-daemon                        │
│                  │  :6768         │  claude processes                            │
└──────────────────┘  tailnet       │      │ wsl.exe -d Ubuntu-26.04 -- sh -c …    │
   lid close =                      │      ▼                                       │
   UI disconnects only              │  ┌──────────────────────────────────────┐   │
                                    │  │ Ubuntu-26.04  (systemd=true)         │   │
                                    │  │  ~/pure/{backend-api,core,schema-…}  │   │
                                    │  │  Docker Desktop WSL integration ─────┼──▶ docker-desktop VM
                                    │  └──────────────────────────────────────┘   │
                                    └──────────────────────────────────────────────┘
```

## Scope

In scope: rescuing state that exists nowhere but air's disk, and carrying Claude
session history across. Out of scope: repo import (the user does this), Orca
worktree recreation (the user starts fresh), and `settings.local.json` (the user
re-authenticates Sentry on desktop).

`pure/` stays out of `fleet-selfpull`, converge, and `/ship`. Work repos keep the
pure-dev PR flow and `/ship` refuses them by design. This is a one-shot
migration, not fleet machinery.

## Phases

### Phase A — promote the newer project memory to `main`

`~/pure/backend-api/.claude/memory/project.md` is gitignored in backend-api and
is instead tracked in the private dotfiles repo at its real `$HOME` path.

- air's copy is **219 lines**, tracked, committed as `7e4c462`, working tree
  clean, and pushed to `origin/air`.
- dotfiles `main` holds a **136-line** version — that is what desktop-ubuntu26
  has checked out.
- Verified: air's copy is a **strict superset** — zero lines present in `main`
  are absent from it.

The content is therefore **not at risk** from teardown; it lives on
`origin/air`. What is wrong is only that `main` is stale, so desktop-ubuntu26
would keep working from 136 lines after the move.

Action: `/dotfiles-promote` the path from the `air` branch to `main`.
Desktop-ubuntu26 inherits it on its next pull — dotfiles' work-tree *is* `$HOME`,
so there is no copy or apply step.

*(An earlier draft called this an untracked file at risk of destruction. That was
a measurement error: `git ls-files` was run from `~/machines`, so the relative
path resolved under `machines/` and reported the file as unknown to git. Re-run
from `$HOME` it is plainly tracked. Recorded here because the same mistake is
easy to repeat with a bare-repo work-tree.)*

### Phase B — repo import (user)

The user imports `backend-api`, `backend-core`, `backend-schema-registry`, and
`claude-plugins` into `/home/me/pure` on desktop and registers them with Orca
themselves, starting from fresh worktrees.

Local-only refs worth knowing about, should the user want them rather than a
clean start from origin — these four exist on air and **not** on origin:

| branch | state on air |
|---|---|
| `metheoryt/agenda` | no upstream at all |
| `epic/CFT-4382_payment-webhook-databus` | ahead 16 |
| `task/romanyuk/CFT-4966-adr-async-payment-webhook-databus` | upstream `[gone]` |
| `task/romanyuk/orca-ide-worktree-setup` | upstream `[gone]` |

They can be pulled straight off air over the tailnet without touching origin:

```bash
git -C ~/pure/backend-api fetch ssh://air/Users/me/pure/backend-api \
  metheoryt/agenda:metheoryt/agenda \
  epic/CFT-4382_payment-webhook-databus:epic/CFT-4382_payment-webhook-databus
```

Named refs only — a `refs/heads/*:refs/heads/*` wildcard would clobber `develop`
with air's copy. `claude-plugins` needs none of this: it is fully pushed, with
both former `worktree-compose-split` commits reachable from
`origin/estimate-3-days-cap`.

### Phase C — dropped

No `settings.local.json` transfer. Every copy carried a live
`SENTRY_ACCESS_TOKEN`, and every copy was full of air-absolute paths
(`/Users/me/.local/bin/gortex` in 5 hooks, 3 allowlist entries) that would
silently no-op under WSL. The user re-authenticates Sentry on desktop instead.

The token is in the 2026-07-31 session transcript because reading these files
was explicitly authorized. Rotating it is cheap; nothing is exposed beyond the
user's own machines.

### Phase D — Claude session history

Session directories are path-keyed, so copying requires a slug rewrite:

| air | desktop |
|---|---|
| `-Users-me-pure-backend-api` (4.0 MB, 3 transcripts) | `-home-me-pure-backend-api` |
| `-Users-me-pure-claude-plugins` (8.3 MB, 5 transcripts) | `-home-me-pure-claude-plugins` |

Seven Orca-worktree session dirs (~25 MB, 19 transcripts) are **held on air**.
Their slugs depend on worktree paths that do not exist yet; they get re-keyed and
copied once the user names their fresh worktrees, or dropped on request.

Within each transcript, only the `"cwd":` field values are rewritten
`/Users/me` → `/home/me`. The remaining `/Users/me` references live in tool
output and message bodies; those are historical record and rewriting them would
falsify the transcript. In the `backend-api` dir that split was 301 `cwd` fields
against 430 total occurrences.

Note that `~/.claude/projects/<slug>/` is deliberately untracked and
machine-local — this is a one-off copy, not something that will keep syncing.

### Cutover gate and teardown

**Nothing is deleted from air until the user confirms the imported repos work on
desktop** — a pane opens, `compose.shared.yml` comes up. Confirmation is asked
for again at that moment; the earlier "delete after cutover" answer is not
standing authorization for `rm -rf`.

Teardown, in order:

1. `git worktree remove` × 6 (`5355`, `agenda`,
   `cft-1955-remove-nfozh-functionality`, `cft-4382`, `cft-4966`,
   `cft-5398-per-worktree-app-container-shared-compo`)
2. `rm -rf /Users/me/pure`
3. `docker system prune` on air — 6.8 GB images + 5.5 GB build cache, all
   inactive

## Risks

| Risk | Mitigation |
|---|---|
| desktop keeps the stale 136-line `project.md` after the move | Phase A promotes air's 219-line superset to `main` |
| Local-only branches lost with `rm -rf` | Enumerated above; user decides before the gate |
| desktop sleeps mid-session | AC standby verified `never`; lid action unverified — check if continuity ever breaks |
| Ubuntu-26.04 disk pressure (4.2 GB free) | Monitor; `wsl --manage --resize` available, C: has 1.17 TB |
| Session slugs mis-keyed | Verify `claude --resume` lists the transcripts on desktop before teardown |
