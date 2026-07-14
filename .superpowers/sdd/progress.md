# Fleet rename Layer 1 (repo labels) — SDD Progress Ledger

(Prior SSH-over-tailnet ledger archived — that plan COMPLETE + merged. This is a new plan.)

Plan: docs/superpowers/plans/2026-07-15-fleet-rename-layer1-repo-labels.md
Spec: docs/superpowers/specs/2026-07-15-fleet-rename-and-magicdns-adoption-design.md
Branch: feat/fleet-rename-labels
BASE @ 196e477 (branch point from main; final-review MERGE_BASE).

ENVIRONMENT (this Windows box = homeserver / METHE-SERVER; controller box):
- jq + bash live in WSL, NOT on Git Bash PATH. Run ALL posix/jq gates via
  `wsl -e bash -lc 'cd /mnt/c/Users/methe/machines && ...'`.
- ALL `nix eval` / `nix flake check` steps DEFER to latitude (real-box gate).
  Implementers do the edits + record the exact eval command; controller marks
  the nix gate deferred and it becomes the PR's pre-merge gate.
- Layer 1 touches only fleet.json, flake.nix, justfile, and two git mv renames
  (hosts/ dir + agents/hosts/ memory file). No new *.sh/*.ps1 -> no BOM/eol work.

## Tasks
- [x] Task 1: rename fleet.json keys (hub/latitude/desktop/server)
- [x] Task 2: latitude full-label rename (flake attr/dir/host-memory/justfile decouple)
- [x] FINAL whole-branch review (opus) + fix wave
- [x] Task 3: push + open the Layer 1 PR

## DONE — Layer 1 code-complete + nix gate GREEN on latitude. PR #1: https://github.com/metheoryt/machines/pull/1
Branch feat/fleet-rename-labels (196e477..4859e34, 5 commits) pushed. `nix flake
check` PASSED on latitude 2026-07-15. NEEDED an extra fix (4859e34): deadnix
failed on modules/home/ssh.nix:25 `mkBlock = name: m:` — `name` went unused when
the SSH-over-tailnet work moved HostName to m.tailnet.ip, but THAT branch's flake
check was deferred to latitude and never run, so it only surfaced on this first
real flake check -> `name`->`_name`. Ready to MERGE + `just switch` on latitude.

## DONE — Layer 2 (VPS/Headscale) live 2026-07-15
gg.ez suffix deployed (surgical sed on /etc/headscale/config.yaml L329 + restart +
rollback guard; NOT cp — diff proved base_domain was the only live-vs-repo diff);
given-names renamed hub(1)/server(3)/desktop(4) (latitude(2) was already done).
Verified hub/server/desktop/latitude resolve FQDN+bare via gg.ez. Writes ran via
user `!` (auto-mode blocks prod SSH writes). Plan L2-3 doc:
docs/superpowers/plans/2026-07-15-fleet-rename-layer2-3-headscale-and-magicdns-cleanup.md

## IN PROGRESS — Layer 3 (MagicDNS cleanup). PR #1 MERGED (main@88e3bce), L2 live.
Branch feat/fleet-magicdns-cleanup, BASE 465bf74 (main after rebase: PR#1 merge +
4 doc commits). Plan: docs/superpowers/plans/2026-07-15-fleet-rename-layer2-3-*.md
ENV note (unchanged): nix eval/flake check DEFER to latitude; jq via WSL; auto-mode
blocks the elevated hosts-file write (Task 4 = user-run, like L2).
- [x] L3 Task 1: pin --accept-dns on latitude (default mechanism B = tailscale set oneshot)
- [x] L3 Task 2: retire hosts machinery (rm fleet-hosts.nix + hosts.sh/ps1; edit
      configuration.nix import, provision.ps1 $RoleExecutors, fleet.json roles x4)
- [x] L3 Task 3: slim ssh.nix (hub cyphy.kz alias + non-default users only)
- [ ] L3 Task 4: hand-delete # BEGIN/END fleet hosts block on THIS box (elevated, user) — separate real-box step
- [x] L3 Task 5: push + PR #2 https://github.com/metheoryt/machines/pull/2

### L3 Log
L3 Task 1: DONE (commit e2f9feb). systemd.services.tailscale-accept-dns oneshot
  (mechanism B, verbatim from brief) added after services.tailscale.enable; 14-line
  add, controller-verified placement/syntax (pkgs in scope). nix verify DEFERRED to
  latitude. MINOR (self-healing, for real-box gate): boot race — if tailscaled isn't
  authed when the oneshot fires it no-ops that boot (RemainAfterExit, no same-boot
  retry); benign because Tailscale PERSISTS the accept-dns pref across restarts once
  set (already ON live), so this only re-asserts declaratively.
L3 Task 2: DONE (commit 52b66d8). Deleted fleet-hosts.nix + hosts.sh + hosts.ps1
  (153 del); removed import from configuration.nix, hosts entry from provision.ps1
  $RoleExecutors, "hosts" from all 4 fleet.json roles arrays. Controller-verified
  completeness: 0 dangling refs (grep provision.ps1/configuration.nix clean; all 4
  roles arrays hosts-free). jq absent in this WSL distro -> implementer used python3
  equivalent (returned true). provision.sh needs no edit (generic role dispatch).
L3 Task 3: DONE (commit 5bf1670, subagent review clean — Spec ✅, Approved, no
  findings). mkBlock slimmed: hub->{HostName cyphy.kz + User debian}, server/desktop->
  {User methe} (no HostName), latitude->{} (default user me, no HostName). settings."*"
  + mapAttrs merge untouched; _name deadnix-safe; header comment updated. Reviewer
  independently re-derived all 4 renders + confirmed home.username="me" (me.nix:29).
  nix eval DEFERRED to latitude.
L3 FINAL REVIEW (opus, 465bf74..5bf1670): Ready to merge = YES, no Critical/Important.
  Deletions complete (0 dangling refs in live files; docs/memory hits excluded per plan);
  both provisioners correct with role gone (provision.sh generic dispatch + guard;
  provision.ps1 $RoleExecutors else-branch graceful); accept-dns oneshot sound for
  imperative join. Predicted nix-gate watch-item: possible statix useless_parens on
  ssh.nix:27 OUTER wrapper parens (inner if/else parens load-bearing). PRE-FIXED by
  controller in fc78d65 (dropped outer wrapper only; // left-assoc so identical).
  2 Minors: (1) accept-dns boot race — acceptable, NO hardening (would over-engineer);
  (2) stale project.md still calls fleet-hosts/hosts-role live -> refresh on finalize.
L3 Task 5: PR #2 opened https://github.com/metheoryt/machines/pull/2 (branch
  465bf74..fc78d65, 4 commits). Pre-merge gate = latitude nix flake check + just switch.
DONE (repo side). Remaining: user runs latitude gate + merges #2; Task 4 elevated
  hosts-block delete on server/METHE-SERVER (separate); refresh project.md memory.

## Minor findings (for final review triage)
(none yet)

## Log
Task 1: complete (commit 0c5feb3, review clean — Spec ✅, Approved, no Critical/Important).
  Pure 4-line key rename (4+/4-, fleet.json only); every nested field (mesh incl.
  peerName/ip, tailnet.ip, ssh.*, roles, detect.hostname) byte-identical, reviewer
  cross-checked via diff context. Implementer used PowerShell (not jq/WSL) for verify —
  same check, fine. Controller closed both reviewer ⚠️: branch feat/fleet-rename-labels
  confirmed (HEAD on it); Step 4 grep re-run by controller = clean (no literal old-key
  lookups in modules/).
Task 2: complete (commits 7a9c266 + fix 3064d7a, review clean — Spec ✅, Approved, no
  findings). Full-label rename latitude5520->latitude: flake.nix 4 attr sites,
  hosts/ dir git mv, agents/hosts memory-file git mv (100% similarity), specialArg
  ->latitude, justfile nixos_attr var + all 7 flake-attr refs (6 nixos-rebuild + iso).
  networking.hostName stays latitude5520 (reviewer confirmed unchanged, line 33). PLAN
  GAP the implementer caught: `just iso` recipe (justfile:281) referenced
  nixosConfigurations.{{hostname}} — fixed in 3064d7a to {{nixos_attr}} + ssh.nix:3
  comment example latitude5520->latitude. grep {{hostname}} justfile now empty. nix
  flake check DEFERRED to latitude (PR pre-merge gate). fleet-hosts.nix comment left
  (deleted in Layer 3).
FINAL REVIEW (opus, 196e477..3064d7a): Ready to merge = NO (1 Important) initially.
  Rename proven consistent + AWG-safe + OS identity intact. CAUGHT a whole-branch miss
  both the plan and per-task reviews missed: scripts/quick-check.sh (the `just quick`
  gate) hardcoded hosts/latitude5520/nixos paths (L21,22) + .#nixosConfigurations.
  latitude5520 dry-build attr (L57) -> `just quick` breaks. Fixed in e3c12f9 (+ 2 Minor
  comment fixes: justfile:335 --machine vps->hub; configuration.nix:83 hosts.latitude5520
  ->latitude). Controller re-verified repo-wide: only intended latitude5520 refs remain
  (detect.hostname, networking.hostName, nixos_attr comment, 2 deliberate comments).
  Predicted nix gate GREEN on latitude. Branch range 196e477..e3c12f9 (4 commits).
