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
- [ ] Task 1: Rename trust file mesh-authorized-keys -> fleet-authorized-keys (+ refs)
- [ ] Task 2: Add fleet.sshServer module; enable on latitude
- [ ] Task 3: Delete mesh-vpn.nix; slim params -> fleet.nix; refactor ssh.nix
- [ ] Task 4: Scrub AWG mesh from fleet.json
- [ ] Task 5: Delete provisioner AWG mesh roles/libs + dispatch
- [ ] Task 6: Converge windows.ps1 SSH firewall onto the tailnet
- [ ] Task 7: Trim base.nix kernel comment; refresh docs/memory
- [ ] FINAL whole-branch review

## Minor findings (for final review triage)

## Log
