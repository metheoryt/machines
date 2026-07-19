# Fleet KB Harvester — SDD Progress Ledger

Plan: docs/superpowers/plans/2026-07-19-fleet-kb-harvester.md
Spec: docs/superpowers/specs/2026-07-19-fleet-kb-harvester-design.md
Branch: refresh-kb (worktree; base main at /home/me/machines).
BASE @ 4057905 (plan commit; final-review MERGE_BASE = 4057905).

ENVIRONMENT:
- uv 0.11.28 present. Tests: `uv run --with pytest pytest -q agents/plugin/skills/kb-refresh/tests/`
- Bash tests: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
- Plugin namespace = cyphy (agents/plugin/.claude-plugin/plugin.json). Sibling skills: gortex-align, update-balance, worktree-agent.
- Task 6 (catch-up run: fleet SSH + review gate) runs in the MAIN session, not a subagent.

## Tasks
- [x] Task 1: distill.py — single-session jsonl → digest (full read)
- [x] Task 2: distill.py — read-once watermark (resume offset + identity hash)
- [x] Task 3: distill.py — CLI (discover, digest, manifest, state merge)
- [x] Task 4: fleet-gather.sh — detect_hosts + in-place remote distill + rsync
- [ ] Task 5: SKILL.md — orchestration (gather→map→reduce→review→write→stamp)
- [ ] Task 6: Catch-up run against machines (human-in-the-loop; main session)
- [ ] FINAL whole-branch review

## Adjudicated findings (do not re-raise)
- T4 #2 (remote ssh command "malformed" → never runs distill.py): **FALSE POSITIVE, dismissed with evidence.** Reviewer reproduced by feeding `bash -c "'python3 …'"` locally, dropping the `bash -lc ` prefix and collapsing the two-shell ssh layers. Real flow: local `ssh` concatenates trailing argv → remote shell receives the string `bash -lc 'python3 … --host desktop --match foo --match bar'` → remote shell (fish) strips the single quotes → `bash -lc` gets a clean single-arg script → tokens split. Empirically verified: substituting `env PROBE` for python3 and running the exact sent-string through a shell executed `env` with arg `PROBE` (`env: 'PROBE': No such file`), proving correct token splitting (not "command not found: python3 …"). `~`/`*` sit inside the quoted script so remote bash expands them. No code change. (Residual, low-risk, closes at Task 6: emulated remote with bash not fish; fish strips single quotes identically.)

## Resolved decisions
- T4 #1 (self-host exclusion): RESOLVED. User chose the runtime-probe approach. Fix d768141: detect_hosts now pure (returns all workstation aliases in ~/.ssh/config; dead OS-hostname-vs-alias check removed), main self-excludes at connect time via `[ "$(ssh "$h" hostname 2>/dev/null)" = "$(hostname)" ] && continue` BEFORE the remote distill. Relocates the brief's "excludes current host" from detect_hosts→main (small plan amendment). Test still PASS. Controller re-reviewed the 12-line diff directly (correct placement, unreachable host still skips cleanly, working ssh bash -lc quoting untouched).

## Minor findings (for final review triage)
- T4 minor: arg-parse `--out) out="$2"` crashes with `$2: unbound` under `set -u` if a flag is the last arg with no value (raw bash error instead of the usage message). Low UX robustness gap; well-formed Task 6 invocations unaffected.
- T4 minor: `A && B || C` idiom at the required-args check (SC2015) — harmless (all three tests side-effect-free).
- T1 #1: distill.py cwd/branch aggregation is last-wins (`if ev.get("cwd"): cwd=ev["cwd"]`), inconsistent with session_id's first-wins. Harmless for cwd; branch could flip on mid-session `git checkout`. INHERITED from plan's reference code — not implementer-introduced.
- T1 #3: distill_lines has no guard against a valid-JSON non-dict line (bare string/number/list) → AttributeError aborts the call. Real transcript lines are always objects; robustness nice-to-have. INHERITED from plan.
- T1 #4: test_distill.py covers only the happy path — the `except JSONDecodeError` branch and mid-session cwd/branch change are untested. Matches brief exactly.

## Log
Task 4: complete (feat 1762233 + self-exclude fix d768141 — haiku impl / sonnet review / sonnet fix, Spec ✅ after fix). detect_hosts (only tested surface) matches spec: 3 workstation aliases, hub never, anchored grep (no HostName/substring false-match); test PASS. Test-harness deviation (export HOME vs brief's inline HOME= prefix) verified correct + non-weakening (bash scoping: env-prefix doesn't persist HOME to post-source detect_hosts call; KB_GATHER_NO_MAIN=1 still gates main off during source). main runs local + remote-in-place distill, rsync pulls ONLY digests (raw transcripts never leave box), forces bash for fish. Review raised 2 Important (both plan-mandated): #2 malformed remote cmd = FALSE POSITIVE (adjudicated w/ evidence above); #1 self-exclusion = REAL, user-decided → fixed via runtime probe. Removed stray subagent scratch file script2.sh from repo root.
Task 3: complete (feat 9a02407 + fix 50889e4, review + re-review clean — haiku impl / sonnet review / sonnet fix / sonnet re-review, Spec ✅, Approved after fixes). run() globs *<m>*/*.jsonl, distills from resume offset, writes headered digests + manifest.tsv (append), merge-writes `sessions` preserving `last_refresh` (verified by test seeding last_refresh). Read-once verified (2nd run over unchanged file → 0 digests; last_line/id_hash always advance). Review found 1 Important: unguarded `json.loads(lines[0])` probe could abort the whole sweep on a malformed first line → FIXED (try/except JSONDecodeError,AttributeError → filename fallback) + bundled Minor (cwd/last_ts clobbered to None on no-op run → FIXED via prev-entry fallback). 2 regression tests added (malformed-first-line survives sweep + processes 2nd session; cwd survives no-op run). 6 tests pass. Remaining Minor (final-review triage): sessions_with_new always == digests_written (redundant field); `# host: None` in header when --host omitted (SKILL always supplies --host).
Task 2: complete (commit 493a4de, review clean — haiku impl / sonnet review, Spec ✅, Approved, 0 Critical/Important). Added identity_hash + resume_offset + import hashlib; verbatim from brief. Reviewer verified all 4 branch cases (new/truncated-strict->/identity-changed/resume) line-by-line; truncation uses strict `>` (exact-length resume not misclassified); Task 1 distill_lines + its test provably untouched. Minor: cosmetic 1-blank-line spacing between new test defs; partial-state (missing id_hash/last_line key) untested — current default safely reprocesses.
Task 1: complete (commit fc07528, review clean — haiku impl / sonnet review, Spec ✅, Approved, 0 Critical/Important). Verbatim transcription of brief's reference code; distill_lines(lines)->(digest,meta); stdlib-only (import json); no filesystem access so read-only constraint holds by construction. Reviewer traced all 6 test events by hand, confirmed PASS. 3 Minor findings logged above (all inherited from plan code) + 1 report-accuracy slip (report said cwd/branch first-wins; code is last-wins — no code impact).
