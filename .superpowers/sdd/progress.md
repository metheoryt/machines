# Fleet SSH-over-tailnet + retire AWG mesh — SDD Progress Ledger

Plan: docs/superpowers/plans/2026-07-17-fleet-ssh-tailnet-retire-awg.md
Spec: docs/superpowers/specs/2026-07-17-fleet-ssh-tailnet-retire-awg-design.md
Branch: ssh-over-fleet (BIG work → branch; finishing skill merges to main).
BASE @ b1b7d20 (plan commit; final-review MERGE_BASE = b1b7d20).

ENVIRONMENT:
- shellcheck via `nix run nixpkgs#shellcheck -- <files>` (no system shellcheck).
- jq present. `just quick` (fast Nix syntax) + `nix flake check` (full eval) run in-session.
- USER-EXECUTED (needs elevation): latitude `just switch`; desktop+server `windows.ps1` as Admin; end-to-end `ssh` reachability.

## Tasks
- [x] Task 1: Rename trust file mesh-authorized-keys -> fleet-authorized-keys (+ refs)
- [x] Task 2: Add fleet.sshServer module; enable on latitude
- [x] Task 3: Delete mesh-vpn.nix; slim params -> fleet.nix; refactor ssh.nix
- [x] Task 4: Scrub AWG mesh from fleet.json
- [x] Task 5: Delete provisioner AWG mesh roles/libs + dispatch
- [x] Task 6: Converge windows.ps1 SSH firewall onto the tailnet
- [x] Task 7: Trim base.nix kernel comment; refresh docs/memory
- [ ] FINAL whole-branch review

## Minor findings (for final review triage)

## Log

Task 1: complete (commit 292628c, review clean — haiku impl+review, Spec ✅, Approved). Pure path/text rename; no logic. Implementer additionally updated provision/ssh-wsl.sh + provision/README.md (same trust file) to satisfy the no-lingering-ref grep — reviewer confirmed correct+complete. Note: implementer's `git add -A` (brief Step 6) swept the ledger into the feature commit; controller now commits the ledger separately each task to keep the tree clean before the next `git add -A` task.
Task 2: complete (commit 3f5869f, review clean — haiku impl / sonnet review, Spec ✅, Approved, 0 findings). ssh-server.nix byte-for-byte transcription of brief; keys-only (PasswordAuth+KbdInteractive false), openFirewall=false, port 22 scoped to tailscale0 + LAN 192.168.8.0/24 (extraCommands/extraStopCommands mirror), trust = provision/fleet-authorized-keys. latitude imports module + fleet.sshServer.enable=true. `nix flake check` 41 checks passed.
Task 3: complete (commit 99be048, review clean — sonnet impl / sonnet review, Spec ✅, Approved, 0 findings). Atomic: deleted mesh-vpn.nix, params→fleet.nix (git recorded as delete+add; slimmed to `inherit (fleet) machines;`), ssh.nix imports fleet.nix + hub HostName keyed off `(m.ssh.host or null)`. Hub-HostName equivalence VERIFIED against fleet.json (only hub.ssh.host == "cyphy.kz"; latitude/desktop/server have no ssh.host). AmneziaVPN client + ssh-server.nix import + fleet.sshServer.enable untouched. `nix flake check` passed. Controller re-verified current fleet.json keys = latitude/desktop/server/hub (matches Task 4 rewrite → no host-alias change). Concern (self-resolving): stale comment provision/roles/mesh-member.sh:4 — that file is deleted in Task 5.
Task 4: complete (commit f6a796f, review clean — haiku impl / haiku review, Spec ✅, Approved, 0 findings). fleet.json: removed all mesh blocks + mesh-member/mesh-hub roles; jq assertion true; 4 machines intact (hub only ssh.host=cyphy.kz; latitude no ssh; desktop/server ssh.user=methe). Only fleet.json changed. `nix flake check` passed.
Task 5: complete (commit 1ce09bf, review clean — haiku impl / haiku review, Spec ✅, Approved, 0 findings). Deleted 7 provisioner mesh files (lib/mesh.sh, lib/Mesh.psm1, lib/mesh.test.sh, roles/mesh-member.{sh,ps1}, roles/mesh-hub.{sh,ps1}); removed mesh-member/mesh-hub from provision.ps1 $RoleExecutors map (reviewer confirmed map still valid PowerShell, ends after repos entry) + comment tweak. grep for Invoke-RoleMesh/Mesh.psm1/lib/mesh.sh/roles/mesh- clean. shellcheck clean, bash -n exit 0. Also removed the stale mesh-member.sh:4 comment flagged in Task 3 (file gone). 8 files changed, 455 deletions.
Task 6: complete (commit 95aa868, review clean — haiku impl / haiku review, Spec ✅, Approved, 0 findings). windows.ps1 step 7: header→tailnet+LAN; 7e firewall CONVERGES (foreach removes OpenSSH-Server-Mesh-LAN + new name, then New-NetFirewallRule OpenSSH-Server-Tailnet-LAN -RemoteAddress @('100.64.0.0/10','192.168.8.0/24'); disables default OpenSSH-Server-In-TCP Any rule); Warn→tailnet. Reviewer confirmed converge logic safe/idiomatic + PowerShell well-formed. No 10.0.0.0/24 or AmneziaWG-tunnel wording; only Mesh-LAN mention is in the removal loop. winget AmneziaVPN/WG untouched. Only windows.ps1 changed. (Runtime-verified by user on Windows.)
Task 7: complete (commit 8952af9, review clean — haiku impl / haiku review, Spec ✅, Approved, 0 findings). Docs only: base.nix kernel comment trimmed (kernelPackages=pkgs.linuxPackages UNCHANGED, NVIDIA/LTS reason kept, AWG sentence gone); fleet-roadmap.md dated retirement bullet + per-host table notes ("mesh removed from repo"; g614jv AWG runs locally/not repo-provisioned); project.md retirement bullet. Reviewer confirmed accuracy: retired=mesh only; KEPT=AmneziaVPN client + VPS AWG server (not misstated); SSH re-homed not removed. Only 3 files changed. `just quick` passed.
