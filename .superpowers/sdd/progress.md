# Fleet SSH-over-tailnet + name resolution — SDD Progress Ledger

(Phase 5b ledger archived — 5b COMPLETE + pushed. This is a new plan.)

Plan: docs/superpowers/plans/2026-07-14-fleet-ssh-over-tailnet-and-hosts.md
Spec: docs/superpowers/specs/2026-07-14-fleet-ssh-over-tailnet-and-hosts-design.md
Branch: feat/ssh-over-tailnet
BASE @ a98e58f (branch point from main; final-review MERGE_BASE).

ENVIRONMENT (this Windows box, g614jv):
- jq + bash live in WSL, NOT on Git Bash PATH. Run ALL posix gates via
  `wsl -e bash -lc 'cd /mnt/c/Users/methe/machines && ...'`.
- shellcheck absent everywhere -> gates fall back to parse-only (`bash -n`).
- PowerShell gates: run via the PowerShell tool (native pwsh); the Read-Host
  confirm-gate needs a non-NonInteractive pwsh -> drive with `echo n | pwsh -File`
  from Git Bash.
- *.sh pinned eol=lf via .gitattributes; new *.ps1 = ASCII-only content + UTF-8 BOM.
- DEFERRED (not session-verifiable on this box):
  - ALL `nix eval` / `nix flake check` steps (Task 2 Steps 1/5, Task 3 Steps 4/5)
    -> latitude5520 real-box gate after pull. Implementers do the edits + record
    the exact eval command in the report; controller marks the nix gate deferred.
  - ALL real-box apply steps (latitude switch, vps/Windows hosts apply) -> runbook.

## Tasks
- [x] Task 1: fleet.json — add tailnet.ip to every machine
- [x] Task 2: modules/home/ssh.nix — HostName off AWG onto tailnet
- [x] Task 3: modules/system/fleet-hosts.nix — generate networking.hosts + import
- [x] Task 4: provision/roles/hosts.sh — posix hosts executor
- [x] Task 5: provision/roles/hosts.ps1 + provision.ps1 wiring — Windows hosts executor
- [x] Task 6: fleet.json — enroll the hosts role on every machine

## Minor findings (for final review triage)
- Task 4 (hosts.sh): mktemp staging file not trap-guarded (leak under errexit caller);
  no guard if jq/fleet.json missing (raw jq error). BOTH inherited verbatim from the
  plan's own code, mirror existing role-executor style. Non-blocking.
- Task 5 (hosts.ps1): (a) `Sort-Object Name` (culture-aware, case-insensitive) vs hosts.sh
  `sort_by(.key)` (codepoint) — latent ordering-parity mismatch only for hypothetical
  mixed-case/leading-nonalnum machine names; ordering doesn't affect resolution. (b) dry-run
  preview body emitted via success stream (`$block | ForEach-Object`) not Write-Host — if the
  dispatcher ever CAPTURED the scriptblock return the body could be swallowed; provision.ps1
  invokes `& $exec` uncaptured so it displays. CONFIRM empirically at Task 6 Step 5. Both
  inherited from the brief's code. Non-blocking.

## Log
Task 1: complete (commit 8e7c748, review clean — Spec ✅, Approved, no findings).
  Purely additive 4-line diff (0 deletions); tailnet.ip on all 4 machines with exact
  IPs; mesh/ssh/roles/detect untouched by construction. jq verify green (via WSL).
  1 harmless Minor (report LF-endings overclaim, non-actionable).
Task 2: complete (commit 1cf4eae, review clean — Spec ✅, Approved, no Critical/Important).
  ssh.nix HostName member branch params.hosts.${name} -> m.tailnet.ip; hub unchanged
  (params.endpoint); header comment updated; only ssh.nix touched; mesh-vpn-params.nix
  untouched; indentation matches. Reviewer ⚠️ (raw-IP vs MagicDNS content of tailnet.ip)
  resolved by controller from Task 1 (fields are raw 100.64.0.x). nix eval + alejandra
  DEFERRED to latitude5520. 1 cosmetic Minor (report line-num refs off).
Task 3: complete (commit 88ad2f2, review clean — Spec ✅, Approved). fleet-hosts.nix
  maps tailnet.ip(key)->[name](value) over params.machines; reuses mesh-vpn-params
  fromJSON (no new one, that file untouched); import added after mesh-vpn.nix in
  latitude config with correct path; deadnix-clean _: ; only 2 files changed.
  Reviewer Important/⚠️ (does machines.<name>.tailnet.ip exist? — it couldn't see
  fleet.json) resolved by controller: Task 1 added it to all 4 (jq-verified). The
  nix eval that would catch a missing field stays DEFERRED to latitude5520.
Task 4: complete (commit 9a1c062, review clean — Spec ✅, Approved, no Critical/Important).
  hosts.sh role_hosts: nixos no-op, wsl/debian write, unknown skip; ASCII markers exact;
  FLEET_HOSTS_FILE override; dry-run side-effect-free; apply idempotent (awk strip+trailing-
  blank-trim traced convergent by reviewer); no provision.sh edit. Smoke GREEN via WSL
  (parse/dry-run/idempotency; shellcheck deferred-absent). 2 brief-inherited Minors logged.
Task 5: complete (commit 2bba524, review clean — Spec ✅, Approved, no Critical/Important).
  hosts.ps1 Invoke-RoleHosts: nixos no-op / non-windows skip / windows write; markers
  byte-identical to hosts.sh (reviewer cross-checked); Get-FleetManifest consumed correctly;
  FLEET_HOSTS_FILE + default path; dry-run pure; apply idempotent (hand-traced convergent);
  $RoleExecutors gained exactly 'hosts', all 5 prior intact; only 2 files changed. BOM
  EF BB BF verified by controller (Format-Hex) AND reviewer (diff byte-scan @2002); ASCII-only
  body confirmed. Native pwsh smoke GREEN (dry-run/idempotency). Step 5 (full-dispatch
  confirm-gate) DEFERRED to Task 6. 2 brief-inherited Minors logged.
Task 6: complete (commit 2f9f6d7, review clean — Spec ✅, Approved, no findings). All 4
  roles arrays gained "hosts" as last element (4+/4-, single full-file hunk); no role
  removed/reordered; no other field touched; JSON valid. Controller ran the deferred
  Task 5 Step 5 full-dispatch confirm-gate (echo n | pwsh provision.ps1 -Apply -Machine
  g614jv): rc=0, hosts preview shows all 4 tailnet IPs between ASCII markers (success-stream
  body SURVIVES dispatch -> Task5 Minor(b) resolved non-issue), "n" skips cleanly. Order
  g614jv/homeserver/latitude5520/vps == sort_by parity for current names (Task5 Minor(a) moot).
ALL 6 TASKS COMPLETE. machines range a98e58f..2f9f6d7. Proceeding to final whole-branch review.
FINAL REVIEW (opus, a98e58f..2f9f6d7): Ready to merge = YES. No Critical, no Important.
  All Global Constraints met; single-source-of-truth preserved; ssh.nix mapAttrs correctness
  + hub laziness confirmed; executors mirror dotfiles pattern; markers byte-identical; BOM ok;
  idempotency/dry-run/confirm-gate empirically verified. 3 Minors, NONE requiring a code change:
  (1) hosts.ps1 Set-Content -Encoding ascii is the CORRECT cross-version tradeoff (BOM breaks a
  Windows hosts file; PS5.1 has no utf8NoBOM; real hosts files are ASCII) — worth a runbook note;
  (2) Sort-Object vs sort_by parity harmless for current names; (3) mktemp leak hypothetical
  (apply runs under disabled set -e via `if "$fn" apply`). Recommendations = 2 runbook watch-items:
  latitude self-hostname now resolves to tailnet .2 (blessed plan decision, verify getent after
  switch); ssh vps->cyphy.kz vs ping vps->tailnet quirk (already spec-documented).
  DEFERRED real-box (runbook): nix eval/flake check + switch on latitude5520; hosts apply on
  vps(root)/Windows(admin). NO fix wave needed. Proceeding to finishing-a-development-branch.
