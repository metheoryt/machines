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
- [x] LIVE BUG #1 — libgit2 ownership (fix a1d90aa): nixos-rebuild aborted with libgit2 error 7 "repository path is not owned by current user". GIT_CONFIG_* env fixes the git CLI only; Nix's flake fetcher uses libgit2, which ignores GIT_CONFIG_* and runs its own ownership check. Dry-build (runs as me) never hit it. Fix: ExecStartPre writes safe.directory into root's global gitconfig (both CLI + libgit2 read it); dropped the env trio. VERIFIED: root nixos-rebuild switch succeeds, status=ok.
- [x] LIVE BUG #2 — trigger missed 2nd consecutive advance (fix 41cf9db): path unit watched .git/ORIG_HEAD, which (a) a fast-forward pull does not reliably rewrite, and (b) git rewrites via atomic rename-replace, staling systemd's inotify watch after the first event. Switched PathChanged to .git/logs/HEAD (appended in place on every HEAD advance; refs-only fetch + converge's read-only git calls don't move HEAD → no spurious/self fires). VERIFIED via 2-consecutive-advance test: both C1 and C2 fired, converged-rev tracked HEAD each time.
- [x] Non-nix skip path VERIFIED: range with no *.nix/flake change → status=ok "config already live via symlinks", converged-rev advances (no growing range).

## ALL VERIFICATION COMPLETE — feature live on latitude + both Windows boxes. main @ 78e58f3.

## Notes

## LIVE GATE RESULTS (2026-07-23)
- fleet-pull deploy: server OK 59d4d70..2c91e07 (Windows-native clone FF-pulled via Git Bash!), desktop SKIP dirty, hub SKIP absent. WSL discovery ran clean (empty, no marker yet).
- python3-under-Git-Bash (final-review #1): CONFIRMED bug. desktop python3=Store-stub (Permission denied), python=3.13.14 works. server python3=3.14.2 works. FIXED commit a818490 (remote_distill_script falls back python3->python via execution test). Verified live: desktop resolves `python`, server resolves `python3`.
- fd_wsl_hosts enumeration live-verified: desktop lists Ubuntu-26.04/docker-desktop/Ubuntu-24.04, returns empty (no marker) correctly.
- desktop WSL Ubuntu-26.04 clone: clean, on main, at 59d4d70 (behind), origin correct -> ready for provision-wsl after git pull.

## FOLLOW-UP DOC GAP (not in plan Task 11 scope): kb-refresh/SKILL.md still describes OLD model (WSL-bash dispatch, /mnt/c paths, "Windows harvests both Windows profile AND WSL"). Task 10 changed this to Git-Bash Windows-native + WSL-as-separate-host. Offer to update SKILL.md + reviewer Minor #2 (drop vestigial /mnt/c from roots_for_platform windows) as a follow-up.

## TASK 9 BLOCKED ON USER: provision-wsl must run on desktop box (WSL distro). Instructions presented.

## ALL LIVE GATES PASSED (2026-07-23) — FEATURE COMPLETE
- Task 9 (WSL discovery e2e): PASS. provision-wsl on desktop distro succeeded; fd_wsl_hosts -> desktop-ubuntu26; marker read quoting works (no fix needed); ssh desktop-ubuntu26.gg.ez works (inbound trust + Host *.gg.ez wildcard); /ship shows distinct desktop-ubuntu26 row.
- Task 12 (final /ship): PASS. server + desktop-ubuntu26 FF-pulled to c7d9ac9 via Git-Bash / direct WSL dispatch. desktop=SKIP dirty (pre-existing box state), hub=SKIP absent (no clone).
- Task 10 Step 5 (kb-refresh gather): PASS after 3 live-gate fixes. All hosts distill (latitude 65, desktop 20, server 14, desktop-ubuntu26 25-43). No "remote distill failed".
  * FIX a818490: remote distiller python3->python fallback (desktop python3=Store stub, Permission denied).
  * FIX c7d9ac9: dropped dead /mnt/c root (missing under Git Bash, failed set -e) + pinned encoding=utf-8 on distill.py's 6 opens (native Windows Python cp1252 choked on U+2192).
  * DISPROVEN: reviewer's "binary tar through Windows hop corrupts" — raw tar pull works (desktop 20, server 14 verified directly). No base64 needed.
  * BENIGN: desktop-windows (/c/Users/methe/.claude/projects) and desktop-ubuntu26 (WSL ~/.claude/projects) share the SAME 20 sessions (identical sids + cwd C:\Users\methe\machines) — the WSL distro mirrors the Windows Claude profile. Flat out-dir dedups by sid (last-writer-wins, identical content). Not data loss.

## PUSHED: main @ c7d9ac9 (origin up to date). Feature live on server + desktop-ubuntu26.

## OPEN FOLLOW-UPS (not blockers):
1. kb-refresh/SKILL.md still describes OLD model (WSL-bash dispatch, /mnt/c, "Windows harvests both profile AND WSL"). Should update to: Git-Bash Windows-native harvest + WSL as separate self-declared host. (Task 11 scope didn't include it.)
2. desktop's Windows clone (C:\Users\methe\machines) is DIRTY -> /ship keeps SKIP dirty. User must commit/stash/discard on that box.
3. Branch fleet-reach-every-clone still exists (kept as safety) — safe to delete now.
