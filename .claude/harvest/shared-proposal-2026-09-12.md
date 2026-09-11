# machines — shared-memory proposals, 2026-09-12

Filed by `/memory-harvest` Phase A. Lane 2 only: nothing here has been written.
`/memory-review` is what applies these. Rows are self-contained on purpose —
the transcripts behind them expire.

Source digests: `40ef9ef4-d45c-480b-be1b-8c36137324ef` (g15, 2026-09-11
17:14–19:55) and `96a76e02-1793-4233-ac7d-48537a2760ab` (g15, 2026-09-11 22:14).
Track B baseline `ac285c4..73a5334`.

Format: `tier | action | fact (exact text to paste) | target file | source | confidence`

## global

global | add | **Where a single-writer job lives depends on what the job IS, not on where the last one went.** A systemd timer running a shell script is happy on a headless services box; an *agent session* is not — it needs the agent CLI installed, a checkout of the repo it edits, and (here) the dotfiles bare repo with every branch fetched, i.e. a machine someone actually works at. The fleet picked its memory-consolidation publisher by analogy with an existing timer-based single writer and got the wrong box; the correction was to reason from the job's requirements instead. Uptime is usually not the deciding axis — check it, but check what the job needs to run at all first. | ~/.claude/memory/global.md (new bullet under *Fleet scripting conventions*) | machines 73a5334 (commit body + session 40ef9ef4) | high

global | add | **A "there must be exactly one X" rule is better expressed as a NAME than as a per-item boolean.** Two booleans can both be true; two names cannot, so the invariant stops being something a human has to remember and becomes something the config file cannot express otherwise — and moving X is editing one value. Make the reader print *nothing* when the key is absent, so the `[ "$(reader)" = "$me" ]` gate every caller writes is false everywhere rather than accidentally true somewhere. Test that the name still matches a real member: a typo means nobody does the job, and "nothing happened" reads exactly like "there was nothing to do". | ~/.claude/memory/global.md (new bullet under *Fleet scripting conventions*) | machines 0624418 (commit body + `provision/tests/memory-publisher.test.sh`) | high

## host:g15

host:g15 | add | **This box is the fleet's `memory_publisher`** (named at the root of `~/machines/fleet.json` since 2026-09-11, moved here from latitude 2026-09-12). It therefore runs `/cyphy:memory-harvest` Phase B — the whole-corpus memory consolidation — on top of Phase A, which every box runs. Phase B reads every machine's dotfiles branch out of the local bare repo, so it needs `dotfiles fetch --all` first and touches nothing remotely. If the job should move, edit that one value; never add a second publisher. | ~/.claude/host-memory.md | machines 73a5334 | high

host:g15 | add | **Repo discovery on this box finds far more repos than the fleet docs suggest — 67 as of 2026-09-12** — because `~/kazakhstan-law` is a git repo that also *contains* 27 nested per-region repos, and `~/kazakhstan-law-0912` is a second copy of the same tree. Any per-repo loop that does a fleet-wide ssh fan-out per iteration must be batched here, or a nightly job makes 67 fan-outs. Two of those repos share the basename `codes` (`~/kazakhstan-law/codes`, `~/split-test/codes`), so anything keyed on a repo's basename collides on this box specifically. | ~/.claude/host-memory.md | session 96a76e02 (measured live) | high

## Notes for the reviewer

- Nothing is proposed for `~/.claude/memory/personality/*` this run.
- The two `host:g15` rows are for THIS box, so they are writable from here —
  they are Lane 2 only because `host-memory.md` is a shared-store tier, not
  because they belong elsewhere.
- The mechanism-level memory-harvest facts from this run (the `--match`
  basename collision, the batched single gather, the substring transcript
  filter) went to Lane 1 in `machines/.claude/memory/project.md`, following the
  2026-09-11 decision to demote `fleet-gather.sh` mechanics out of `global.md`.
