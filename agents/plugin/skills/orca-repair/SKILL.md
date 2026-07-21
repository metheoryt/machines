---
name: orca-repair
description: "Use when Orca shows stale/ghost workspaces that won't go away — a workspace whose worktree or environment is gone still appears in the sidebar, and right-click Remove fails with `selector_not_found`. Prunes the orphaned view-state from this machine's orca-data.json (backup + Orca-closed guard). Read-only scan is safe with Orca open. Fleet personal machines. Invoked as /orca-repair."
---

# /orca-repair — remove ghost workspaces the UI can't delete

Orca renders a per-environment "recent workspaces" list from cached view-state in
`orca-data.json` (`workspaceSessionsByHostId`). When a worktree is deleted or an
environment is removed, its cache lingers and shows as a stale workspace. The UI
**cannot** clear it: right-click Remove maps to a worktree removal *by selector*,
which fails with `selector_not_found` because there is no worktree behind the
ghost. `orca worktree rm` fails the same way. The only fix is pruning the cache.

The helper `orca-repair.py` (this dir) detects and prunes two ghost classes:
- **Orphaned runtime block** — a `runtime:<envid>` whose environment is no longer
  in `orca environment list` (e.g. after `orca environment rm`). Dropped whole.
- **Stale recent** — a recent worktree id a live environment's registry
  (`orca worktree list --environment`) no longer reports. Pruned individually.

## The two gotchas (both cost real time if missed)

1. **`$TERM_PROGRAM` lies.** It can read `Orca` even in a plain terminal (e.g.
   Ghostty) launched from an Orca session — so it is NOT proof this session is
   inside the IDE, and killing the IDE will NOT necessarily kill your session.
   Trust the process tree / `orca-runtime.json`, not the env var. The script's
   liveness check already does this; to check by hand:
   `pstree -s $$` or `ps -o comm= -p $(ps -o ppid= -p $$)`.
2. **The IDE is Electron — a killed child respawns.** Killing one `orca-ide`
   process makes the supervisor relaunch it. To fully quit, use the app's Quit
   (or kill the main process). Clean shutdown removes `orca-runtime.json`; its
   absence is the reliable "IDE is down" signal.

## Workflow

```bash
REPAIR=~/machines/agents/plugin/skills/orca-repair/orca-repair.py

# 1. Scan — read-only, safe with Orca open. Queries live registries to find
#    stale recents; add --offline to skip the network (orphaned blocks only).
python3 "$REPAIR"
#    Know the name already? Flag it without a live query: --match log-watcher

# 2. If it lists ghosts: FULLY QUIT the Orca IDE (app Quit, not kill-a-child),
#    and confirm it's down:  test ! -e ~/.config/orca/orca-runtime.json && echo down

# 3. From a NON-Orca terminal (so quitting Orca didn't kill your shell):
python3 "$REPAIR" --apply     # backs up orca-data.json, then prunes

# 4. Reopen Orca — the stale workspaces are gone.
```

`--apply` refuses to run while the IDE is up. If a ghost's underlying git
worktree also still exists and is abandoned, remove it separately with
`git worktree remove` + `git branch -D` (verify no unmerged/unpushed work first).

## Notes

- `orca-data.json` is per-machine (not synced), so run this on whichever machine
  shows the ghosts. The default profile path is
  `~/.config/orca/profiles/local-default/orca-data.json`; pass `--data <path>` for
  another profile.
- Backups are written next to the file as `orca-data.json.bak.orca-repair.<ts>`.
- Detection/prune logic is unit-tested: `bash tests/orca-repair.test.sh`.
