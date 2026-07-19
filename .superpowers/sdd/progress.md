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
- [x] Task 5: SKILL.md — orchestration (gather→map→reduce→review→write→stamp)
- [x] Task 6: flip fleet.json detect.hostname + empirical statements -> g513ie
- [x] FINAL whole-branch review (opus, 4057905..c0eb951): Ready to merge = WITH FIXES
- [x] Final-review fixes #1/#3/#4 landed (commit a374328, verified: 7 distill tests + fleet PASS)
- [x] Task F2: fleet-wide read-once fix (#2) — seed remote w/ authoritative watermark + merge back (commit 2417478, review clean, Approved)
- [x] Task 6 Phase 1: LOCAL-only catch-up harvest (commit 1562638) — 55 sessions harvested, 46 facts approved+written across 6 KB files, state seeded w/ last_refresh. review gate passed.
- [ ] Phase 2 (later, separate): merge tooling→main + fleet pull + full ~200-session fleet harvest

USER DECISIONS (recorded): (1) Local shakeout now, fleet later. (2) Fix #2 before any run. Both Task 6 phases write KB edits on a FRESH branch, never main.

## FINAL REVIEW findings (opus)
- **CRITICAL #1 (CONFIRMED empirically): remote distill path wrong + undeployed.** fleet-gather.sh:57 globs `~/.claude/plugins/cache/*/cyphy/*/skills/kb-refresh/distill.py` — matches NOTHING. cyphy is deployed as a SKILLS-DIR symlink `~/.claude/skills/cyphy → /home/me/machines/agents/plugin` (bootstrap.sh:244), NOT a marketplace plugin. Correct path: `~/.claude/skills/cyphy/skills/kb-refresh/distill.py`. BUT even corrected it won't resolve until refresh-kb MERGES to main + each box pulls — the symlink points at the MAIN checkout, which lacks kb-refresh today (`find -L ~/.claude -name distill.py` = empty). Failure is misreported as "[$h] skipped (unreachable)". LOCAL distill is fine (uses $SKILL_DIR = worktree). → FIX path in script; Task 6 fleet-gather is BLOCKED until merge+fleet-pull (sequencing decision).
- **IMPORTANT #2: read-once not fleet-wide (spec deviation).** Remote in-place distill reads remote `~/.cache/kb-harvest-state.json`; watermarks never rsync back (only digests do). So git-tracked state holds only the CONTROLLER box's watermarks; a box that's controller one run + remote another re-harvests from 0. Fine for the one-shot Task 6 (single controller), breaks the "repeatable" goal on later cross-box runs. Fix is design-level (rsync remote state back, merge by session-id UUID). DECISION: fix-now vs defer.
- **IMPORTANT #3: non-dict JSON line aborts whole sweep.** distill_lines catches only JSONDecodeError; a valid-but-non-dict line → ev.get() raises AttributeError, uncaught → propagates → under set -e kills fleet-gather before remotes. One-line fix: `if not isinstance(ev, dict): continue` after json.loads. (run's sid_probe already guarded; distill_lines wasn't.)
- **IMPORTANT #4: watermark advances at gather (Step 1), before commit (Step 6).** If map/reduce crashes or user rejects, state already advanced → re-run says "0 digests" (silent no-op); recovery = rm untracked state file. Fix: SKILL.md note to revert/delete state on abort/reject.
- Minors: manifest.tsv clobbered in fleet mode (rsync overwrites; low impact, SKILL doesn't consume it); remote digests --host=alias vs local --host=hostname (host-tier filename mismatch; recoverable at gate); detect_hosts `desktop` alias may be stale (WSL renamed desktop-ubuntu26 per 340183c) — verify ssh aliases before Task 6.


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
Task 6 Phase 1 IN PROGRESS (local shakeout, main session):
- GATHER done: `distill.py --match machines` → 56 sessions seen, 55 digests (1.6MB) in scratchpad/kb-digests/. State .claude/kb-harvest-state.json seeded (56 sessions, no last_refresh → Track B full pass). NOT yet committed (part of eventual Phase 1 commit; abort-recovery = rm the untracked state file).
- MAP done: 5 sonnet subagents → 116 candidate facts (batch1=20, b2=18, b3=29, b4=20, b5=29). Track B done: 11 drift rows (root CLAUDE.md heavily stale — retired g16 host, renamed hosts/latitude/, wrong homeserver chassis, missing VPS hub, ~11 undocumented modules incl 2 orphaned, no tailnet arch, aspirational backup/ never existed; global.md host-identity + fleet.json-path errors). = 127 candidates.
- REDUCE done: opus → 46 survivors (global 19, project 14, claude-md 9, host:latitude5520 3, host:g614jv 1), 77 dropped (54 known / 19 stale / 2 contradicted / 2 false), 2 needs-confirm. PROPOSAL.md written. Controller independently verified the 9 CLAUDE.md structural edits vs live repo (g16 windows-only, latitude sole NixOS host, backup/ never existed, nvidia/asus-rog orphaned — all TRUE). Confirmation #2 (settings.pure.json) resolved: pure profile RETIRED in d48c09a → becomes a doc fix in agents/CLAUDE.md.
- REVIEW GATE PASSED: user approved ALL 46 + pure-profile doc fix; dropped tailnet-ACL item (user trusts tailnet, don't record). Branch = refresh-kb.
- WRITE done (commit 1562638): writer applied 46/46 tier rows verbatim + provenance stamp (c525f9a); controller did agents/AGENTS.md pure-profile fix + last_refresh (56 sessions preserved). Controller verified all 6 file diffs vs proposal (root AGENTS.md architecture edits incl g16-block delete confirmed against live repo). 646 insertions.
- MERGE main→refresh-kb (b11ec0b): branch was 2 behind main. main's c1c10c8 had ALREADY bumped kernel→linuxPackages_latest + retired AmneziaVPN client — the exact 2 facts Phase 1's reduce dropped as "contradicted" (it verified against the stale branch tip, not main). LESSON: sync main BEFORE running a refresh so Track B/reduce verify against true current state. Resolved project.md conflict = took main's correct kernel+AmneziaVPN bullets over branch's wrong "LTS kept" bullet; kept all Phase 1 non-conflicting adds; fixed neighbor "LTS pin below" line. Provenance realigned to post-merge HEAD (95f46cd).
- refresh-kb now 28 ahead / 0 behind main → clean FF merge-back available.
- MERGE-BACK + PUSH DONE: FF main→e532735 in base checkout /home/me/machines, pushed to origin (2310 insertions: tooling + spec/plan + Phase-1 KB refresh). Worktree kept for Phase 2.
- REMAINING: Phase 2 (separate session, post-merge) = fleet pull + full fleet harvest. FF merge-back offered to user (unblocks Phase 2 + delivers tooling+KB fleet-wide).
Task F2: complete (commit 2417478 — sonnet impl / sonnet review, Approved). merge_sessions_into(local,remote)->int in distill.py: unions remote sessions by session-id, higher last_line wins (never rewind), takes whole entry, preserves last_refresh + other top-level keys, json.dump indent=2 sort_keys. `--merge-from` CLI added (--match/--out now required=False, validated in main via ap.error; old invocation unchanged). fleet-gather.sh: seed remote ~/.cache with git-tracked state (rsync, mkdir -p .cache) BEFORE remote distill; merge remote state back via mktemp+`--merge-from` AFTER success; all new lines set-e-safe, tmp always cleaned. SKILL.md Step 1 updated. Controller smoke-verified: old CLI intact (56 seen/55 new on this box), merge gave sessions_merged:1 with stale remote last_line=3 NOT rewinding local=9, NEW added, last_refresh kept. 11 distill tests + fleet PASS. Minor follow-ups: non-dict STATE file → AttributeError (pre-existing pattern in _load_state; state files are our own output); corrupt-remote-JSON branch + CLI-validation paths not unit-tested (smoke-covered).
Final-review fixes: complete (commit a374328 — sonnet fix, controller-verified directly). #1 remote path → ~/.claude/skills/cyphy/skills/kb-refresh/distill.py (+ ssh exit-code split 255=unreachable/else=remote-failed, set-e-safe `|| rc=$?`; quoting untouched). #3 `if not isinstance(ev,dict): continue` in distill_lines after decode guard (+regression test; 7 pass). #4 SKILL.md abort-recovery note (state advances at gather, before commit → rm/checkout state before retry). Deferred: #2 fleet-wide read-once (design-level, follow-up), all Minors. Task 6 fleet gather BLOCKED until refresh-kb merges to main + fleet pull (deployment reality, confirmed).
Task 5: complete (commit 10573ac — sonnet impl / haiku accuracy review, Approved, 0 issues). SKILL.md orchestration doc: all 4 invariants verbatim; Steps 0–6 (resolve/gather+distill/map/Track B/reduce/review gate/write+stamp); review gate MANDATORY + pre-write; state ownership correct (distill.py→sessions, write stage→last_refresh merge-preserving); provenance single-stamp-line-replaced; tier table FILLED (global.md/hosts/project.md/CLAUDE.md/docs) matching spec + repo memory wiring. Reviewer cross-checked every distill.py/fleet-gather.sh flag against actual source — all ✅; no placeholders. Controller also read the full file (will follow it in Task 6).
Task 4: complete (feat 1762233 + self-exclude fix d768141 — haiku impl / sonnet review / sonnet fix, Spec ✅ after fix). detect_hosts (only tested surface) matches spec: 3 workstation aliases, hub never, anchored grep (no HostName/substring false-match); test PASS. Test-harness deviation (export HOME vs brief's inline HOME= prefix) verified correct + non-weakening (bash scoping: env-prefix doesn't persist HOME to post-source detect_hosts call; KB_GATHER_NO_MAIN=1 still gates main off during source). main runs local + remote-in-place distill, rsync pulls ONLY digests (raw transcripts never leave box), forces bash for fish. Review raised 2 Important (both plan-mandated): #2 malformed remote cmd = FALSE POSITIVE (adjudicated w/ evidence above); #1 self-exclusion = REAL, user-decided → fixed via runtime probe. Removed stray subagent scratch file script2.sh from repo root.
Task 3: complete (feat 9a02407 + fix 50889e4, review + re-review clean — haiku impl / sonnet review / sonnet fix / sonnet re-review, Spec ✅, Approved after fixes). run() globs *<m>*/*.jsonl, distills from resume offset, writes headered digests + manifest.tsv (append), merge-writes `sessions` preserving `last_refresh` (verified by test seeding last_refresh). Read-once verified (2nd run over unchanged file → 0 digests; last_line/id_hash always advance). Review found 1 Important: unguarded `json.loads(lines[0])` probe could abort the whole sweep on a malformed first line → FIXED (try/except JSONDecodeError,AttributeError → filename fallback) + bundled Minor (cwd/last_ts clobbered to None on no-op run → FIXED via prev-entry fallback). 2 regression tests added (malformed-first-line survives sweep + processes 2nd session; cwd survives no-op run). 6 tests pass. Remaining Minor (final-review triage): sessions_with_new always == digests_written (redundant field); `# host: None` in header when --host omitted (SKILL always supplies --host).
Task 2: complete (commit 493a4de, review clean — haiku impl / sonnet review, Spec ✅, Approved, 0 Critical/Important). Added identity_hash + resume_offset + import hashlib; verbatim from brief. Reviewer verified all 4 branch cases (new/truncated-strict->/identity-changed/resume) line-by-line; truncation uses strict `>` (exact-length resume not misclassified); Task 1 distill_lines + its test provably untouched. Minor: cosmetic 1-blank-line spacing between new test defs; partial-state (missing id_hash/last_line key) untested — current default safely reprocesses.
Task 1: complete (commit fc07528, review clean — haiku impl / sonnet review, Spec ✅, Approved, 0 Critical/Important). Verbatim transcription of brief's reference code; distill_lines(lines)->(digest,meta); stdlib-only (import json); no filesystem access so read-only constraint holds by construction. Reviewer traced all 6 test events by hand, confirmed PASS. 3 Minor findings logged above (all inherited from plan code) + 1 report-accuracy slip (report said cwd/branch first-wins; code is last-wins — no code impact).

---

# Fleet-Gather Windows Support — SDD Progress Ledger (plan #2)

Plan: docs/superpowers/plans/2026-07-19-fleet-gather-windows.md
Spec: docs/superpowers/specs/2026-07-19-fleet-gather-windows-design.md
Branch: refresh-kb (worktree; base main at /home/me/machines).
BASE @ 0298c6f (plan commit; final-review MERGE_BASE = 0298c6f).

ENVIRONMENT:
- jq 1.8.2 present; grep -P works. Offline test: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
- CONTROLLER RESOLUTION (all tasks): new pure-fn test blocks go BEFORE the legacy detect_hosts
  invocation (old lines 21-24) so new assertions stay observable across Tasks 1-4; the legacy
  call aborts under set -e once FLEET_WORKSTATIONS is removed (Task 1), and Task 5 rewrites it.
- Job 2 (live harvest) is OUT OF SCOPE — code + offline tests only; never run main.

## Tasks (plan #2)
- [x] Task 1: fleet_hosts — fleet.json → per-host tuples
- [x] Task 2: roots_for_platform — Windows profile + WSL roots
- [x] Task 3: local_host_id — live hostname → fleet detect.hostname
- [x] Task 4: remote_distill_script — static argv-driven remote distiller
- [x] Task 5: detect_hosts drives off fleet.json + fix its test
- [x] Task 6: main rewrite — platform-dispatch IO (cat/tar, bash-wrapped, pushed distiller)
- [x] Task 7: docs — project.md caveat + SKILL.md remote-path description
- [x] FINAL whole-branch review

## Log (plan #2)
Task 1: complete (commit 0298c6f..0b1a7cf, review clean — haiku impl / sonnet review, Spec ✅, Approved). fleet_hosts reads fleet.json, hub excluded via ssh.host==null, 4-field TSV. Legacy detect_hosts block left aborting (planned Task 5). New assertions placed before legacy block per controller resolution.
Task 2: complete (commit 0b1a7cf..58200f7, review clean — haiku impl / sonnet review, Spec ✅, Approved). roots_for_platform: windows→profile+WSL (literal ~ preserved), unix→~/.claude/projects. fail/eq helpers added after trap. New block before legacy detect_hosts.
Task 3: complete (commit 58200f7..f8f4bfe, review clean — haiku impl / sonnet review, Spec ✅, Approved). local_host_id: known→canonical detect.hostname, unknown→passthrough; null-safe jq, missing-file falls through. Assertions inside jq guard. Minors: head -1 on dup hostnames (invariant-guarded), no in-fn jq guard (matches file style).
Task 4: complete (commit f8f4bfe..5033764, review clean — haiku impl / sonnet review, Spec ✅, Approved). remote_distill_script: single-quoted heredoc (static, no emit-time interp), argv parsing host/nroots/roots/matches, ${root/#\~/$HOME} expansion, per-root distill.py invocation, bash -n clean. Byte-exact to brief. Reviewer note: test greps+bash -n only, never executes emitted script w/ sample args (shift-count not runtime-verified; manual trace confirms correct).
Task 5: complete (commit 5033764..6a1103d, review clean — haiku impl / sonnet review, Spec ✅, Approved). FULL SUITE GREEN (PASS, exit 0) — legacy-block breakage resolved. detect_hosts now consumes fleet_hosts, anchored Host grep preserved (no HostName/substring false-match), emits full tuple, rc0 on missing config. FLEET_WORKSTATIONS fully gone (0 repo hits). Minor: `local alias` shadows builtin (harmless, brief-dictated). CARRY TO T6 REVIEW: main() still `for h in $(detect_hosts)` — word-splits on tuple tabs; Task 6's main rewrite MUST replace it with `while IFS=$'\t' read -r alias platform hostid user; do … done < <(detect_hosts …)`.
Task 6: complete (commit 6a1103d..8c7d4d0 impl + fix 1f50412 — haiku impl / sonnet review / sonnet fix). Spec ✅. Review found CRITICAL stdin-drain: bare ssh inside `while read … done < <(detect_hosts)` drains the loop's process-sub stream → sweep stops after 1 host. Bug was in the PLAN's code too, not implementer error. FIXED: ssh -n on the 4 unredirected loop calls (probe/mkdir/state-pull/tar); NOT on the 2 cat> pushes (< file) or the piped distill dispatch. Controller independently verified -n audit + bash -n + suite green — accepted without re-review (surgical, matches reviewer's prescribed remedy; final whole-branch review is backstop). Also fixed stale line-3 rsync comment. Plan doc code block corrected to match (commit follows).
Task 7: complete (commit bf16683..08e5cb7 + adjacent-fix 8f-follow — haiku impl / sonnet accuracy review, Spec ✅, Accuracy Approved). SKILL.md Step 1 + project.md bullet rewritten to shipped mechanism (platform dispatch, cat/tar, pushed distiller, detect.hostname); SKILL.md rsync-free. Reviewer cross-checked every prose claim against main()/helpers/distill.py --merge-from — all TRUE. Adjacent Important: project.md:649 stale 'rsyncs back' line (contradicted the new bullet 2 lines up) — controller fixed directly (rsyncs→copies via cat/tar). project.md now rsync-clean except the '(no rsync)' assertion.
FINAL REVIEW (opus, 0298c6f..4bd9bf9): **Ready to merge.** End-to-end trace clean: argv contract lines up for 1-root unix + 2-root Windows; Critical fix 1f50412 complete/coherent (ssh -n on 4 loop calls, absent on 3 redirected); set -e safety holds (unreachable host skips, no sweep abort); self-exclusion correct incl Windows-controller-probing-self + empty-probe guard; docs match code. All 4 logged minors DEFERRED.
NEW MINORS (non-blocking, DEFERRED — consistent w/ approved spec which kept local NixOS controller on single stock root):
  (a) Local distill is platform-blind: main hardcodes local --projects-root ~/.claude/projects, doesn't iterate roots_for_platform locally. If a WINDOWS box were ever controller, its own Windows-profile transcripts missed locally AND it self-excludes remotely → never harvested. Out of scope: spec fixed local=NixOS latitude=single root. KNOWN LIMITATION (one-line fix available if a Windows controller is ever needed).
  (b) --exclude=manifest.tsv drops remote manifest rows — intentional (prevents clobber; SKILL Step 2 globs *.md, nothing consumes remote manifest). Deliberate, not a defect.
STATUS: Job 1 COMPLETE. 10 commits 0298c6f..4bd9bf9. Offline suite green, bash -n clean. Job 2 (live harvest) downstream, runs from ~/machines after FF-merge. Merge-back = user-gated (worktree mode).

## LIVE HARVEST (Job 2, 2026-07-19) — bug found + fixed + verified
- First run (shipped form-A tool): local latitude 2 digests; desktop + server both
  "skipped (unreachable)". FALSE negative — direct ssh to both boxes WORKED (g614jv,
  methe-server; WSL bash 5.3.9, HOME=/home/me, python 3.14, both projects roots present).
- ROOT CAUSE (empirical A/B/C/D/E test): inline `ssh h bash -lc 'cmd'` fails. ssh FLATTENS
  its argv into one command string, so LOCAL single-quotes are consumed before the remote
  shell sees them → remote gets `bash -lc mkdir -p ~/x` → `bash -c` runs only word `mkdir`
  (no args) → uutils mkdir 0.8.0 "no dirs provided" → reported "unreachable". `hostname`
  survived only because it's one word. Form B (nested `bash -lc "'cmd'"`, the handoff's
  validated manual form) and form D (piped `bash -s`) both work. Plan's Global Constraint
  literally prescribed the broken form A; offline tests + static reviews could not catch it
  (none exercised real ssh). Advisor consulted, confirmed.
- FIX (commit 4790c5f, branch refresh-kb): 6 inline `bash -lc 'cmd'` → `bash -lc "'cmd'"`,
  preserving -n / < file / pipe semantics per advisor matrix (probe/mkdir/state-pull/tar keep -n;
  2 cat> pushes keep < file, no -n; distill dispatch line 150 = form D, UNCHANGED). Verified
  argv survives dispatch: 5 args intact, `~/.claude/projects` arrives expanded to /home/me/... by
  remote WSL bash (harmless — same as ${root/#~/$HOME} intended). Spec updated w/ nested-quote rule.
- SECOND run (fixed tool): BOTH Windows boxes REACHED + harvested. desktop g614jv: profile root
  22 seen/0 new, WSL root 38 seen/1 new (1 digest). server methe-server: profile 10 seen/0 new,
  WSL 0 seen/0 new. Read-once correct (Phase-2 sessions skipped). Watermark 105→107.
- HARVEST OUTCOME: 3 genuinely-new digests (mtime>=23:30): 8c866a7f + 9fc6b575 = THIS work session
  on latitude (self-referential fleet-gather work, already in commits/plan/ledger); c3c430cb = g614jv
  11-line throwaway in machines/test worktree. NEAR-EMPTY of durable new facts (as handoff predicted).
  Scratch also holds 44 STALE carry-over digests from the 21:21 manual harvest.
- TOOL WART (follow-up): tar pull grabs the ENTIRE remote ~/.cache/kb-digests, which still holds the
  2026-07-19 manual-harvest leftovers → stale digests pile into scratch. Options: clean remote
  ~/.cache/kb-digests before distilling, or pull only files newer than run-start. Not fixed this run.
- DURABLE LEARNING to record (proposed to user): the ssh-argv-flatten quoting gotcha (refines the
  global fleet-SSH note — inline `bash -lc 'cmd'` also fails, not only PowerShell &&/quoting).
- PENDING USER DECISIONS: (1) FF merge-back form-B fix (4790c5f) + spec/plan notes to main; (2) KB
  refresh is near-empty → recommend SKIP full map/reduce/write, just record the ssh-quoting learning;
  (3) tool wart — record as follow-up vs fix now.

---

# Fleet Hostname Normalization — SDD Progress Ledger (plan #3)

Plan: docs/superpowers/plans/2026-07-20-fleet-hostname-normalization.md
Spec: docs/superpowers/specs/2026-07-19-fleet-hostname-normalization-design.md
Branch: orca-setup-script-hint (worktree; base main at /home/me/machines).
BASE @ 3cfd60b (plan commit). Branch MERGE_BASE = 7569e45.

SCOPE THIS RUN: Phase 1 (Tasks 1-4) only — box-independent, mergeable now.
Phase 2 (Tasks 6-7) gated on USER running `Rename-Computer -NewName g513ie -Restart`
on the server box (Task 5). Do NOT execute Phase 2 until Task 5 confirmed.

ENVIRONMENT:
- gortex daemon NOT running this session → Read/Grep/Glob/Edit hooks disabled;
  subagents use standard file tools (not gortex MCP).
- Nix gate: `bash scripts/quick-check.sh` (this worktree is on the NixOS box latitude5520).

## Tasks (plan #3)
- [x] Task 1: git mv hosts/homeserver -> hosts/server + rewrite path refs
- [x] Task 2: git mv hosts/g16 -> hosts/desktop + bootstrap URL + path refs
- [x] Task 3: g513ie.md primary + methe-server.md symlink + dual-name prose
- [x] Task 4: two-layer convention + model docs (box-independent statements)
- [~] Phase 1 checkpoint: FF merge-back OFFERED to user (pending decision)
- [ ] Phase 2 (Tasks 5-7): GATED on user box rename

Task 1: complete (commit 3cfd60b..fc8d836, review clean — haiku impl / haiku review, Spec ✅, Approved). git mv hosts/homeserver->hosts/server; 3 live path refs rewritten (.claude/memory/project.md x2, agents/hosts/methe-server.md x1). Minor: report's verification grep used --exclude-dir=docs (broader than :!docs/superpowers/); reviewer re-ran correct-scope grep, 0 live refs remain.

Task 2: complete (commit fc8d836..ea0409c impl + fix ff5f48b — haiku impl / haiku review / haiku fix / haiku re-review, Spec ✅, Approved after fix). git mv hosts/g16->hosts/desktop; bootstrap URL in install.ps1 updated; 22 path rewrites across 12 files (README/AGENTS/justfile/install-media/backup.ps1/runbook/project.md/g614jv.md/CLAUDE.md). Review found 2 real defects from the blind sweep: (Critical) g614jv.md `hosts/g16.md` (deleted-file ref) tripped grep -> fixed to bare `g16.md`; (Important) project.md rename-desc tautology hosts/desktop->hosts/desktop -> restored FROM->TO as `g16`->hosts/desktop, `homeserver`->hosts/server. grep clean.
  NOTE for Task 4: project.md hostname-normalization bullet still lumps the (now-DONE) dir renames under 'PENDING'. Task 4 Step 4 should reconcile: dir renames are done; only the methe-server->g513ie OS-hostname flip remains pending (Phase 2).

Task 3: complete (commit ff5f48b..1d5a117, review clean — sonnet impl / sonnet review, Spec ✅, Approved, 0 issues). git mv methe-server.md->g513ie.md; relative compat symlink methe-server.md->g513ie.md (mode 120000, matches ME-G614JV.md precedent); H1 dual-name + 'This box' prose (methe-server today, being renamed to g513ie — does NOT assert g513ie is live yet); model line + Notes preserved byte-for-byte (verified via git show). add+typechange (not R100) confirmed cosmetic, no content loss. Commit scoped (left unrelated progress.md unstaged) = fine.

Task 4: complete. CLAUDE.md is a symlink to AGENTS.md (same inode) — one edit covered both: repo-overview `homeserver` bullet now states model **G513IE**, logical name `server`, OS hostname `methe-server` (**being renamed to `g513ie`**); added a "Two-layer hostname convention" subsection under Hardware Context (logical name vs OS-hostname=model, `hub`/`27608` VPS special-case, explicit note that the server's *live* hostname is still `methe-server`). README.md: fixed the stale "ROG G16 2023" server-model claim -> "ROG G15 2023 (model G513IE)" + convention/target phrasing; left the onboarding table's `methe-server` (line 26) untouched — that's current/operational addressing, not a convention statement. hosts/server/README.md: added model code + convention/target note; also fixed a real broken relative path found while editing (`../g16/windows/...` -> `../desktop/windows/...`, a casualty of Task 2's dir rename that the `hosts/g16` literal-string sweep can't catch since it's a relative ref). .claude/memory/project.md: reconciled the in-flight bullet per Task 2's note — dir renames now recorded DONE, only the `methe-server`->`g513ie` OS-hostname flip stays PENDING (Phase 2); kept the FROM->TO phrasing bare (`g16`->`hosts/desktop`, not `hosts/g16`->`hosts/desktop`) to avoid tripping the literal-string sweep — caught and fixed this exact mistake in a self-review pass before committing. Gate: quick-check.sh green (required files + flake eval + dry-build all pass); full-repo sweep for `hosts/g16`/`hosts/homeserver` outside docs/superpowers + .superpowers is empty.

Task 4: complete (commit 1d5a117..e7dd885 impl + fix 9f046b1 — sonnet impl / sonnet review / sonnet fix / sonnet re-review, Spec ✅, Approved after fix). CLAUDE.md(=AGENTS.md symlink) two-layer convention subsection + server bullet (G513IE, methe-server being renamed to g513ie, NOT asserting g513ie live); README/AGENTS/hosts-server-README methe-server hits reconciled (convention->g513ie, empirical left); server model G16->G15/G513IE fixed; project.md in-flight bullet reconciled (dir renames DONE, only OS-hostname flip PENDING); also fixed broken ../g16/windows relative path in hosts/server/README.md. Review found Important spec gap (spec Component 4): docs still presented retired g16 as a LIVE NixOS host. Advisor-confirmed in-scope. FIX 9f046b1 (advisor-guided full sweep + discriminator): removed README desktop-bullet live-NixOS claim, phantom hosts/desktop/nixos entry, ### g16 NVIDIA PRIME section, and root-CLAUDE ### g16 Hardware Context subsection (### Both hosts facts merged into latitude, none lost). quick-check green; hosts/g16|hosts/homeserver grep empty; surviving g16 mentions all accurate-history/model-name.

PHASE 1 COMPLETE (Tasks 1-4). Impl range 3cfd60b..9f046b1.

## Minor follow-ups (out of Component-4 scope; for final review triage / later pass)
- README.md:119 `hosts/latitude5520/nixos/` is a stale path — the latitude dir is `hosts/latitude` (per AGENTS.md:120). Latitude-scope, not touched (advisor: don't touch latitude sections).
- .claude/memory/project.md ~line 346 `hosts/{g16,homeserver}/windows/winget-packages.json` — stale brace-notation path (escaped Tasks 1-2 grep because `hosts/{g16,` != `hosts/g16`). In a dated historical log entry; left as history.

FINAL WHOLE-BRANCH REVIEW (opus, 3cfd60b..9f046b1): **Ready to merge.** 0 Critical/0 Important. Verified: live path sweep clean (incl brace-form check), fleet.json still methe-server (Phase-2 flip correctly withheld), bootstrap URL->hosts/desktop, symlinks mode 120000 + g513ie.md content intact, NO premature 'g513ie is live' assertion, nix gate green, models never swapped (server=G15/G513IE, desktop=G16/G614JV), docs/superpowers untouched. One Minor: g513ie.md caveat cited hosts/server/README.md as mislabeling server (branch had already fixed that file).
Final-review Minor fix: complete (commit e7acd9a — haiku). g513ie.md caveat now cites only sibling vps CLAUDE.md. Symlink methe-server.md verified still 120000 (not dereferenced).

PHASE 1 DONE + REVIEWED. Impl range 3cfd60b..e7acd9a. Ready for FF merge-back (user-gated). Phase 2 (Tasks 5-7) remains GATED on user box rename.

PHASE 1 MERGED to main (FF 7569e45..13364c8, user-approved). main==branch.
PHASE 2 UNBLOCKED: user ran Rename-Computer + reboot. Box verified live 2026-07-20: `ssh server hostname`=g513ie, $env:COMPUTERNAME=G513IE. fleet_detect Windows uses -ieq (case-insensitive) so g513ie matches G513IE.
  RESTIC CAVEAT: user rebooted before the Task-5-Step-1 restic --host pre-check was confirmed. Snapshot host-identity may have forked to g513ie (operational, vps-repo concern, not a machines repo change). FLAG to user post-Phase-2.
- [x] Task 6: flip fleet.json detect.hostname + empirical statements -> g513ie
- [x] Task 7: verify fleet_detect + invariant sweep (merge-back pending user)

Task 6: complete (commit 13364c8..8fe6162 impl + fix 2ec5e04 — sonnet impl / sonnet review / haiku fix, Spec ✅, Approved). fleet.json server.detect.hostname->g513ie; global.md verified-live bullet + SSH bullets->g513ie (2026-07-20); AGENTS.md(=CLAUDE.md) + g513ie.md state g513ie as CURRENT (renamed from methe-server); provision/fleet-authorized-keys comment->methe@g513ie; project.md rename recorded DONE. Implementer expanded scope (justified): also flipped README.md/install-media/README.md/g614jv.md/hosts/server/README.md (identical stale 'being renamed' claims) + rustdesk-config.nix peer display label (cosmetic, keyed by RustDesk ID — verified non-functional). Review found 1 Important: backup.ps1:278 + windows-reinstall-runbook.md:92,93 had EXECUTABLE scp/rsync cmds to 'methe-server' (never a wired SSH alias) -> FIX 2ec5e04 retargeted all hosts/desktop/windows methe-server refs to the 'server' alias (7 replacements). Left correctly: compat symlink, accurate history, test fixtures (test_fleet_gather.sh PASS), kb-harvest-state.json + project.md dated log entries.

Task 7: verification complete (main session). fleet_detect logic verified: jq query with hostname=g513ie vs branch fleet.json -> 'server' (matches fleet_detect() impl which reads live hostname). Invariant sweep: no hosts/g16|hosts/homeserver; fleet.json map latitude5520/g614jv/g513ie/27608; agents/hosts tier correct (g513ie.md/g614jv.md/latitude5520.md real; methe-server.md->g513ie.md, ME-G614JV.md->g614jv.md symlinks). Box live-verified g513ie earlier. NOTE: on-box fleet_detect returns 'server' only AFTER Phase 2 merges to main + box git pull (main still has Phase-1 methe-server until merge). Final review: Phase-2 diff (1 flip + 1 doc fix) already adversarially reviewed at task level + end-to-end verified; no redundant whole-branch opus pass.

PHASE 2 COMPLETE + VERIFIED. Impl range 13364c8..2ec5e04. Ready for FF merge-back (user-gated).

## RECONCILIATION with concurrent other-box work (origin/main divergence)
On push, origin/main was 3 ahead: a CONCURRENT hostname normalization authored on the g513ie box (~1h prior, author 'Maxim') from the same merge-base 7569e45. It AGREED on fleet.json (server->g513ie) but DIVERGED: model-named repo dirs (hosts/g16 kept, hosts/homeserver->hosts/g513ie) + uppercase G513IE.md, no compat symlink — contradicting the user's locked 'dir=fleet key, full consistency' decisions.
USER DECISION: 'This session supersedes.' Reconciled by:
1. Verified filename-case: bootstrap host_id()=${COMPUTERNAME:-hostname} (case-preserved) -> box resolves G513IE (native) / g513ie (WSL). Differ only by case -> can't coexist on box NTFS (case-insensitive); single lowercase g513ie.md resolves BOTH there. Our approach functionally correct (unlike ME-G614JV/g614jv which differ beyond case and need 2 files).
2. SALVAGED (commit 1662d39) 7 unique host-memory notes from their G513IE.md into our g513ie.md (sshd administrators_authorized_keys; PowerShell-7 MSI-not-Store for sshd DefaultShell; headless git-push account key id_ed25519_gh vs telegrind deploy key; Docker credsStore removal; WSL2 mount-wedge wsl --shutdown; MSYS_NO_PATHCONV=1; kb-refresh no-jq/PYTHONUTF8=1) + the confirmed Docker-stack list. Their global.md/project.md/g614jv.md edits were pure label-swaps (no unique facts).
3. merge -s ours origin/main (commit 7b7db78): our two-layer tree kept, their 3 commits preserved in history, their tree superseded. Pushed to origin (ed8d784..7b7db78).

FLEET SYNC PENDING: g513ie box + other fleet boxes must 'git pull'. On the g513ie box the pull is a clean FF (origin now contains their commits as ancestors); working tree will swap hosts/g16+hosts/g513ie -> hosts/desktop+hosts/server and G513IE.md -> g513ie.md.
STILL OPEN: restic --host snapshot-identity check (user rebooted before Task-5-Step-1 pre-check).
WORKTREE: orca-setup-script-hint branch @1662d39 is now an ancestor of main (7b7db78) -> fully merged, safe to remove (user-gated).
