---
name: orca-setup
description: "Use when the user wants to set up (or re-check) a repo for Orca-managed worktrees — one-time per repo. Scaffolds the repo's committed .orca/worktree-setup.sh custom-rules delegate and PRINTS the Orca setup-script one-liner for the user to paste into Orca's per-repo settings. Never writes Orca config, never closes the IDE. Fleet-sync personal repos only; refuses work/Pure repos. Invoked as /orca-setup."
---

# /orca-setup — wire a repo for Orca-managed worktrees

Runs in your session. It does the parts worth automating — the guard, the
committed `.orca/worktree-setup.sh` scaffold, and a **read-only** check of the
current Orca wiring — then hands YOU the exact setup-script command to paste into
Orca's UI. It never edits `orca-data.json` and never asks you to close Orca.

Background: `agents/worktree-setup.sh` / `agents/worktree-teardown.sh` are the
shared dispatchers Orca runs on each fresh worktree (Setup hook) and on delete
(Archive hook). Setup gortex-tracks the worktree (when the daemon is up), links the
generic gitignored config set, then delegates to this repo's
`.orca/worktree-setup.sh`; teardown runs a repo-local teardown (if any), then
gortex-untracks + reconciles. Overlay conventions for the working agent live in
`cyphy:worktree-agent`.

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
clobber — show a diff and let the user decide. NEVER regenerate
`orca-setup:managed:repo-steps` — that block holds the user's own repo-specific
steps and must be preserved. On a refresh of a delegate scaffolded by an older
version, STRIP any legacy `orca-setup:managed:gortex-readiness` block (from the
matching `>>>` to `<<<` marker line, inclusive) — gortex readiness is no longer
part of the delegate; the dispatcher owns all gortex handling now and never starts
the daemon.

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
tracking is handled entirely by the dispatcher (no per-repo opt-in, no daemon
start — it tracks only when the daemon is already up). Offer to `git add "$DEST"`.

## Step 3 — Print the setup + teardown commands (read-only status; no writes)

Check how the repo is currently wired, then print guidance. This reads
`orca-data.json` read-only — safe with Orca open.

**The one-liner is platform-specific** — see "Why Windows differs" below. Resolve
Orca's data file first; whichever location exists tells you which platform's
one-liner to print.

```bash
# Assumes Orca's default profile; a non-default profile yields ABSENT (harmless —
# you just re-paste the idempotent one-liners). Point DATA elsewhere if needed.
# %APPDATA% in POSIX form — $APPDATA itself is backslashed and fails `[ -f ]`.
WIN_DATA="$HOME/AppData/Roaming/orca/profiles/local-default/orca-data.json"

if [ -f "$WIN_DATA" ]; then
  DATA="$WIN_DATA"
  SETUP='"%ProgramFiles%\Git\bin\bash.exe" -c "bash $HOME/machines/agents/worktree-setup.sh"'
  TEARDOWN='"%ProgramFiles%\Git\bin\bash.exe" -c "bash $HOME/machines/agents/worktree-teardown.sh"'
else
  DATA="$HOME/.config/orca/profiles/local-default/orca-data.json"
  SETUP='bash "$HOME/machines/agents/worktree-setup.sh"'
  TEARDOWN='bash "$HOME/machines/agents/worktree-teardown.sh"'
fi
~/machines/agents/plugin/skills/orca-setup/orca-status.sh "$DATA" "$ORIGIN" "$SETUP" "$TEARDOWN" "$BASE"
```

Run this from the **same shell world as the Orca install** — Git Bash (MINGW64) on
the Windows boxes, not WSL. From WSL neither candidate path resolves and you would
silently print the Linux one-liner for a Windows Orca.

The helper prints two lines, one per Orca hook slot:

```
setup<TAB><WIRED|UNWIRED|ABSENT|CONFLICT<TAB><value>>
archive<TAB><WIRED|UNWIRED|ABSENT|CONFLICT<TAB><value>>
```

Turn each slot's token into guidance. Orca's **Setup script** field takes the
`setup` one-liner; its **Archive script** field (run on worktree delete) takes the
`teardown` one-liner:

- **`WIRED`** → "This slot already points at the dispatcher — nothing to paste."
- **`UNWIRED`** / **`ABSENT`** → print the matching one-liner and where it goes:

  > Paste into Orca → the repo's settings — the **Setup script** field gets
  > `$SETUP`, the **Archive script** field (runs on worktree delete) gets
  > `$TEARDOWN`, exactly as the block above resolved them for this platform:
  >
  > Linux:
  >
  >     bash "$HOME/machines/agents/worktree-setup.sh"
  >     bash "$HOME/machines/agents/worktree-teardown.sh"
  >
  > Windows:
  >
  >     "%ProgramFiles%\Git\bin\bash.exe" -c "bash $HOME/machines/agents/worktree-setup.sh"
  >     "%ProgramFiles%\Git\bin\bash.exe" -c "bash $HOME/machines/agents/worktree-teardown.sh"
  >
  > (If `ABSENT`: the repo isn't listed in Orca yet — open it once so it appears,
  > then paste. Orca applies it on the next worktree it creates.)

- **`CONFLICT\t<value>`** → "A different script is configured (`<value>`)." If
  `<value>` is the **legacy** `…/scripts/orca-worktree-setup.sh`, tell the user it
  is retired and should be replaced with the new one-liner. On Windows, a `<value>`
  of the bare Linux form `bash "$HOME/…"` is likewise **broken, not a preference** —
  say so and replace it. For any other value, never presume — the user decides.

## Why Windows differs

Orca wraps whatever is in the field into `.git/worktrees/<wt>/orca/setup-runner.cmd`
and runs it through **cmd.exe**, which breaks the Linux one-liner two ways:

1. **`bash` resolves to the WSL launcher.** Git's `bin` is not on the machine PATH,
   so `where bash` returns `C:\Windows\System32\bash.exe` first. Launched from
   Orca's non-interactive context it dies with `Bash/Service/E_UNEXPECTED`, exit 1 —
   the hook silently never runs (symptom: a fresh worktree is missing its
   `.claude/settings.local.json` link).
2. **cmd.exe does not expand `$HOME`.** Even with the right bash, `bash "$HOME/…"`
   passes a literal `$HOME/…` as a *filename*, which bash does not expand.

The Windows form fixes both: an absolute `%ProgramFiles%`-rooted path to Git Bash
(cmd *does* expand `%…%`), and `-c` so the string is a *command*, where bash expands
`$HOME` itself. Verified on `g513ie`: `bash -c` (non-login) already gets the full
MSYS PATH (`git`, `sed`) and Orca's cwd (the worktree), so no `-l` / `CHERE_INVOKING`
is needed. Do not quote `$HOME` inside the `-c` string — cmd does not process `\"`;
the fleet's `$HOME` (`/c/Users/methe`) has no spaces.

## Notes

- Orca's registry is per-runtime/per-host and `orca-data.json` is not synced, so
  the paste is per machine. The committed `.orca/worktree-setup.sh` DOES sync, so
  the custom rules travel; only the paste repeats.
- This skill performs no Orca-config writes and no destructive git ops.
- Orca's data file lives at `~/.config/orca/profiles/local-default/orca-data.json`
  on Linux but `%APPDATA%\orca\profiles\local-default\orca-data.json` on Windows.
- Hand-testing a `setup-runner.cmd` **from MINGW64 needs `cmd //c`, not `cmd /c`** —
  MSYS path conversion rewrites the lone `/c` into a path, cmd never sees the switch
  and drops to an interactive prompt, producing bogus "`'…' is not recognized`"
  errors that have nothing to do with the real failure.
