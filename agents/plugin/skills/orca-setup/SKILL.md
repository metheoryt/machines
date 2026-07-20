---
name: orca-setup
description: "Use when the user wants to set up (or re-check) a repo for Orca-managed worktrees — one-time per repo. Scaffolds the repo's committed .orca/worktree-setup.sh custom-rules delegate and PRINTS the Orca setup-script one-liner for the user to paste into Orca's per-repo settings. Never writes Orca config, never closes the IDE. Fleet-sync personal repos only; refuses work/Pure repos. Invoked as /orca-setup."
---

# /orca-setup — wire a repo for Orca-managed worktrees

Runs in your session. It does the parts worth automating — the guard, the
committed `.orca/worktree-setup.sh` scaffold, and a **read-only** check of the
current Orca wiring — then hands YOU the exact setup-script command to paste into
Orca's UI. It never edits `orca-data.json` and never asks you to close Orca.

Background: `scripts/orca-worktree-setup.sh` is the shared dispatcher Orca runs on
each fresh worktree; it links generic gitignored config, then delegates to this
repo's `.orca/worktree-setup.sh`. Overlay conventions for the working agent live
in `cyphy:worktree-agent`.

## Step 1 — Guard & identity

1. `git remote get-url origin` — if it matches `thepureapp/`, STOP: work repos
   use the pure-dev PR flow, not /orca-setup.
2. Resolve the base checkout (Orca keys its entry to it, not to a worktree path):

   ```bash
   common=$(git rev-parse --git-common-dir)
   case "$common" in /*|[A-Za-z]:*) : ;; *) common=$(cd "$(git rev-parse --show-toplevel)" && cd "$common" && pwd) ;; esac
   BASE=$(dirname "$common")
   ORIGIN=$(git -C "$BASE" remote get-url origin)
   ```

## Step 2 — Scaffold `$BASE/.orca/worktree-setup.sh` (committed → synced)

Copy the template verbatim if the repo has no delegate yet; if it exists, DO NOT
clobber — show a diff and only offer to refresh the marker-delimited managed
blocks.

```bash
TEMPLATE=~/machines/agents/plugin/skills/orca-setup/worktree-setup.template.sh
DEST="$BASE/.orca/worktree-setup.sh"
if [ -e "$DEST" ]; then
  diff -u "$DEST" "$TEMPLATE" || true   # show what a refresh would change; ask the user
else
  mkdir -p "$BASE/.orca" && cp "$TEMPLATE" "$DEST" && chmod +x "$DEST"
fi
```

Tell the user this file is committed and syncs across the fleet, and that
repo-specific steps go in the `orca-setup:managed:repo-steps` block. Gortex
readiness is opt-in — it runs only when the worktree is created with
`ORCA_GORTEX=1` in the environment. Offer to `git add "$DEST"`.

## Step 3 — Print the setup command (read-only status; no writes)

Check how the repo is currently wired, then print guidance. This reads
`orca-data.json` read-only — safe with Orca open.

```bash
DATA="$HOME/.config/orca/profiles/local-default/orca-data.json"
DISPATCH='bash "$HOME/machines/scripts/orca-worktree-setup.sh"'
STATUS=$(~/machines/agents/plugin/skills/orca-setup/orca-status.sh "$DATA" "$ORIGIN" "$DISPATCH" "$BASE")
echo "$STATUS"
```

Turn the token into guidance:

- **`WIRED`** → "Already pointed at the dispatcher — nothing to paste."
- **`UNWIRED`** or **`ABSENT`** → print the one-liner and where it goes:

  > Paste this into Orca → the repo's settings → **Setup script** field:
  >
  >     bash "$HOME/machines/scripts/orca-worktree-setup.sh"
  >
  > (If `ABSENT`: the repo isn't listed in Orca yet — open it once so it appears,
  > then paste. Orca applies it on the next worktree it creates.)

- **`CONFLICT\t<value>`** → "A different setup script is configured (`<value>`).
  Replace it with the dispatcher one-liner only if you mean to; otherwise leave
  it." Never presume — the user decides.

## Notes

- Orca's registry is per-runtime/per-host and `orca-data.json` is not synced, so
  the paste is per machine. The committed `.orca/worktree-setup.sh` DOES sync, so
  the custom rules travel; only the paste repeats.
- This skill performs no Orca-config writes and no destructive git ops.
