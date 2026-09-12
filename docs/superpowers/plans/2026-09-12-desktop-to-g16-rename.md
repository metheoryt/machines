# Rename `desktop` → `g16` (and `desktop-wsl` → `g16-wsl`)

Decided 2026-09-12. Status: **DONE** — repo and live moves both.
Written before a context compact — everything below was measured in that
session, so do not re-derive it.

## Corrections found while executing (2026-09-12)

- **Headscale nodes 3 and 9 were already gone** when the rename ran — the
  debris item below is stale. Do not hunt for them.
- **`g16` has THREE earlier referents, all this same hardware**, not two: the
  retired NixOS install, AND the `hosts/g16/` directory that `ea0409c` renamed
  to `hosts/desktop/` on 2026-07-20. So this rename is a partial revert.
- **The WSL distro's Windows REGISTRATION stays `desktop-wsl`.** Renaming it
  means export/import or a registry edit and would move `\\wsl$\<name>` and
  Docker Desktop's integration list with it. Nothing needs it to match the
  nickname: `fd_wsl_hosts` reads the distro name from `wsl -l -q` live and pairs
  it with whatever `fleet.local.json` declares, so the dispatch target is
  `g16:desktop-wsl`.
- **The installed restic unit hard-codes the old path.**
  `resticprofile-backup@profile-wsl.service` carries
  `WorkingDirectory=.../backup/desktop-wsl`, so the 06:00 job fails into nothing
  the moment the directory is renamed. Re-running `backup/g16-wsl/install-tasks.sh`
  is part of the change, not a follow-up. No test can see this.
- **`origin/server` and `origin/g15-wsl` are NOT debris to delete.** A dotfiles
  machine branch is the only copy of that box's host-local files — they are
  absent from `main` by design. Tag before any deletion, or leave them.
- **The gate is 59 suites here, not 37.** Green, 0 failures, after the rename.

## Why

`desktop` is the only logical name in the manifest that lies: the box is an ASUS
ROG **G16** laptop, and three of five fleet members are laptops, so the word
distinguishes nothing. Same defect that got `server` renamed on 2026-08-27 — a
role name outliving its role.

It is also an overloaded token: the word appears 1424 times in this repo and
only a handful of those are the machine. The rest are `.desktop` files,
`ORCA_INSTALL_MODE=desktop`, `ubuntu-desktop`, `%USERPROFILE%\Desktop`. **Never
`sed` this rename repo-wide** — that noise is why.

## Two facts that set the shape (measured 2026-09-12, do not re-check blindly)

- **`g16` is a REUSED token.** It was the logical name of the retired NixOS
  install on this same hardware (deleted 2026-07-08, `hosts/g16/` gone). Docs and
  git history use `g16` for that install. Same physical machine, so the confusion
  is mild — but AGENTS.md must say so in one line, or an old `g16` reference
  reads as the current Windows box. `g15` had no such collision.
- **The restic repository is NOT affected.** Its path segment is `g614jv` — the
  Windows hostname, which is also the htpasswd username `--private-repos` maps to
  a top-level directory (`backup/desktop-wsl/profiles.yaml` documents this). The
  logical name is not in the repo path, so nothing moves on the backup hub.
  The *directory* `backup/desktop-wsl/` is named for the WSL nickname and does
  move — that is a git rename, not a repository migration.

## What must move in one change (AGENTS.md: "or it moves nothing")

1. `fleet.json` — the `desktop` key. Note `detect.hostname` stays `g614jv`: that
   is the OS-hostname layer and is already model-based.
2. `hosts/desktop/` → `hosts/g16/` (`windows/` + `wsl/`). Role executors resolve
   `hosts/<machine>/<platform>/`, so the directory name IS the manifest name.
3. Tailnet node name in Headscale.
4. dotfiles branch `desktop` → `g16` (and `desktop-wsl` → `g16-wsl`), on origin
   and locally. The sync timer records the expected branch at
   `~/.local/state/dotfiles-sync/branch` and REFUSES to run when HEAD is not on
   it — update that file on the box or sync stops silently.
5. `fleet-authorized-keys`.
6. `self.parent` in desktop-wsl's gitignored `fleet.local.json`, plus its
   `nickname`. Written by `provision/fleet-local.sh`
   (`--parent <alias>`), so re-run `just provision-wsl g16-wsl` rather than
   hand-editing. `fd_probe`/`fd_run` key on `self.parent`, and a wrong value
   makes a fleet-wide run print a green row for the wrong machine.
7. `backup/desktop-wsl/` → `backup/g16-wsl/` (identity dir = nickname). Check
   `install-tasks.sh` inside it for the old name.
8. `.claude/kb-harvest-state.json` keys `desktop-wsl` / `desktop-ubuntu26` — history
   only; decide whether to rewrite or leave as provenance.

Windows `~/.ssh/config` needs no manual work: its `fleet-ssh` block is rendered
from `fleet.json` by `provision/lib/fleet-ssh-config.ps1` on a `windows.ps1` run.

## Fixtures that are NOT the machine

`agents/plugin/skills/lib/tests/fleet-dispatch.test.sh` uses `desktop` as a test
fixture throughout. Renaming it is cosmetic and optional; renaming it *wrongly*
breaks the suite. Leave it unless the diff is clean.

## Clean up the previous rename's debris while here

The 2026-08-27 `server` → `g15` rename left tails, found 2026-09-12:

- dotfiles: `origin/server` (last commit 2026-07-28) and `origin/g15-wsl` (the
  distro destroyed 2026-09-07), plus a stale local `server` ref.
- Headscale nodes 3 (`g15-retired`) and 9 (`g15-wsl`), both dead and still listed.

## Gate

`just test` — but `just` is NOT installed on desktop-wsl. Run the gate's own
suite list by hand there:
`for t in $(find . -name '*.test.sh' -not -path './.git/*'); do bash "$t"; done`
and check exit codes, not `ALL PASS` strings. Green on 2026-09-12: 37 suites.

## Still open from the 2026-09-12 Orca session (unrelated to the rename)

- Two orphaned Orca runtime blocks in the Windows store must be pruned BEFORE
  the remote servers are re-paired — after re-pairing the environment ids change
  and the old blocks can no longer be matched against anything:
  `python3 ~/machines/agents/plugin/skills/orca-repair/orca-repair.py --apply --data /mnt/c/Users/methe/AppData/Roaming/orca/profiles/local-default/orca-data.json`
  (refuses while the Orca UI is up).
- The "wsl memory harvest" automation (weekly Sa 14:20, `/cyphy:memory-harvest`
  in `machines`) was deleted by the user, who is restoring it himself.

## What was actually done, 2026-09-12

Repo (`c04dc49`): `fleet.json` key, `hosts/desktop/` -> `hosts/g16/`,
`backup/desktop-wsl/` -> `backup/g16-wsl/` plus every cross-reference,
`fleet-authorized-keys` (both comments + a header that now lists two renames),
AGENTS.md / README.md / provision README / the live roadmap, the `irm ... | iex`
bootstrap URL in `install.ps1` and the runbook paths it names, a both-arms
assertion in `fleet-profile.test.sh`, and a preamble in `.claude/memory/project.md`
instead of a sweep. Gate: 59 suites, 0 failures.

Live:

- Headscale node 4 `desktop` -> `g16`, node 6 `desktop-wsl` -> `g16-wsl`.
  Node 6's *Hostname* stays `desktop-ubuntu26` — that is the distro's OS
  hostname, a layer this rename does not touch.
- dotfiles: branches renamed local+origin on both checkouts (`desktop` -> `g16`
  on the Windows side, `desktop-wsl` -> `g16-wsl` in the distro), both
  `~/.local/state/dotfiles-sync/branch` files updated, `sync_guard` verified
  rc=0. `origin/desktop` and `origin/desktop-wsl` deleted only after proving
  `rev-parse` equality with the new refs. Two stale LOCAL refs (`server`,
  `desktop`, both at `d298774`) deleted after proving `merge-base --is-ancestor`
  against `origin/g15` / `origin/g16` — redundancy proven, not assumed.
  `origin/server` and `origin/g15-wsl` turned out to be already gone from the
  remote; what the earlier session saw were stale remote-tracking refs.
- `fleet.local.json` rewritten through `fleet-local.sh` (nickname `g16-wsl`,
  parent `g16`); `fd_local_parent` -> `g16` and `fd_probe g16 windows` takes the
  interop branch.
- restic schedule reinstalled: the unit's `WorkingDirectory` now names
  `backup/g16-wsl`, timer still armed for 06:00.
- `~/.ssh/config` fleet block re-rendered on `g16` (PowerShell renderer, after
  pulling that checkout) and inside `g16-wsl`. latitude/g15/hub could NOT be
  fixed — see the P3 finding below.
- `provision.sh --machine g16` exits 0, `--machine desktop` exits 2.

## What this rename UNCOVERED (not caused): P3's ssh gap

No Debian box renders fleet `Host` blocks at all — `tier_fleet_ssh` is
darwin-only and `tiers.test.sh` pins that. latitude's and g15's `~/.ssh/config`
are 444 bytes, account blocks only. Hand-writing the block does not survive:
`fleet-selfpull.timer` + a changed `fleet.json` reprovisions the box within one
timer interval and rewrites the file from `tier_ssh_accounts` alone (measured —
a hand-merged block on g15 was gone inside ten minutes). Written up in
`docs/fleet-roadmap.md` P3, first item, which was also corrected: its claim that
latitude has no GitHub account block is out of date.

