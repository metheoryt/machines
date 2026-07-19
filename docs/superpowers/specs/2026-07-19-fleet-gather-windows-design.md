# Design — teach `fleet-gather.sh` the Windows fleet

**Date:** 2026-07-19
**Scope:** Job 1 of `docs/fleet-gather-windows-handoff.md` — make
`agents/plugin/skills/kb-refresh/fleet-gather.sh` harvest the Windows fleet
members. Job 2 (collect remaining transcripts) is a separate, downstream step.

## Problem

`fleet-gather.sh` gathers + in-place-distills Claude Code transcripts across the
fleet: it distills the local box, then for each remote workstation seeds the
git-tracked watermark → runs `distill.py` in place → merges the advanced
watermark back → pulls digests. Raw transcripts never leave their box; only
digests return.

Every remote assumption in the current script is unix-shaped and breaks on the
**Windows** members (`desktop`=g614jv, `server`=methe-server), whose SSH lands
in **PowerShell** (though `ssh h bash …` does dispatch to WSL bash):

- **rsync-over-ssh fails** — no `rsync` on the PowerShell PATH (3 call sites:
  seed-push L58, state-pull L80, digest-pull L87).
- `ssh $h mkdir -p .cache` (L57) — PowerShell `mkdir` has no `-p`.
- `ssh $h hostname` self-exclusion probe (L51) — returns the *native* Windows
  name (`ME-G614JV`), never equal to the fleet identity.
- `distill.py` is invoked at a **deployed-symlink** path
  (`~/.claude/skills/cyphy/…`) that doesn't exist in WSL.
- Transcripts live in the **Windows** profile
  `/mnt/c/Users/<user>/.claude/projects`, not WSL `~/.claude/projects`
  (server's WSL has none; desktop's WSL has a partial one — so a Windows box has
  **two** roots).

Net: a stock run reports 0 digests from the Windows boxes — a silent no-op.

The fix mechanism was **run by hand and verified 2026-07-19** (see the handoff);
this spec turns that verified manual work into the tool.

## The two rules the fix hangs on

The risk is the **shell boundary**, not the distill logic.

1. **Every remote command is bash-wrapped — AND nested-quoted.** Not only the
   distill call — all of `mkdir`, the transport calls, the self-exclusion probe,
   and the distill invocation go through `ssh $h bash …`. A bare `ssh $h <cmd>`
   lands in PowerShell; that is the entire bug class.
   **Nested quoting is mandatory** for the inline `bash -lc` calls: write
   `ssh $h bash -lc "'<cmd>'"`, NOT `ssh $h bash -lc '<cmd>'`. ssh flattens its
   argv into a single command string, so the LOCAL single-quotes are consumed
   before the remote shell ever sees them — `bash -lc '<cmd>'` arrives as
   `bash -lc <cmd>` and `bash -c` then runs only the first word (`mkdir` with no
   args → "no dirs provided", misreported as "unreachable"). The inner quotes
   must travel to the remote intact. *(The live harvest 2026-07-19 caught the
   shipped single-quote form failing on both Windows boxes; the piped `bash -s`
   distill dispatch — rule 2 — was unaffected because its body arrives on stdin,
   not in argv.)*
2. **Dynamic values cross as arguments, never string-interpolated.** Pipe a
   static script and pass roots/host/matches as positional args
   (`ssh $h bash -s -- "$host" "$@" < run.sh`, read `$1/$2/…` inside). This
   deletes the `bash -lc "'… ${match_args[*]}'"` triple-quoting trap (ssh →
   PowerShell → WSL bash mangles special chars).

## Decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| a | Platform detection | Read `platform` from `fleet.json` (jq) | Already present; a runtime probe is fragile — `ssh h uname` errors under PowerShell and `ssh h true` is a false-negative (PowerShell has no `true`). |
| b | Transport | Unify **all** boxes on `cat`/`tar`; drop rsync entirely | rsync-over-ssh fails on Windows; the unix-*remote* rsync path is **never exercised today** (latitude = local controller, hub = excluded from `FLEET_WORKSTATIONS`), so tar-unifying loses no working capability. Seed-push + state-pull = `cat` of a single JSON file; digest-pull = `tar` with `--exclude=manifest.tsv` (deliberate — the local manifest accumulates; a plain copy would clobber it). |
| c | Windows profile user | Trust `fleet.json` `ssh.user`; **no** remote-FS scan (YAGNI) | `ssh.user` (`methe`) is the authoritative Windows profile user and is verified correct on both boxes. A wrong user degrades *gracefully* — the profile root's glob finds nothing and the WSL root still harvests — rather than crashing, so a `/mnt/c/Users/*` scan (which would have to run on the remote FS, not in an offline helper) isn't worth the complexity. The WSL login user is `me` and is NOT in fleet.json — use bare `~` for the WSL root. |
| d | Multi-root | Windows box distills **two** roots (Windows profile + WSL `~`), same out/state; unix box distills one (`~/.claude/projects`) | `distill.py` already supports multi-root via repeated calls with the same `--out`/`--state`. |

## Identity fix (folded in)

Resolve **every** `--host` — local and remote — from `fleet.json`
`detect.hostname`, not the ssh alias (remote) or raw `$(hostname)` (local).

- Uniform identity fleet-wide.
- Makes each digest's `# host:` line match the `agents/hosts/*.md` filenames
  (`latitude5520` / `g614jv` / `methe-server`), which the downstream reduce
  relies on. Today the script inconsistently uses the ssh alias for remotes and
  `$(hostname)` locally.
- Closes a latent self-exclusion gap: the (now bash-wrapped) probe compares the
  remote's WSL `hostname` against **this box's resolved fleet identity**, so a
  Windows box acting as controller can still recognise itself.

## Architecture

The remote path is untestable without live boxes, so the decision logic moves
into **pure functions** tested against a `fleet.json` fixture — the same
`ssh_wsl_render_config` pattern already used in `provision/ssh-wsl.sh` +
`ssh-wsl.test.sh`. `main` stays a thin IO wrapper (ssh/cat/tar) around them.

Pure helpers (loadable via `KB_GATHER_NO_MAIN=1 source`, no IO, no network):

- **`fleet_hosts <fleet.json>`** — emit one line per workstation:
  `alias\tplatform\tdetect.hostname\tssh.user` (hub excluded; ssh.user empty
  when absent). Reads `fleet.json` via jq.
- **`roots_for_platform <platform> <ssh.user>`** — newline-separated projects
  roots for that box:
  - `windows` → `/mnt/c/Users/<ssh.user>/.claude/projects` **and** `~/.claude/projects`
  - unix (`nixos`/`debian`) → `~/.claude/projects`
- **`local_host_id <fleet.json> <live-hostname>`** — map this box's live
  `hostname` to its `detect.hostname` (fallback: the live hostname).
- **`remote_distill_script`** — emit the static run-script (or the arg vector)
  that a remote runs: for each root, `python3 ~/.cache/distill.py
  --projects-root <root> --match … --host <id> --out ~/.cache/kb-digests
  --state ~/.cache/kb-harvest-state.json`. Dynamic values arrive as positional
  args, never interpolated into a quoted string.

`main` (IO, per remote workstation):

1. Bash-wrapped self-exclusion probe: `ssh $h bash -lc 'hostname'` vs this box's
   resolved fleet id → skip self.
2. Push `distill.py` (always — drop the deployed-symlink dependency) and seed
   the git-tracked state, both via `ssh $h bash -lc 'cat > …'`.
3. Run the distill run-script per root via `ssh $h bash -s -- <args> < script`.
4. Pull the remote state (`ssh $h bash -lc 'cat …'` → tmp), merge only its
   `sessions` back via `distill.py --merge-from`.
5. Pull digests via `tar` over `ssh $h bash -lc 'cd … && tar cf - --exclude=manifest.tsv .'` | `tar xf -`.

Local-first distill preserved (unchanged: `--projects-root ~/.claude/projects`,
now `--host <resolved id>`). Self-exclusion invariant preserved. Read-once
seed→distill→merge-back→pull invariant preserved.

## Testing

Extend `tests/test_fleet_gather.sh` (currently tests `detect_hosts`, whose
contract changes — it now consults `fleet.json` for platform, so update it in
the same pass). Add fixture-driven cases for the new pure functions, mirroring
`ssh-wsl.test.sh`:

- `fleet_hosts` against a fleet.json fixture → correct tuples, hub excluded,
  empty ssh.user for the unix member.
- `roots_for_platform windows methe` → both roots in order; `roots_for_platform
  nixos ''` → single WSL root.
- `local_host_id` → live `latitude5520` maps to `latitude5520`; unknown host
  falls back to itself.
- `remote_distill_script` → contains a `--projects-root <root>` per root and the
  resolved `--host`, and does NOT string-interpolate match args into a quoted
  blob (assert the positional-arg shape).

Guard jq-dependent cases with `command -v jq` + a `SKIP:` line, per convention.
The test must run offline (no ssh/network) — it exercises only the pure
functions loaded in `KB_GATHER_NO_MAIN=1` mode.

## Docs to update after the fix

- `.claude/memory/project.md` — the kb-refresh caveat currently says the tool
  can't reach Windows; update to say it now handles Windows via the platform
  dispatch.
- `SKILL.md` (Step 1) — the description of `fleet-gather.sh`'s remote path
  (rsync + deployed-symlink distill.py + alias `--host`) is now stale; rewrite
  to the platform-dispatch / tar-transport / pushed-distiller / `detect.hostname`
  identity story.

## Out of scope (Job 2)

Collecting the remaining transcripts runs the *fixed* tool from the `~/machines`
main checkout **after** this branch is FF-merged to `main` — today's script
would silently return 0 from the Windows boxes. Prereqs (from the handoff):
`git pull` first; the watermark advances at gather time *before* any write, so
on any abort/reject run `git checkout -- .claude/kb-harvest-state.json` before
re-running or it reports "0 new."
