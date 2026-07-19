# KB refresh — Phase 2 runbook (fleet-wide harvest)

One-time follow-up to the Phase 1 local harvest. Start a **fresh Claude Code
session** from `~/machines` (the main checkout) on a box that can reach the fleet
over the tailnet, and give it the kickoff prompt below.

## Where Phase 1 left off
- The `kb-refresh` tooling, its spec/plan, and the Phase 1 KB refresh are on
  `main` (merged + pushed). Phase 1 harvested **this controller box's** ~55 local
  sessions and landed 46 approved facts.
- The read-once watermark for those sessions is in the git-tracked
  `.claude/kb-harvest-state.json` (`last_refresh.commit` = the Phase-1 baseline).
  Phase 2 harvests the **other** boxes (latitude, desktop, server) + any new
  local sessions; the watermark skips everything already done.

## Prerequisites (verify FIRST)
1. **Sync `main` here:** `git -C ~/machines pull`. Phase 1's one wrong fact came
   entirely from running against a branch behind `main` — sync first so Track B
   and the reduce stage verify against true current state.
2. **Deploy the tooling on each fleet box.** Each box's `~/.claude/skills/cyphy`
   symlinks to `~/machines/agents/plugin`, so the box needs `main` pulled:
   `ssh <box> bash -lc 'cd ~/machines && git pull'` for box in `latitude`,
   `desktop`, `server`. Confirm it resolves:
   `ssh <box> bash -lc 'ls ~/.claude/skills/cyphy/skills/kb-refresh/distill.py'`.
   (This path did not exist before the Phase-1 merge — this is the step that
   makes the remote distill actually run.)
3. **Reachability:** `ssh <box> hostname` for latitude / desktop / server.

## Kickoff prompt (paste into the new session)

> Run Phase 2 of the fleet KB refresh: the full fleet-wide transcript harvest,
> using the `kb-refresh` tooling on `main`. First do the prerequisites in
> `docs/kb-refresh-phase2-runbook.md` (sync `main` here + `git pull` on each
> fleet box so `~/.claude/skills/cyphy/skills/kb-refresh/distill.py` resolves,
> and confirm ssh reachability). Then follow
> `agents/plugin/skills/kb-refresh/SKILL.md` WITH the fleet:
>
> 1. GATHER: `bash agents/plugin/skills/kb-refresh/fleet-gather.sh --match machines --state ~/machines/.claude/kb-harvest-state.json --out <scratch>/kb-digests`. Expect ~0 new locally (Phase 1 did this box); it seeds each remote with the git-tracked watermark, distills in-place on latitude/desktop/server, merges their watermarks back, and rsyncs back only digests. Watch the per-host lines: "remote distill failed (exit N)" = deploy/path problem on that box (fix the pull); "skipped (unreachable)" = tailnet.
> 2. MAP: size-balance the NEW digests into ~5 batches; fan out map subagents (sonnet) to extract durable candidate facts (gotchas / decisions / host quirks) routed to tiers {global, host:<name>, project, claude-md, docs}; never extract secrets.
> 3. TRACK B: baseline = `.claude/kb-harvest-state.json` `last_refresh.commit` → HEAD (small diff); emit doc/code drift rows.
> 4. REDUCE: dedup against the CURRENT KB (much richer after Phase 1), drop stale/already-known, verify checkable claims against the live repo, cluster survivors into one proposal.
> 5. REVIEW GATE (mandatory): present the proposal; write nothing until the user approves/trims.
> 6. WRITE: apply approved rows to the tier files, update `last_refresh` (merge-preserving), refresh the single provenance stamp in `.claude/memory/project.md`, commit on a FRESH branch off `main` (never commit KB edits directly on `main`), then offer the FF merge-back + push.

## Notes
- Host-tier facts use the digest's `# host:` value; host-memory filenames use the
  raw OS hostname (`agents/hosts/latitude5520.md`, `g614jv.md`, `methe-server.md`).
- The first fleet gather is the real shakeout of the remote distill/rsync path —
  it has only ever run locally so far.
- Delete this runbook after Phase 2 completes.
