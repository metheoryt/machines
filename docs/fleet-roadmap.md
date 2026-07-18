# Fleet Roadmap

Living backlog for the machine fleet. Curated — tick/prune as items land. A new
session inherits the fleet state from `.claude/memory/project.md`; this file is
the "where to head next" companion. For any item worth real work, run
`superpowers:brainstorming` → `writing-plans` and drop the plan under
`docs/superpowers/plans/`.

_Last updated: 2026-07-14_

## Where we are now

Fleet transport is **Headscale** (self-hosted Tailscale) end-to-end; AmneziaWG is
retained on the VPS **only for relatives**. Control plane at `https://cc.cyphy.kz`
+ embedded DERP.

| Node | Tailnet IP | State |
|---|---|---|
| vps-test | `100.64.0.1` | hub + embedded DERP; also runs the AWG relatives-hub (`10.0.0.1`) |
| latitude | `100.64.0.2` | tailnet-only (mesh removed from repo) |
| homeserver | `100.64.0.3` | services on tailnet; mesh removed from repo; VPS↔it direct @ ~5ms |
| g614jv | `100.64.0.4` | tailnet + Windows sshd; AWG tunnel runs locally (not repo-provisioned) |

Networking note: the fleet spans **two separate LANs**. Same-LAN pairs get direct
P2P (~3ms); cross-LAN pairs relay through our own DERP (expected and accepted —
this is why **UPnP/router port-mapping is NOT on the backlog**).

## Now — finish what the migration started

- [x] **Fleet-wide SSH-over-tailnet — CODE COMPLETE 2026-07-14** (branch
  `feat/ssh-over-tailnet`; spec+plan `docs/superpowers/{specs,plans}/2026-07-14-fleet-ssh-over-tailnet-and-hosts*`).
  Chose: add a parallel `fleet.json` `tailnet.ip` (kept `mesh.ip` for AWG), move the
  whole SSH story onto raw `100.64.0.x` (not MagicDNS), hub stays on `cyphy.kz`.
  `modules/home/ssh.nix` repointed. **Also added fleet-wide name resolution** (see
  below). **Real-box apply PENDING** (runbook in the plan): `nix flake check` +
  `nixos-rebuild switch` on latitude5520, then verify `ssh homeserver`.
- [x] **Fleet-wide name resolution (hosts file) — CODE COMPLETE 2026-07-14** (same
  branch). NixOS `modules/system/fleet-hosts.nix` generates `networking.hosts` from
  `fleet.json`; a new cross-platform `hosts` provisioner role (`provision/roles/hosts.{sh,ps1}`)
  writes a marker-delimited managed block into the system hosts file on Windows/Debian
  (no-op on NixOS). So `ping homeserver`/`curl homeserver:8001` resolve fleet-wide with
  no DNS resolver. **Real-box apply PENDING:** `hosts` role apply on vps (root) +
  g614jv/homeserver (admin pwsh).
- [x] **2026-07-17 — AWG mesh retired from the repo.** SSH re-homed onto the tailnet
  via `fleet.sshServer` (NixOS) + converged `windows.ps1` firewall. Deleted:
  `mesh-vpn.nix`, mesh params, `fleet.json` mesh blocks, provisioner mesh
  roles/libs. Kept: the AmneziaVPN client + the VPS AWG VPN server.
- [ ] **Restart immich + navidrome** on the homeserver — they were down during the
  cutover; confirm they serve over the tailnet like the rest. (Operational, quick.)
- [ ] **Drop g614jv's AWG.** It runs AWG beside Tailscale; its services already work
  over the tailnet. Remove once nothing depends on its `10.0.0.6` (then remove the
  `me-g614jv` peer on the VPS hub).

## Next — make it repeatable (provisioner)

- [ ] **Codify the `ssh-server` role executor.** Currently unimplemented. Windows:
  `dism.exe /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0`
  (NOT `Add-WindowsCapability` — it throws "Class not registered" under PS7),
  enable the firewall rule for all profiles, seed
  `C:\ProgramData\ssh\administrators_authorized_keys` for admin users, set the
  default shell. NixOS: `services.openssh`. (Gotchas captured in project memory.)
- [ ] **Declarative Windows Tailscale provisioning.** Fold `winget install
  Tailscale.Tailscale` + `tailscale up --login-server https://cc.cyphy.kz --authkey
  <key>` into the `ssh-server` role (or a dedicated tailscale role) so enrolling
  a box isn't manual. Mint a short-lived key per enrollment and expire it after
  (`headscale preauthkeys expire --id <n> --force`).
- [ ] **Zero-touch WSL tailnet enrollment (design approved 2026-07-16).** Extend
  `provision/tailscale-wsl.sh` (already shipped, currently env-key + manual) so a
  WSL distro re-enrolls hands-free. Note: the *fleet itself* is manual today —
  `services.tailscale.enable` on latitude, then a hand-pasted `tailscale up
  --authkey` after switch (`hosts/latitude/nixos/configuration.nix:89`) — so
  there's nothing more-automated to inherit; this builds the automation the fleet
  lacks (the NixOS `authKeyFile` pattern, hand-rolled). **Approved design:**
  (a) key source precedence `--authkey-file <path>` → `$HEADSCALE_AUTHKEY` → an
  already-persisted `/etc/headscale/authkey`; persist the resolved key to
  `/etc/headscale/authkey` `root:root 0600`; add `provision/secrets/` to
  `.gitignore` for a local stash. (b) install a systemd **system** oneshot
  `/etc/systemd/system/tailscale-autoconnect.service` — `After/Wants=tailscaled`,
  `ConditionPathExists=/etc/headscale/authkey`, `Type=oneshot RemainAfterExit=true`,
  `ExecStart=/bin/sh -c 'tailscale status --peers=false >/dev/null 2>&1 || tailscale
  up --login-server https://cc.cyphy.kz --authkey "$(cat /etc/headscale/authkey)"
  --hostname wsl-<distro>'`, `WantedBy=multi-user.target`; hostname baked at install
  (system units don't see `$WSL_DISTRO_NAME`). Runs as root → no interactive sudo at
  boot; idempotent (key consumed only on first enroll, state persists in
  `/var/lib/tailscale`). One-time `sudo` to install is the only interactive step.
  **Accepted tradeoff:** a reusable pre-auth key sits root-readable on disk;
  mitigation = use a key with an expiry and rotate in Headscale. Update
  spec/plan/README (`docs/superpowers/specs/2026-07-15-orca-serve-wsl-design.md`,
  `docs/superpowers/plans/2026-07-15-orca-serve-wsl.md`) to match. Straight to `main`.
- [ ] **Headscale ACLs.** The tailnet is default-open. Scope access (who can reach
  which node/port) before it widens — relatives never join this tailnet, but least
  privilege across our own boxes is cheap now.

## Later — reproducibility & backups (older parked)

- [ ] **VPS base-machine reproducibility.** Bring a fresh cloud VM to the VPS
  baseline reproducibly. Blocked on the `base` / `ssh-server` / `backup-client`
  role executors being unimplemented. Services stay the `vps` repo's `setup-*.sh`.
  (See project memory "VPS base-machine reproducibility".)
- [ ] **Truly-offsite backups.** Everything ultimately lands on the homeserver
  (its own immich backups + REST target) — one location loses primary + all
  backups. Fix is cheap: the dock drives are already removable → periodic manual
  rotation of one drive off-site. No new infra needed.
- [ ] **Back up latitude5520.** No dedicated backup today; only what home-manager
  declares is "backed up" (via git). User wants it in a private repo "someday" —
  mechanism not chosen (chezmoi/stow/plain git).

## Housekeeping

- [ ] **Drop `pylspFixOverlay` from `flake.nix`** once python-lsp/python-lsp-server
  PR #715 ships in a nixpkgs release. Tracking:
  https://github.com/python-lsp/python-lsp-server/pull/715

## Done (2026-07-13, this rollout)

- Headscale live on the VPS (0.29.2 + embedded DERP, `cc.cyphy.kz`).
- Probe passed; latitude cut over; homeserver cut over (Caddy → `100.64.0.3`,
  AWG spoke removed, no regression — direct path verified).
- g614jv enrolled + Windows sshd set up and reachable over the tailnet.
- vps convention docs updated to the tailnet reality; reusable pre-auth keys
  revoked. Plans/results under `docs/superpowers/`.
