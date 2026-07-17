# Design: SSH-server role on the tailnet + retire the AWG mesh

Date: 2026-07-17
Status: approved, ready for implementation planning
Supersedes (in effect): the AWG-mesh SSH-server wiring from
`2026-07-07-fleet-mesh-vpn-ssh-design.md` for our own machines.

## Problem

The AmneziaWG (AWG) → Headscale migration moved the fleet's **transport** to the
Headscale tailnet (`100.64.0.0/10` / `tailscale0`) but left the **SSH-server
role** — sshd enablement, the port-22 firewall scope, and the key trust —
pinned to the retired AWG mesh (`10.0.0.0/24` / `awg0`). So SSH-over-the-tailnet
does not work fleet-wide:

- **latitude (NixOS):** `fleet.meshVpn.enable = false` gates the ENTIRE
  `mesh-vpn.nix` config block, which also holds `services.openssh.enable`, the
  firewall rules, and `authorizedKeys.keyFiles`. Result: no sshd at all, and the
  trust file is not loaded.
- **desktop / server (Windows):** `windows.ps1` scopes port 22 to
  `10.0.0.0/24` (AWG) + LAN and disables the default Any rule, so tailnet peers
  (`100.64.0.0/10`) are blocked.

At the same time the AWG *mesh* is now legacy for our own machines (AWG survives
only as the obfuscated VPN **server** on the VPS for RU relatives/friends). So we
also retire the AWG mesh from this repo rather than leave it as dormant weight.

## Goals

1. Keys-only sshd reachable over the tailnet on every fleet member (NixOS +
   Windows), decoupled from the retired AWG mesh.
2. Remove the AWG *mesh* from this repo entirely (module, params, `fleet.json`
   blocks, provisioner roles, trust-file naming).
3. No regression to existing LAN SSH access.

## Non-goals / explicitly kept

- **Keep** the AmneziaVPN *client* app: latitude's `me.nix` wrapper + the
  `AmneziaVPN.service`, and the Windows `winget` AmneziaVPN/AmneziaWG entries.
  Only the fleet **mesh** (awg0 spoke, peers, `10.0.0.0/24`) is retired; dialing
  the VPS VPN as a client still works.
- **Keep** the VPS-side AWG VPN server (owned by the sibling `~/my/vps` repo) —
  untouched by this repo.
- **Keep** the `base.nix` LTS kernel pin. It has a second, still-valid reason
  (NVIDIA driver safety for g16); only the AWG sentence in its comment is
  removed. No kernel flip.
- **Keep** the posture: keys-only (`PasswordAuthentication no`), a single
  committed public-keys trust file, no public-interface exposure.

## Fleet constants the design must respect

- Control server `https://cc.cyphy.kz` (Headscale v0.29.2, embedded DERP region
  999). MagicDNS suffix **`gg.ez`**. Tailnet CGNAT **`100.64.0.0/10`**, interface
  `tailscale0`.
- Fleet tailnet IPs: hub `100.64.0.1`, latitude `100.64.0.2`, server
  `100.64.0.3`, desktop `100.64.0.4`, WSL leaf `100.64.0.6`.
- `fleet.json` is the source of truth for machine records. Members:
  latitude / desktop / server / hub. The WSL box is a leaf, deliberately NOT in
  `fleet.json`.
- The single committed trust file (public keys only) is consumed by NixOS
  (`authorizedKeys.keyFiles`) and Windows (`windows.ps1` →
  `administrators_authorized_keys`). It now contains the WSL leaf key
  `me@wsl-desktop`.

## Design

### A. New SSH-server role (NixOS)

**New module `modules/system/ssh-server.nix`**, option `fleet.sshServer`, owning
the whole SSH-server role under `lib.mkIf cfg.enable`:

- `services.openssh`: `enable = true`, `openFirewall = false`,
  `settings.PasswordAuthentication = false`,
  `settings.KbdInteractiveAuthentication = false`.
- **Firewall — tailnet:** `networking.firewall.interfaces.tailscale0.allowedTCPPorts = [22]`.
  Rationale (decided): interface-based is tighter than a source-CIDR — it binds
  22 to the actual tailnet interface, and Tailscale crypto + Headscale ACLs are
  the source auth; the host firewall just scopes the port. The "tailscale0 not up
  yet" worry is a non-issue: iptables accepts a rule referencing a
  not-yet-existent interface and matches `-i tailscale0` at packet time (direct
  in-repo precedent: the retired module did exactly this with
  `interfaces.awg0.allowedTCPPorts = [22]`, awg0 also being a dynamic tunnel
  iface).
- **Firewall — LAN:** the `192.168.8.0/24` iptables rule moved verbatim from
  `mesh-vpn.nix` (`extraCommands` add + `extraStopCommands` delete on the
  `nixos-fw` chain — the escape hatch avoids the nftables backend flip that could
  disrupt Docker).
- **Trust:** `users.users.me.openssh.authorizedKeys.keyFiles = [ ../../provision/fleet-authorized-keys ]`.
- Carry over the host-key-pinning follow-up comment (`programs.ssh.knownHosts`,
  not yet collected; clients fall through to `StrictHostKeyChecking=accept-new`).

**`hosts/latitude/nixos/configuration.nix`:** add
`../../../modules/system/ssh-server.nix` to `imports`; add
`fleet.sshServer.enable = true;`. Remove the `fleet.meshVpn` block (see B).
latitude is the **sole NixOS importer today**; the module is written to be reused
by a future NixOS g16 — no g16 NixOS config is fabricated here.

### B. Retire the AWG mesh

- **Delete** `modules/system/mesh-vpn.nix` entirely (the `fleet.meshVpn` option
  + awg0 spoke + the SSH bits, now owned by `ssh-server.nix`).
- **Rename** `modules/system/mesh-vpn-params.nix` → `modules/system/fleet.nix`,
  stripped to just the fleet machine records read from `fleet.json`
  (`inherit (fleet) machines;`). Drop `vpsPublicKey`, `port`, `endpoint`,
  `obfuscation`, and the derived `hosts` mesh-IP map.
- **`modules/home/ssh.nix`:** change the import to `../system/fleet.nix`, and key
  the hub's `HostName` off `ssh.host` presence instead of `mesh.role`:

  ```nix
  # was: if m.mesh.role == "hub" then { HostName = params.endpoint; } else {}
  # now:
  (if (m.ssh.host or null) != null then { HostName = m.ssh.host; } else {})
  ```

  Behavior is identical: in `fleet.json` only the hub carries `ssh.host`
  (`cyphy.kz`), so the hub still gets `HostName cyphy.kz` and all other members
  resolve by bare MagicDNS name. This removes the last `mesh.*` dependency in the
  Nix tree.
- **`fleet.json`:** remove each machine's `mesh` object and the `mesh-member` /
  `mesh-hub` strings from every `roles` array. Keep `tailnet`, `ssh`, `roles`
  (minus mesh), `detect`.
- **Delete the provisioner AWG pieces:** `provision/lib/mesh.sh`,
  `provision/lib/Mesh.psm1`, `provision/lib/mesh.test.sh`,
  `provision/roles/mesh-member.sh`, `provision/roles/mesh-member.ps1`,
  `provision/roles/mesh-hub.sh`, `provision/roles/mesh-hub.ps1`, and the
  `mesh-member` / `mesh-hub` dispatch entries in `provision/provision.ps1`.
  (`provision/provision.sh` auto-sources `roles/*.sh`, so removing the files is
  enough on the posix side.)
- **Rename** `provision/mesh-authorized-keys` → `provision/fleet-authorized-keys`
  (`git mv`), and update all references: `.gitignore` allow-line,
  `modules/system/ssh-server.nix`, `provision/windows.ps1`. Legacy "mesh" naming
  is retired.
- **`modules/system/base.nix`:** delete the AWG sentence from the
  `kernelPackages` comment; keep the LTS pin (NVIDIA reason stands).
- **Docs / memory:** update `docs/fleet-roadmap.md` and
  `.claude/memory/project.md` to record that the AWG mesh is retired from the
  repo (mesh module/params/roles gone; AmneziaVPN client + VPS VPN server kept).

### C. Windows (`provision/windows.ps1`, step 7)

- **Firewall converges** (fixes the create-if-absent bug that would silently skip
  re-scoping on `desktop`, which already carries the old rule from this
  session): remove any prior rule — old `OpenSSH-Server-Mesh-LAN` **and** the new
  name — then recreate as `OpenSSH-Server-Tailnet-LAN` with
  `RemoteAddress = @('100.64.0.0/10','192.168.8.0/24')` (AWG `10.0.0.0/24`
  dropped). Keep disabling the default `OpenSSH-Server-In-TCP` (Any) rule.
- **Keys:** point `$srcKeys` at `provision\fleet-authorized-keys`.
- **Comments/warnings:** update the step-7 header ("over tailnet+LAN") and the
  trailing AmneziaWG/`10.0.0.0/24` warning to reference the tailnet.
- **Keep** the winget AmneziaVPN/AmneziaWG entries (client app) untouched.

## Risks / verification points for the plan

- `provision/lib/fleet.sh` + `provision/lib/Fleet.psm1` (the general fleet libs,
  distinct from the mesh libs) must not hard-require a `mesh` block after it is
  removed from `fleet.json`. Verify before/while editing `fleet.json`.
- Confirm nothing else in the Nix tree reads `params.hosts` / `params.endpoint` /
  `params.obfuscation` after the rename (grep shows only `mesh-vpn.nix`, which is
  deleted, and `ssh.nix`, which is refactored).
- `.gitignore` is allow-only; the renamed `fleet-authorized-keys` needs its own
  `!` allow-line or it becomes untracked.

## Definition of done (user-executed — not self-verifiable)

The Bash tool runs on latitude and cannot `sudo nixos-rebuild` non-interactively;
Windows changes need Administrator. So the user runs:

1. `nix flake check` passes (can be run in-session, no sudo).
2. `just switch` on latitude.
3. Re-run `provision\windows.ps1` elevated on **desktop** and **server**.
4. From the WSL box / any tailnet node:
   - `ssh -o BatchMode=yes latitude true` → succeeds
   - `ssh -o BatchMode=yes desktop true` → succeeds
   - `ssh -o BatchMode=yes server true` → succeeds
5. No regression to existing LAN / other SSH access.
