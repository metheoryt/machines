# Handoff — fix `fleet-gather.sh` for the Windows fleet, then collect remaining transcripts

Start a **fresh Claude Code session** from `~/machines` (main checkout) on a box that
can reach the fleet over the tailnet. Two jobs, in order: (1) teach `fleet-gather.sh`
to harvest the Windows fleet members, (2) run it to pick up transcripts created since
the 2026-07-19 Phase-2 harvest. Delete this file when both are done.

## Where things stand (2026-07-19)
- Phase 2 fleet KB refresh is **done + merged to `main` + pushed** (`eaeb0bd`).
- The read-once watermark (`.claude/kb-harvest-state.json`) is at **105 sessions**,
  `last_refresh.commit` stamped `2e7423f`.
- The Windows boxes were harvested this session by **manual orchestration**, because
  the stock `fleet-gather.sh` can't reach them. This handoff turns that manual work
  into the tool, then re-runs it cleanly.

## The bug (diagnosed + verified 2026-07-19)
`fleet-gather.sh` assumes every remote fleet box is unix-y with (1) transcripts under
`~/.claude/projects`, (2) `~/.claude/skills/cyphy/…/distill.py` deployed, (3) `rsync`
reachable over ssh, (4) a fish/bash login shell. On the **Windows** members
(`desktop`=g614jv, `server`=methe-server) NONE of those hold:
1. Live transcripts live in the **Windows** profile
   `/mnt/c/Users/<winuser>/.claude/projects`, NOT WSL `~/.claude/projects` (server's
   WSL has no `~/.claude/projects` at all; desktop's WSL has a *partial* one).
2. No `~/.claude/skills` in WSL → `distill.py` isn't found there.
3. SSH lands in **PowerShell**; `rsync`-over-ssh fails (no `rsync` on the PowerShell
   PATH). `ssh h bash -lc '…'` / `ssh h bash -s < f` do dispatch to **WSL bash**.

Net: a stock run reports 0 digests from those boxes — a silent no-op.

## The validated manual mechanism (blueprint for the fix)
Per Windows box, via WSL bash over ssh (raw transcripts never leave the box; only
digests come back):
1. **Seed** the git-tracked state → remote cache (verify byte size after):
   `ssh h bash -lc "'cat > ~/.cache/kb-harvest-state.json'" < <git-state>`
2. **Push the distiller** (drop the deployed-symlink dependency):
   `ssh h bash -lc "'mkdir -p ~/.cache/kb-digests; cat > ~/.cache/distill.py'" < agents/plugin/skills/kb-refresh/distill.py`
3. **Distill per root** (pipe a script via `ssh h bash -s < run.sh`):
   `python3 ~/.cache/distill.py --projects-root <ROOT> --match machines --host <OSHOST> --out ~/.cache/kb-digests --state ~/.cache/kb-harvest-state.json`
   - ROOTs: Windows `/mnt/c/Users/<winuser>/.claude/projects` (both boxes) **and** WSL
     `~/.claude/projects` (desktop only — run distill twice, same out/state).
   - `<OSHOST>` = fleet.json `detect.hostname` (`methe-server` / `g614jv`) so digests'
     `# host:` matches the `agents/hosts/*.md` filenames.
4. **Merge watermark back**: pull the remote state, merge only its `sessions`:
   `ssh h bash -lc "'cat ~/.cache/kb-harvest-state.json'" > /tmp/s.json` then
   `python3 …/distill.py --merge-from /tmp/s.json --state <git-state>`
5. **Pull digests** (tar, not rsync):
   `ssh h bash -lc "'cd ~/.cache/kb-digests && tar cf - --exclude=manifest.tsv .'" | tar xf - -C <out>`

Local box (`latitude`, NixOS, fish) uses the stock path (`--projects-root
~/.claude/projects`) — no change.

## `fleet.json` already carries what the fix needs
```
desktop/server: "platform": "windows", "ssh": {"user": "methe"}, "detect": {"hostname": "g614jv"/"methe-server"}
latitude:       "platform": "nixos",  ...,                       "detect": {"hostname": "latitude5520"}
```
- `platform` → dispatch unix-path vs windows-path.
- `detect.hostname` → the `--host` value (uniform; today the script inconsistently uses
  the ssh alias for remotes and `hostname` locally).
- `ssh.user` (`methe`) = the Windows **profile** user → `/mnt/c/Users/methe/…`. The WSL
  login user is `me` (`~` = `/home/me`) and is NOT in fleet.json — use bare `~` for the
  WSL root.

## Job 1 — the fix (scope)
Modify `agents/plugin/skills/kb-refresh/fleet-gather.sh`:
- Resolve each workstation's `platform` / `detect.hostname` / `ssh.user` from
  `fleet.json` (jq), instead of the hardcoded `FLEET_WORKSTATIONS` + alias `--host`.
- **Unix path** (nixos/debian): keep rsync; `--projects-root ~/.claude/projects`;
  `--host <detect.hostname>`.
- **Windows path**: the 5-step mechanism above (push `distill.py`, roots =
  `/mnt/c/Users/<ssh.user>/.claude/projects` [+ a `/mnt/c/Users/*` scan fallback] and
  WSL `~/.claude/projects`, tar transport, `--host <detect.hostname>`).
- Recommended: **always push `distill.py`** (uniform, robust on every box).
- Preserve the seed→distill→merge-back→pull invariant (read-once, fleet-wide).
- Keep the local-first distill; keep self-exclusion (a box whose live `hostname`
  matches this one is skipped).

**Design decisions to settle first (brainstorm, then spec under
`docs/superpowers/specs/`):**
- (a) **Detection** — fleet.json `platform` (recommended, already present) vs a runtime
  probe. Note `ssh h uname` errors under PowerShell, and `ssh h true` is a false-negative
  (PowerShell has no `true`) — probe with `whoami`/`exit 0` if you probe at all.
- (b) **Transport** — tar/cat for Windows (rsync fails there); unify all boxes on
  tar, or keep rsync for unix.
- (c) **Windows user** — trust fleet.json `ssh.user`, or scan `/mnt/c/Users/*/.claude/projects`.
- (d) **Multi-root** — a box can have >1 projects root (Windows profile + WSL).

Add a `fleet-gather.test.sh` (repo convention: `ssh-wsl.test.sh`,
`tailscale-wsl.test.sh`) or at minimum a dry-run/self-test. After the fix, update the
`project.md` kb-refresh caveat and `SKILL.md` to say the tool now handles Windows.

## Job 2 — collect remaining data
From `~/machines` (main, pulled) on a fleet-reachable box:
```
bash agents/plugin/skills/kb-refresh/fleet-gather.sh \
  --match machines --state ~/machines/.claude/kb-harvest-state.json --out <scratch>/kb-digests
```
Read-once skips the 105 already-harvested sessions, so it should pick up only NEW ones
since 2026-07-19 (including this Phase-2 session's own transcript). Then run the
`cyphy:kb-refresh` map/reduce/**review-gate**/write as a small incremental refresh
(`agents/plugin/skills/kb-refresh/SKILL.md`) — likely a handful of facts, possibly
near-empty.

## Prereqs & gotchas
- `git -C ~/machines pull` first (sync `main`); Track-B/reduce verify against live state.
- The fixed gather runs `distill.py` **by pushing it** — the Windows boxes don't need
  the skill deployed for the harvest to work; only the controller runs `fleet-gather.sh`.
- **rsync-over-ssh to a Windows box FAILS** (PowerShell remote shell, no `rsync` on PATH) — use tar/cat.
- Nested quoting through **ssh → PowerShell → WSL bash** mangles special chars — pipe a
  script file (`ssh h bash -s < f.sh`) over inline one-liners.
- Recovery: the watermark advances at gather time (before any write). On abort/reject,
  `git checkout -- .claude/kb-harvest-state.json` before re-running, else it reports "0 new".
- Leftover scratch from this session on desktop/server: `~/.cache/{distill.py,
  kb-digests,kb-harvest-state.json}` — harmless; the fixed run re-seeds/overwrites.

## Reference — box facts (verified 2026-07-19)
| alias | OS hostname | platform | SSH lands in | WSL user / home | transcripts |
|---|---|---|---|---|---|
| latitude | latitude5520 | nixos | fish | me / /home/me | `~/.claude/projects` (local; stock path) |
| desktop | g614jv | windows | PowerShell | me / /home/me | Windows `/mnt/c/Users/methe/.claude/projects` **and** WSL `~/.claude/projects` |
| server | methe-server | windows | PowerShell | me / /home/me | Windows `/mnt/c/Users/methe/.claude/projects` only |

`python3` present in WSL on both Windows boxes (3.14); `rsync` present in WSL but not
reachable through the PowerShell remote shell. Windows profile user on both = `methe`.
