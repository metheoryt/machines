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

## DONE — Layer 1 code-complete. PR #1 open: https://github.com/metheoryt/machines/pull/1
Branch feat/fleet-rename-labels (196e477..e3c12f9, 4 commits) pushed. Pre-merge
gate = real-box nix on latitude (nix flake check + build .#nixosConfigurations.
latitude + just quick).

## DONE — Layer 2 (VPS/Headscale) live 2026-07-15
gg.ez suffix deployed (surgical sed on /etc/headscale/config.yaml L329 + restart +
rollback guard; NOT cp — diff proved base_domain was the only live-vs-repo diff);
given-names renamed hub(1)/server(3)/desktop(4) (latitude(2) was already done).
Verified hub/server/desktop/latitude resolve FQDN+bare via gg.ez. Writes ran via
user `!` (auto-mode blocks prod SSH writes). Plan L2-3 doc:
docs/superpowers/plans/2026-07-15-fleet-rename-layer2-3-headscale-and-magicdns-cleanup.md

## PENDING — Layer 3 (MagicDNS cleanup), gated on PR #1 MERGED (L2 already live)
pin --accept-dns on latitude; retire fleet-hosts.nix + hosts role; slim ssh.nix;
hand-delete the # BEGIN/END fleet hosts block on this box's real hosts file.

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
