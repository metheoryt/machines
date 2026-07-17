# ssh-wsl.sh (fleet SSH for a disposable WSL node) — SDD Progress Ledger

Plan: docs/superpowers/plans/2026-07-17-ssh-wsl-fleet.md
Spec: docs/superpowers/specs/2026-07-17-ssh-wsl-fleet-design.md
Branch: main (repo workflow: straight to main, commit per task).
BASE @ 0a3589b (plan revision commit; final-review MERGE_BASE).

ENVIRONMENT:
- shellcheck via `nix run nixpkgs#shellcheck -- <files>` (no system shellcheck).
- jq present on dev box. Pure helpers prototyped by controller pre-execution → ALL PASS.
- [WSL] on-box acceptance (Task 2 step 6): needs a real distro → hand to user.

## Tasks
- [x] Task 1: pure helpers (sanitize/render/merge/key_present) + unit tests (TDD)
- [x] Task 2: main orchestration + README
- [x] FINAL whole-branch review

## Minor findings (for final review triage)

## Log

Task1/Minor (for final triage): jq render filter hardcodes "id_fleet" — a 2nd source of truth vs FLEET_KEY_NAME (plan-mandated, low risk; drift only if key name changes).
Task1/Note: implementer report line-counts inaccurate (said 214/189; actual diff 108/81) — report-only, no code impact.
Task 1: complete (commits c7a8c7c..997767e, review clean — Spec ✅, Approved). Reviewer Important (plan-mandated merge-coverage gap) fixed additively in 997767e: added differing-block span-replacement test + exact-marker assertions; ssh-wsl.sh logic unchanged, suite PASS, shellcheck clean. 21+ assertions.

Task2/Minor (final triage): mesh-authorized-keys append (ssh-wsl.sh:203) assumes file ends in \n — could concatenate onto last line if not. MITIGATED in practice: repo's end-of-file-fixer pre-commit hook guarantees committed mesh-authorized-keys ends in \n. Plan-mandated verbatim.
Task2/Minor (final triage): restore branch (ssh-wsl.sh:182) checks only $STORE_KEY not $STORE_KEY.pub — priv-only store → silent .pub install fail + empty PUB_BODY. Very low prob (persist writes both). Plan-mandated verbatim.

Task 2: complete (commit 3ac3d98, review clean — opus reviewer, Spec ✅, Approved; no Critical/Important; SC2015 disables confirmed legit; idempotency + set -u + winuser edge cases traced clean). [WSL] on-box acceptance (Step 6) DEFERRED to user (needs real distro).

FINAL REVIEW (opus, 0a3589b..3ac3d98): Ready to merge = With fixes. No Critical/Important. 5 Minor.
  Fixing pre-merge (one fix wave): #1 vestigial SC2034 disable (main now uses FLEET_KEY_NAME → disable dead + reason wrong); #2 restore branch depends on stored .pub (priv-only store → silent .pub fail + false success) → regenerate pub from priv via ssh-keygen -y; #3 README: add stale-leaf-key pruning note (mirror Headscale node prune); #4 README: tradeoff must state key grants ADMIN ssh (mesh-authorized-keys feeds Windows administrators_authorized_keys + NixOS).
  SKIPPED #5 (EXISTING=$(cat) swallows read error on unreadable ~/.ssh/config): pathological — user owns own 0600 config; YAGNI, not worth a guard.

Fix wave 766348b: all 4 pre-merge Minors applied — #1 SC2034 disable removed; #2 restore derives .pub via `ssh-keygen -y`; #3 README pruning note; #4 README admin-blast-radius. Verified controller-side: shellcheck clean, bash -n clean, unit suite PASS. All fixes are exactly what the review recommended (no re-review needed — additive/mechanical, verified).

## STATUS: PLAN COMPLETE, reviewed, fixes applied. Branch main. 4 feature commits c7a8c7c..766348b.
## PUSHED to origin/main @ 766348b (user chose push-now). eb2aeea..766348b.
## REMAINING (user-owned): [WSL] on-box acceptance (Task 2 Step 6) — needs a real distro. Then operator: commit+push mesh-authorized-keys after first run + re-provision the other boxes to trust id_fleet.
## PLAN COMPLETE + PUSHED 2026-07-17. origin/main @ 766348b.

## FOLLOW-UP (post-merge, user-requested): per-host key naming + live propagation (2026-07-17)
- User asked: key is shared across all distros on a Windows host → name it after the host, not the distro. Chose per-host identity.
- a218508: name key me@wsl-<label>, mapping uname -n → fleet.json detect.hostname (g614jv→desktop→me@wsl-desktop), else sanitized hostname. Added ssh_wsl_host_label pure helper + tests; re-stamp comment on restore.
- 3a3f0f8: FIX real bug — ssh-keygen -y echoes embedded comment (key gen'd with -C) → appending KEY_COMMENT doubled it. Extracted tested ssh_wsl_stamp_pub (keeps type+body only). Caught live during propagation, not by tests initially.
- b55b0a7: relabel deployed mesh-authorized-keys comment → me@wsl-desktop (same body).
- LIVE PROPAGATION done by controller (SSH access from latitude): git (mesh-authorized-keys pushed), HUB (debian@cyphy.kz authorized_keys, verified `ssh hub` from WSL box = HUB_OK as debian@27608). WSL box live+store id_fleet.pub relabeled to me@wsl-desktop (single comment). WSL clone synced.
- REMAINING (need elevation controller lacks): latitude `sudo nixos-rebuild switch`/`just switch`; server+desktop `windows.ps1` as Admin. Then `ssh latitude`/`ssh server`/`ssh desktop` from the WSL box.
