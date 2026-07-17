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
- [ ] Task 3: Delete mesh-vpn.nix; slim params -> fleet.nix; refactor ssh.nix
- [ ] Task 4: Scrub AWG mesh from fleet.json
- [ ] Task 5: Delete provisioner AWG mesh roles/libs + dispatch
- [ ] Task 6: Converge windows.ps1 SSH firewall onto the tailnet
- [ ] Task 7: Trim base.nix kernel comment; refresh docs/memory
- [ ] FINAL whole-branch review

## Minor findings (for final review triage)

## Log

Task 1: complete (commit 292628c, review clean — haiku impl+review, Spec ✅, Approved). Pure path/text rename; no logic. Implementer additionally updated provision/ssh-wsl.sh + provision/README.md (same trust file) to satisfy the no-lingering-ref grep — reviewer confirmed correct+complete. Note: implementer's `git add -A` (brief Step 6) swept the ledger into the feature commit; controller now commits the ledger separately each task to keep the tree clean before the next `git add -A` task.
Task 2: complete (commit 3f5869f, review clean — haiku impl / sonnet review, Spec ✅, Approved, 0 findings). ssh-server.nix byte-for-byte transcription of brief; keys-only (PasswordAuth+KbdInteractive false), openFirewall=false, port 22 scoped to tailscale0 + LAN 192.168.8.0/24 (extraCommands/extraStopCommands mirror), trust = provision/fleet-authorized-keys. latitude imports module + fleet.sshServer.enable=true. `nix flake check` 41 checks passed.
