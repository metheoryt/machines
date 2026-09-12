# Rename `desktop` → `g16` (and `desktop-wsl` → `g16-wsl`)

Decided 2026-09-12. Status: **not started.** Written before a context compact —
everything below was measured in that session, so do not re-derive it.

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
