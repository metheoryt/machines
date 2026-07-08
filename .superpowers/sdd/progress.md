# Fleet Provisioner Phase 5b (mesh conf-fetch executors) — SDD Progress Ledger

(5a ledger archived to progress-5a.md — 5a COMPLETE + real-box verified, HEAD was ebd4fa8..)

Plan: docs/superpowers/plans/2026-07-09-fleet-provisioner-phase5b-mesh-executors.md
Branch: main (per-task commits, as Phases 1-5a).
machines BASE @ b6fb624 (final-review MERGE_BASE).
vps repo BASE @ 49ffcdf (Task 1 lands in the SIBLING ~/my/vps repo, its own origin).

ENVIRONMENT (this Windows box, g614jv):
- jq + bash live in WSL, NOT on Git Bash PATH. Run ALL posix gates via
  `wsl -e bash -lc 'cd /mnt/c/Users/methe/machines && ...'`.
- shellcheck absent everywhere -> gates skip it gracefully (parse gate only).
- *.sh pinned to eol=lf via .gitattributes; PowerShell tolerates CRLF.
- DEFERRED (not session-verifiable here):
  - Task 2 Step 3 `[nix box]` gate (nix eval / dry-build) -> latitude5520 after pull.
  - ALL real-box apply steps (SSH fetch, NixOS key install+reboot, Windows import)
    -> Task 7 runbook, executed with VPS/real-box access.

## Tasks
- [x] Task 1: ~/my/vps manage-peers.sh — non-interactive add <name> <ip> + --conf-only (CROSS-REPO)
- [x] Task 2: fleet.json — vps.ssh.host + vps.mesh.managePeers
- [x] Task 3: provision/lib/mesh.sh + mesh.test.sh — posix conf-fetch helper
- [x] Task 4: provision/roles/mesh-member.sh — NixOS key-fetch + verifier
- [x] Task 5: provision/lib/Mesh.psm1 + roles/mesh-member.ps1 — Windows conf-fetch + verify
- [x] Task 6: mesh-hub.{sh,ps1} no-op pointers + provision.ps1 dispatch wiring
- [x] Task 7: project.md memory + acceptance sweep + real-box runbook

## Minor findings (for final review triage)
- Task 1 (vps): bare-global CONF_ONLY/args style + `${args[N]:-}` under set -u — pre-existing
  script style, consistent; verify under shellcheck once available on a Linux box. Non-blocking.
- Task 3: mesh_manual_hint has no direct test coverage (stderr-only informational text, no secret
  risk). Cosmetic heredoc spacing inconsistency. Non-blocking.
- Task 4: (resolved as IMPORTANT fix feacff5) — no residual Minor.
- Task 5: `$target/$script/$peer/$ip` recomputed in 3 functions (mirrors mesh.sh parity); Write-Host
  vs Write-Warning stream split in manual hint — both brief-specified, cosmetic. Non-blocking.
- OPEN ASSUMPTION (real-box, out of session scope): whether /etc/amnezia-wg pre-exists on NixOS is
  now moot — mesh-member.sh uses `install -D` (creates the parent dir). Windows conf ACL verified.

## Log
Task 1: complete (vps commit 46625e1, PUSHED to vps origin 49ffcdf..46625e1; review clean —
  Spec ✅, Approved; reviewer independently confirmed all cmd_add mutations run BEFORE the
  CONF_ONLY short-circuit; 2 non-blocking Minor = pre-existing bare-global style + shellcheck-
  when-available note).
Task 2: complete (machines commit 8132931, review clean — Spec ✅, Approved, no findings;
  only vps block changed 2+/2-, other 3 machines byte-identical, 5a peerNames intact, valid JSON,
  no .nix touched. Step 3 [nix box] gate DEFERRED to latitude5520. Not pushed — batched.)
Task 3: complete (commits 5ac9cac + fix 35b785c; HEAD 35b785c). Review: Spec ✅, Approved;
  reviewer independently re-ran unit test (ALL TESTS PASS) + confirmed by control-flow that key
  only reaches stdout, show short-circuits before add, no rotation.
  1 IMPORTANT finding (test-coverage gap: plan's verbatim stub always failed `show`, so no test
  proved a SUCCESSFUL show suppresses add). User chose "augment test now" -> fix 35b785c added
  scenario 4 (show succeeds -> assert stored key reused + NO add line). RESOLVED, gate green.
  Controller verified fix delta (only mesh.test.sh +20, no existing assert weakened, LF clean).
Task 4: complete (commits 4d03177 + fix feacff5; HEAD feacff5). Review: Spec ✅ (verbatim to
  brief), Code quality Needs-work -> 1 IMPORTANT + 1 Minor.
  IMPORTANT (inherited from plan's own snippet): unguarded sudo install/tee -> on a box where
  /etc/amnezia-wg doesn't pre-exist, could fall through to false "wrote" success or default-perms
  key (role fn runs under disabled errexit as an if-condition). User chose "fix now" -> feacff5
  added install -D + ||return 1 guards on both install and tee, success line only after both;
  Minor: verify &&/|| -> explicit if/else. Guard-proof gate: failing install => rc=1, no false
  wrote, no key leak. Controller verified delta (only mesh-member.sh +13/-3, existing guards intact).
Task 5: complete (commits 5da6b29 + fix f3eaaca; HEAD f3eaaca). Review: Spec ✅ (verbatim to
  brief; 7 exports, show-then-add, key never logged, dry-run key-redacted, native ConvertFrom-Json),
  Code quality Needs-work -> 1 IMPORTANT.
  IMPORTANT (inherited from plan's own snippet): awg0.conf written world-readable — C:\ProgramData
  inherits Users:Read+Write, so the private key was readable/writable by any local user (vs posix
  root:600). User chose "fix now" -> f3eaaca: after Set-Content, icacls /inheritance:r + grant
  current-user(R,W) + Administrators SID(F); removes the file if ACL fails. Gate B proved via Get-Acl
  (no Users/Everyone, inheritance off). Controller verified delta (only .ps1 +14/-1).
  NOTE: Task 5 Step 4 (confirm-gate decline) was DEFERRED to Task 6 (needs provision.ps1 wiring).
Task 6: complete (commit b5f4f43; HEAD b5f4f43). Review: Spec ✅, Approved, no findings.
  mesh-hub.{sh,ps1} pure no-op pointers (both modes); provision.ps1 $RoleExecutors gained
  mesh-member + mesh-hub (3 "deletions" = re-alignment, all 5 entries present); provision.sh
  ZERO diff (auto-discovers). Both wiring gates re-run by reviewer: real ~ would ssh plan (not
  fallback) on posix+windows. Confirm-gate decline (was Task 5 Step 4) PASS: rc=0, nothing written.
Task 7: complete (commit 88a490b; HEAD 88a490b). Review: Spec ✅, Approved, no findings.
  Full session sweep GREEN (parse + ALL TESTS PASS + posix member plan + hub pointer + 2 Windows
  lines). project.md 5b bullets accurate (reviewer cross-checked every fact vs live repo), curated
  (no 5a dup, +33/-0), runbook complete, no secrets. Hardening facts (install -D guard, icacls lock)
  recorded.
ALL TASKS COMPLETE — proceeding to final whole-branch review.
  machines range: b6fb624..88a490b. vps range: 49ffcdf..46625e1 (already pushed + reviewed).
  NOT pushed yet (machines): batched to after final review / finishing-branch decision.
FINAL REVIEW (opus, b6fb624..88a490b): Ready to merge = WITH FIXES. All 9 Global Constraints
  honored; dispatch/parity/graceful-degradation correct both platforms; unit test ALL TESTS PASS;
  posix hardening solid. 1 gating IMPORTANT + 4 Minor.
  IMPORTANT (cross-platform, per-task reviews couldn't see): Windows create-then-lock ORDERING
  WINDOW — Set-Content wrote the key BEFORE icacls locked, so the conf was briefly world-readable
  (C:\ProgramData inherits Users:Read), unlike posix install -m600 which creates locked-first.
  -> fix ed9b351: reorder to New-Item(empty)->icacls-lock->Set-Content; also fold in PrivateKey
  guard (posix parity) + throw on ACL failure (honest, not false "applied"). Gate B proved: write
  succeeds after lock, no Users in ACL. Controller verified delta (only .ps1 +14/-9).
  DEFERRED Minors (cosmetic, non-blocking): hardcoded hub 10.0.0.1 in Windows ping (stable const,
  verify-only); target/peer recompute in 3 psm1 fns (mesh.sh parity); unanchored [Interface] match;
  Task1 vps bare-global style; mesh_manual_hint no direct test.
  DEFERRED real-box (out of session): [nix box] eval/dry-build on latitude5520; SSH fetch;
  NixOS key install+reboot into 6.18.38; Windows GUI import.
FINAL HEAD (machines): ed9b351.
FINISH: user chose "push main to origin". Push initially rejected — origin had 4 unrelated commits
  (pylsp fork/fixes + gortex daemon unit; flake.nix, modules/home/me.nix, project.md tail) pushed
  after merge-base 4241b4c (which already includes the 5a real-box fixes, so 5b was correctly based
  on 5a). NOT force-pushed. Merged origin/main into main (merge commit; repo has precedent for
  origin/main reconciliation merges). Only shared file project.md auto-merged cleanly (5b bullets
  mid-file vs their Pending-follow-ups section at end — disjoint regions). Post-merge: both regions
  present, mesh.test.sh ALL TESTS PASS. PUSHED: b549500..a07053e. main == origin/main.
PHASE 5B COMPLETE (session-verifiable scope). Remaining = real-box runbook (latitude5520 [nix box]
  gate + pull/apply/reboot; VPS pull+smoke; Windows import) — executed with real-box access.
