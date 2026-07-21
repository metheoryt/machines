# Fleet converge self-healing sync — SDD Progress Ledger

Plan: docs/superpowers/plans/2026-07-21-fleet-converge-self-healing-sync.md
Spec: docs/superpowers/specs/2026-07-21-fleet-converge-self-healing-sync-design.md
Branch: converge-selfheal (in-place on main checkout at /mnt/c/Users/methe/machines).
BASE @ 204bb81 (plan commit; final-review MERGE_BASE = 204bb81).

ENVIRONMENT:
- Dev box = WSL/Windows, NO Nix. NixOS dry-build (Task 3) + real converge DEFER to latitude after branch pull.
- Bash tests: `bash scripts/converge.test.sh` etc. Idiom: `*_LIB_ONLY=1` sourcing, pass/die/eq, PATH mocks.
- Constraint: convergence must NEVER dirty tracked tree (writes only .machines/).
- Exclude work repos (thepureapp/*). --ff-only fleet-wide.

## Tasks
- [x] Task 1: scripts/converge.sh engine + .machines/ state root (commits 565ff14..9cdd818, review Approved, exec-bit fix landed)
- [x] Task 2: extend agents/git-hooks/post-merge (commit 9cdeb64, review Approved)
- [x] Task 3: machines-converge.nix + self-update.nix retarget (commits 74f954e, +3da8371 doc-fix; review Approved) — DRY-BUILD + LIVE CONVERGE STILL PENDING ON LATITUDE (see below)
- [x] Task 4: fleet-selfpull.{sh,ps1} + windows.ps1/linux.sh (commit bf2eb41 + fix a21a5f4; review Approved after fixing 2 Important: batch-mode git guard + service timeout, no-upstream-gate test)
- [x] Task 5: /ship convergence column (commit 19ade19, review Approved; also fixed 2 pre-existing test-fixture host-collisions, verified legit — production roots untouched)
- [x] FINAL whole-branch review (opus, 204bb81..19ade19): found C1 CRITICAL (flake attr $(hostname)=latitude5520 ≠ attr `latitude`) + I1 comment + triaged Minors
- [x] Fix wave (commit c64339c): C1 flake hostname-alias, I1 comment, T1 REPO guard, T2 setsid/nohup fallback. Re-review Resolved (converge.test 9/9, post-merge.test 2/2). T4/T5 left as documented fast-follow.
- BRANCH APPROVED to merge — GATED on latitude nix-eval + live converge, and Windows task-registration verification (see deferred lists).

## Minor findings roll-up (for final review)
- T1 converge.sh:16 — `REPO="$(CDPATH= cd .. && pwd)"` has no exit check; contrived empty-$0 invocation → REPO="" → .machines at FS root. Inherited from brief, non-blocking. (Fix if hardening.)
- T2 post-merge:47 — `setsid sh "$converge" &` has no `command -v setsid` fallback; if setsid absent, "not found" swallowed by 2>/dev/null → converge silently doesn't fire. Brief-mandated; setsid is util-linux (present on WSL/Debian/NixOS). (Fix if minimal-image support needed.)

## Minor (T4) — cron fallback loses jitter under dash ($RANDOM unset → 0); pull still runs. systemd-user is primary. Non-fatal.
## Minor (T5) — fleet-pull.sh:77 malformed last-converge (missing rev=) → token conv:ok@ (empty short-rev) not conv:none. Task-1 writer always populates both; theoretical.

## WINDOWS / live-provision verification
- [x] desktop (g614jv) + server (g513ie): windows.ps1 registers machines-converge (SYSTEM) + fleet-selfpull (10m) green (2026-07-21). Required fix 7bc36f5 (RepetitionDuration MaxValue → blank; MaxValue serialized to out-of-range P99999999DT23H59M59S). schtasks run confirmed.
- T4 linux.sh: systemctl --user branch actually enables in a real (non-container) session; WSL may lack a running user systemd manager → cron fallback path. (No non-WSL Linux fleet box currently; unverified, low-risk.)

## MERGED to main (42fa56f pushed). Rebased onto origin deps-bump (6815b58); 4 suites ALL PASS post-rebase.

## LATITUDE verification
- [x] Task 3 dry-build: PASS on latitude5520 (2026-07-21). Evaluated clean; built machines-converge.path/.service + retargeted nix-repo-auto-pull.service; net-tools-2.10 fetched (pkgs.nettools/hostname OK); flake hostname-alias resolved.
- [x] Live converge chain fired on latitude (2026-07-21): switched → real ff-pull → machines-converge.path fired → root machines-converge.service ran converge.sh → git CLI gates PASSED as root → class=nixos, range computed.
- [x] CAUGHT LIVE BUG (fix a1d90aa): nixos-rebuild aborted with libgit2 error 7 "repository path is not owned by current user". The GIT_CONFIG_* env trio fixes the git CLI only; Nix's flake fetcher uses libgit2, which ignores GIT_CONFIG_* and runs its own ownership check. Dry-build (runs as me) never hit it. Fix: ExecStartPre writes safe.directory into root's global gitconfig (both CLI + libgit2 read it); dropped the env trio. Deployed to latitude, ExecStartPre confirmed present.
- [ ] Final confirm: fixed unit yields status=ok on a real-commit trigger (in progress).

## Notes

## trigger-test advance 1 (110123)
