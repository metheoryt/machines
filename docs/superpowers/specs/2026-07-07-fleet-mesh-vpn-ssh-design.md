# Fleet AmneziaWG mesh + SSH access (for agents and humans) — design

**Date:** 2026-07-07
**Status:** approved (design), pending implementation plan
**Scope:** two repos — `machines` (this repo, owns the NixOS/Windows machine
config) and `~/my/vps` (owns the VPS-side AmneziaWG hub + RustDesk server).
Each repo's changes are additive to its existing scripts/modules — no
architecture replacement.

## Goal

Give **agents** (Claude Code sessions running on any fleet machine) and
humans the ability to `ssh <hostname>` into any other fleet machine and run
commands, whether or not the machines share a physical LAN — primarily so a
laptop away from home can still reach/manage the homeserver (and the other
laptop), and so an agent working on one box isn't blocked from inspecting or
acting on another (as happened in this session: this agent, running on
latitude5520, had no path to g16 or the VPS).

## Current state (verified this session)

- VPS runs **AmneziaWG** (not plain WireGuard) — `vps/vps/setup-awg.sh`. Hub
  at `10.0.0.1/24`.
- Homeserver (`10.0.0.2`) is a static peer baked into `setup-awg.sh` at
  initial setup.
- `vps/vps/manage-peers.sh` already supports adding arbitrary roaming peers
  (auto-picks next IP, generates keys into gitignored `vps/vps/peers/`) — this
  mechanism is already in occasional use: g16 is already a peer at `10.0.0.6`,
  added ad-hoc (not committed anywhere, not in either repo).
- `vps/vps/awg.env` (VPS pubkey, port, the `Jc/Jmin/Jmax/S1/S2/H1-4`
  obfuscation params, VPS public IP) is `.gitignore`d and has never been
  committed — this data exists nowhere in git today, and isn't present on
  this machine either (checked). Filling in real values is a manual
  post-implementation step (see Follow-ups).
- No SSH server is declared anywhere in this repo (`services.openssh.enable`
  doesn't appear once) — g16's currently-working SSH access was set up
  imperatively on g16 itself, outside git.
- `avahi`/mDNS is already fully enabled fleet-wide (`modules/system/base.nix`:
  `enable = true; nssmdns4 = true; openFirewall = true;`) — LAN-local
  `*.local` discovery already works today with zero new work. mDNS does not
  cross the WireGuard tunnel, so it doesn't help while roaming.
- No secrets-management framework (sops-nix/agenix) in this repo — existing
  convention is to keep secrets out of git entirely (gitignored files or
  fixed out-of-store paths provisioned manually once), not to encrypt them
  in-repo. This design follows that convention rather than introducing one.

## Decisions taken (brainstorm)

1. **Extend the existing AmneziaWG hub, don't replace it** (e.g. with
   Tailscale/Headscale) — the user explicitly wants AmneziaWG, which is
   already chosen for DPI resistance; a mesh-VPN swap is out of scope.
2. **Split tunnel** (`AllowedIPs = 10.0.0.0/24` on clients) — laptops join
   the mesh only to reach other fleet members; general internet traffic
   never routes through the VPS. This also means LAN reachability
   (`192.168.8.x`) is completely unaffected by the VPN being up or down —
   different subnet, no interaction.
3. **Full mesh, not hub-only** — any peer can reach any other peer (not just
   "laptop → homeserver"), via one VPS-side iptables hairpin rule.
4. **`manage-peers.sh add` becomes interactive** — prompts for peer name and
   mesh IP (suggesting the next free one as the default), instead of only
   auto-assigning.
5. **Discovery = two complementary, already-cheap mechanisms, no new
   infrastructure:**
   - LAN: existing avahi/mDNS (`*.local`) — verify `publish.addresses` is on.
   - Mesh-wide / roaming: Home-Manager-declared `programs.ssh.matchBlocks`
     (not `networking.extraHosts`) — because the real requirement surfaced
     was **agent automation**, not just name resolution: an agent's
     non-interactive `ssh g16 <cmd>` must never hit a host-key prompt or need
     `-l user`. `matchBlocks` fixes `HostName`, `User`, and
     `StrictHostKeyChecking = accept-new` (TOFU-then-pin — safe on a private,
     self-controlled mesh) in one place.
   - No router changes, no mDNS reflector, no self-hosted DNS server — all
     rejected as infrastructure this 3-4-machine fleet doesn't need yet.
6. **RustDesk is already essentially done** — self-hosted server + peer
   seeding for g16/homeserver already exist in
   `modules/home/rustdesk-config.nix`. The only gap is latitude5520's
   RustDesk peer ID, which is unknowable until RustDesk has actually run
   there once — deferred as a trivial follow-up, not built speculatively now.
7. **Endpoint by domain, not IP** — client/peer configs use `cyphy.kz:<port>`
   instead of a raw `VPS_PUBLIC_IP`, so a VPS IP change needs one DNS update,
   not regenerating every peer.
8. **AWG public constants committed in `machines`, not shared cross-repo** —
   VPS pubkey, port, and the obfuscation params aren't secret, just need to
   match exactly. Since `machines` is the consumer (Nix eval needs them),
   they're committed there once, with a comment pointing back at
   `vps/vps/awg.env` as the value's origin. No shared file between repos, no
   impure cross-repo path reads (would break eval portability and the
   "machine here, services there" boundary).
9. **No new secrets framework** — private keys stay out-of-git at a fixed
   path (matches the VPS's own `peers/*.key` convention), provisioned
   manually once per host.

## Architecture

```
                         ┌─────────────┐
                         │     VPS     │  10.0.0.1  (hub, cyphy.kz)
                         │  wg0 (awg)  │
                         └──────┬──────┘
             hairpin FORWARD    │   (new: wg0 → wg0 accept)
        ┌───────────────────────┼───────────────────────┐
        │                       │                        │
   10.0.0.2                10.0.0.6                 10.0.0.<n>
  homeserver (Win)            g16                  latitude5520
  sshd (new)              sshd (codify existing)   sshd (new, this session)
```

Each spoke's client config: `AllowedIPs = 10.0.0.0/24` (split tunnel) +
`Endpoint = cyphy.kz:<port>`. sshd on every spoke is firewalled to the mesh
interface only — never reachable from the public/LAN interface directly.

## Components

### 1. VPS (`~/my/vps` repo)

- `vps/vps/setup-awg.sh`: add one `PostUp`/`PreDown` pair to `wg0.dist.conf`
  enabling peer↔peer hairpin routing:
  ```
  PostUp = iptables -A FORWARD -i wg0 -o wg0 -j ACCEPT
  PreDown = iptables -D FORWARD -i wg0 -o wg0 -j ACCEPT
  ```
- `vps/vps/manage-peers.sh` `cmd_add`:
  - Prompt for `name` if not passed as `$1`.
  - Compute the next-free IP as today, then prompt `IP [<suggested>]:` —
    Enter accepts the suggestion; a typed IP overrides it (validate it's
    unused and in `10.0.0.0/24`).
  - Client-config template: `AllowedIPs = 0.0.0.0/0` → `10.0.0.0/24`; drop
    the `DNS = 1.1.1.1` line (meaningless on a split tunnel); `Endpoint` uses
    `cyphy.kz` instead of `$VPS_PUBLIC_IP`.
- g16 and homeserver's existing peer entries are untouched.

### 2. `modules/system/mesh-vpn-params.nix` (new, `machines` repo)

Committed, non-secret constants (VPS pubkey, AWG port, `Jc/Jmin/Jmax/S1/S2/
H1-4`, endpoint domain) plus the shared host→mesh-IP map used by both the
wireguard peer block and `matchBlocks`. Values start as placeholders — see
Follow-ups; comment references `vps/vps/awg.env` as the source of truth.

### 3. `modules/system/mesh-vpn.nix` (new, `machines` repo)

Options: `fleet.meshVpn.enable`, `.address` (per-host, e.g. `"10.0.0.7/32"`),
`.privateKeyFile` (defaults to an out-of-store path like
`/etc/amnezia-wg/awg0.key`, provisioned manually once — never in git).
Declares `networking.wireguard.interfaces.awg0` with `type = "amneziawg"`,
the shared obfuscation params from `mesh-vpn-params.nix`, and one `[Peer]`
block for the VPS. Imported by both `hosts/g16/nixos/configuration.nix` and
`hosts/latitude5520/nixos/configuration.nix`, each setting its own
`address`.

### 4. SSH (both NixOS hosts)

- `services.openssh.enable = true;` with `openFirewall = false;` +
  `networking.firewall.interfaces.awg0.allowedTCPPorts = [ 22 ];` — sshd
  reachable only over the mesh.
- `users.users.me.openssh.authorizedKeys.keys` — existing
  `~/.ssh/id_ed25519.pub` added declaratively (same key already used).
- `modules/home/me.nix`: `programs.ssh.matchBlocks` for `g16`,
  `latitude5520`, `homeserver` (hostnames from `mesh-vpn-params.nix`, correct
  `User` per host, `StrictHostKeyChecking = accept-new`).

### 5. Windows homeserver (manual/documented — not Nix-managed)

Written up in `hosts/homeserver/README.md` (mirroring the g16 Windows runbook
style):
1. `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`; enable
   and start `sshd`.
2. Add `id_ed25519.pub` to `C:\ProgramData\ssh\administrators_authorized_keys`
   with the ACL fix OpenSSH requires (admins/SYSTEM only).
3. Set default shell to PowerShell (`HKLM:\SOFTWARE\OpenSSH\DefaultShell`) so
   agent commands land somewhere scriptable, not `cmd.exe`.
4. Windows Firewall inbound rule for port 22 scoped to remote address
   `10.0.0.0/24` only.
5. Homeserver's AWG peer already exists (`10.0.0.2`) — no new VPN client
   needed there.

### 6. RustDesk — no code change now

Already functionally complete (server + peer seeding). Follow-up only: once
latitude5520 has run RustDesk once and has an ID, add it to the `peers` attr
in `modules/home/rustdesk-config.nix` (same shape as the existing entries).

## Explicitly out of scope

- Replacing AmneziaWG with Tailscale/Headscale or any other mesh VPN.
- Full-tunnel (route-everything) client configs.
- A self-hosted DNS server, mDNS reflector, or router-level DNS/static
  leases for discovery.
- sops-nix/agenix or any secrets-encryption-in-git framework.
- Regenerating g16's or homeserver's already-working peer configs.
- Automating the Windows homeserver steps with a script (kept as documented
  manual steps, consistent with how homeserver's OS reinstall runbook is
  already deferred/manual).

## Follow-ups (need user action outside this session)

1. **Fill in real values in `mesh-vpn-params.nix`** — this session has no
   VPS SSH access and no local copy of `awg.env`; the module ships with
   clearly marked placeholders for VPS pubkey/port/obfuscation params until
   the user copies them from the VPS.
2. **Run `manage-peers.sh add latitude5520` on the VPS** to get its real
   mesh IP + private key; update `mesh-vpn-params.nix` and latitude5520's
   `mesh-vpn.nix` `address` to match, and place the private key at the
   configured path.
3. **Apply the codified config to g16** (reusing its already-generated key,
   not regenerating) next time it's reachable/on-site.
4. **Windows homeserver manual steps** (§5 above) — needs hands-on access.
5. **latitude5520's RustDesk peer entry** — once it has a RustDesk ID.

## Verification

- `just quick` / `nix flake check` pass after the new modules are wired in.
- On latitude5520 (this machine, once keys/IP are filled in): `awg show
  awg0` shows a handshake with the VPS; `ssh g16` / `ssh homeserver` connect
  without a host-key prompt and land as the right user.
- From g16 (once codified): `ssh latitude5520` works the same way, proving
  the hairpin rule enables peer↔peer, not just peer↔hub.
- `ssh homeserver` reaches a PowerShell prompt, not `cmd.exe`.
- Turning the VPN off doesn't break `ssh <name>.local`-style LAN access
  (mDNS) or `192.168.8.x` reachability — confirms split-tunnel didn't
  entangle LAN and mesh routing.

## Decisions log

1. Extend existing AmneziaWG hub-and-spoke; no mesh-VPN replacement.
2. Split tunnel (`10.0.0.0/24` only) on all client configs.
3. Full mesh via one VPS iptables hairpin rule, not hub-only.
4. `manage-peers.sh add` becomes interactive (name + IP, suggested default).
5. Discovery: existing avahi/mDNS for LAN (already done) + Home-Manager
   `programs.ssh.matchBlocks` (not `extraHosts`) for the mesh, chosen because
   the real requirement is non-interactive agent SSH, not just name
   resolution. No router, no DNS server, no mDNS reflector.
6. RustDesk needs no new code; latitude5520 peer ID is a deferred follow-up.
7. Endpoint by domain (`cyphy.kz`) instead of raw VPS IP.
8. AWG public constants (non-secret) committed once in `machines`
   (`mesh-vpn-params.nix`), sourced from `vps/vps/awg.env` manually — not
   shared cross-repo via any file or mechanism.
9. No secrets framework introduced; private keys stay out-of-git at a fixed
   provisioned path, matching the VPS's own convention.
