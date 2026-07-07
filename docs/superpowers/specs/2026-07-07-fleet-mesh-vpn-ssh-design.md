# Fleet AmneziaWG mesh + SSH access (for agents and humans) — design

**Date:** 2026-07-07
**Status:** approved (design), revised after senior review (2026-07-07 —
folded in keepalive, existing-peer preconditions, dual-path LAN+mesh sshd,
host-key pinning, and VPS/first-switch ordering), pending implementation plan
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
interface *and* the LAN interface (never the public interface) — see §4 for
why the LAN interface is included.

## Preconditions on the *existing* peers (verify, don't assume)

The design declares "don't regenerate g16's/homeserver's already-working peer
configs" out of scope — but the full-mesh + roaming-to-homeserver goals
depend on two properties of those *existing, ad-hoc-generated* configs that
were never checked. These are **preconditions to verify**, and to fix in
place if they're wrong (which is *not* a full regeneration):

1. **Each existing spoke's client-side `AllowedIPs` must cover
   `10.0.0.0/24`.** The VPS hairpin rule (§1) is necessary but not
   sufficient: for a roaming laptop to reach the homeserver, the
   *homeserver's own* config (the `[Peer]` on the Windows box pointing at the
   VPS) must route the whole `/24`, not just the hub or its own `/32`. Same
   for g16. An ad-hoc peer added with `0.0.0.0/0` already satisfies this
   (superset); one added with a narrow value silently breaks peer↔peer. If
   narrow, widen that one line to `10.0.0.0/24` — no key regeneration needed.
2. **The homeserver's AWG tunnel must be persistently up (autostart on
   boot), not a hand-toggled GUI connection.** "A `[Peer]` for the homeserver
   exists on the VPS" is *not* the same as "the tunnel is up on the Windows
   box." `ssh homeserver` only works while that tunnel is connected; for an
   always-reachable target it must come up on boot and stay up (pairs with
   the `persistentKeepalive` requirement in §3). Verify it runs as a service,
   not via the AmneziaVPN GUI clicked by hand.

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

Options: `fleet.meshVpn.enable`, `.address` (per-host, e.g.
`"10.0.0.<n>/32"` — a placeholder; the real IP comes from `manage-peers.sh`,
Follow-up #2), `.privateKeyFile` (defaults to an out-of-store path like
`/etc/amnezia-wg/awg0.key`, provisioned manually once — never in git).
Declares `networking.wireguard.interfaces.awg0` with `type = "amneziawg"`,
the shared obfuscation params from `mesh-vpn-params.nix`, and one `[Peer]`
block for the VPS. Imported by both `hosts/g16/nixos/configuration.nix` and
`hosts/latitude5520/nixos/configuration.nix`, each setting its own
`address`.

- **The VPS `[Peer]` block MUST set `persistentKeepalive = 25`.** These hosts
  sit behind home/coffee-shop NAT. Peer↔peer traffic is forwarded by the VPS
  *into* each spoke's tunnel, which only works while that spoke's
  NAT mapping toward the VPS is alive. Without a keepalive, a spoke that
  hasn't sent traffic recently becomes unreachable for *inbound* (forwarded)
  connections even though `awg show` still lists it — the classic
  WireGuard-mesh footgun. 25 s is the standard value. This is non-optional
  for any host that must be an SSH *target* while idle (the homeserver above
  all, but also either laptop when the other wants to reach it).
- **`AllowedIPs = 10.0.0.0/24` on this VPS `[Peer]`** (not `/32`): the spoke
  must route the *whole* mesh through the tunnel, or it can reach the hub but
  not other spokes. With `allowedIPsAsRoutes` (default `true`) NixOS installs
  the `10.0.0.0/24` route from this automatically; the `/32` on `.address`
  only sets the interface's own address, it does not gate reachability.
- Interface is named `awg0` on spokes vs `wg0` on the VPS — deliberate, they
  are independent interfaces; a code comment should say so, so nobody
  "corrects" the mismatch.

### 4. SSH — trust via one committed keys file, not one shared key

Each fleet machine has its **own** SSH keypair (verified: latitude5520's
pubkey comment is `me-nixos-latitude5520`, not a shared identity) — g16 and
homeserver almost certainly have their own too. So cross-machine trust is a
small mesh of public keys, not one key copied everywhere.

- **`provision/mesh-authorized-keys`** (new, committed, plain text): one
  pubkey per line, commented with the host it belongs to. Public keys only —
  safe to commit, same convention as the already-committed RustDesk server
  key. Seeded with latitude5520's key now; g16's (and optionally
  homeserver's, if it ever initiates outbound) appended when reachable
  (follow-up).
- **NixOS (both hosts):** `services.openssh.enable = true;` with
  `openFirewall = false;`, then allow port 22 on **both** the mesh and the
  LAN — never the public interface:
  - mesh: `networking.firewall.interfaces.awg0.allowedTCPPorts = [ 22 ];`
  - LAN: `networking.firewall.extraInputRules = "ip saddr 192.168.8.0/24 tcp
    dport 22 accept";` (source-CIDR scoped, so it's independent of the
    per-host wlan/eth interface name; nftables backend, the NixOS default).

  **Why the LAN interface is included** (correcting the original
  "mesh-only"): with mesh-only, when both boxes are home the *only* path to
  port 22 is `laptop → VPS → box`, hairpinning local SSH across the WAN — a
  latency/bandwidth tax *and* it makes the VPS a single point of failure for
  SSH'ing a machine sitting next to you. Allowing the LAN subnet too keeps a
  direct home path and a working fallback when the VPS is down. It stays off
  the public interface, so no exposure is added.
- `users.users.me.openssh.authorizedKeys.keyFiles = [
  ../../provision/mesh-authorized-keys ];` — one committed file, no per-host
  key duplication.
- **`modules/home/me.nix`:** `programs.ssh.matchBlocks` for `g16`,
  `latitude5520`, `homeserver` — `HostName` = the host's **mesh IP** (from
  `mesh-vpn-params.nix`), because that's the one address that resolves both
  at home and while roaming and is what an agent's non-interactive `ssh g16`
  needs. A human wanting the fast direct path at home can still use
  `ssh <host>.local` (existing mDNS, now that port 22 is open on the LAN).
- **`vps` alias too.** The hub is itself a fleet member worth an `ssh vps`.
  Unlike the NAT'd spokes it has a stable public address, so its `matchBlock`
  points `HostName` at **`cyphy.kz`** (its public domain), not the `10.0.0.1`
  mesh IP — that way `ssh vps` works with the tunnel up *or* down and never
  depends on the mesh being healthy to manage the very box that hosts it.
  `User` = whatever admin account you SSH the VPS as today (e.g. `root`);
  `Port` if it's non-default. This is a *client-side* convenience only — the
  VPS's own sshd/`authorized_keys` stays owned by the `vps` repo / your
  existing manual setup, and it is **not** added to
  `provision/mesh-authorized-keys` (that file is for the NixOS/Windows spokes
  this repo provisions). `10.0.0.1` remains available for the in-tunnel path
  when you specifically want it.
- **Host-key trust — pin, don't blind-TOFU.** `StrictHostKeyChecking =
  accept-new` is the transitional fallback, but the durable answer is to
  **pin each host's public host key declaratively** via NixOS
  `programs.ssh.knownHosts.<host> = { hostNames = [ "<mesh-ip>" "<host>"
  "<host>.local" ]; publicKey = "<ssh_host_ed25519_key.pub contents>"; };`
  (public host keys are safe to commit, same as the authorized-keys file).
  This gives real host authentication instead of blind trust-on-first-use.
  It also removes the reinstall footgun **provided the host's SSH *host*
  keypair is preserved across reinstalls** — restore `ssh_host_ed25519_key*`
  from backup rather than regenerating, so the committed pin stays valid and
  no `known_hosts` "IDENTIFICATION HAS CHANGED" wall ever appears. The host
  *private* key path therefore joins the per-host `~/.dotfiles` restore
  checklist (§7). Hosts not yet pinned fall through to `accept-new`.

### 5. Windows homeserver — baked into `provision/windows.ps1`, not a manual runbook

`provision/windows.ps1` is already the canonical Windows entry point for
*both* g16 and homeserver (per the existing onboarding routing table) and is
already idempotent/step-based — SSH setup becomes one more numbered step
there instead of a separate hand-followed runbook:

1. Install the `OpenSSH.Server` capability if `Get-WindowsCapability` reports
   it not installed (`Add-WindowsCapability -Online -Name
   OpenSSH.Server~~~~0.0.1.0` — this identifier is a fixed Windows-capability
   name, not an OpenSSH version; still the current, correct call); set `sshd`
   to `Automatic` and start it.
2. Set default shell to PowerShell (`HKLM:\SOFTWARE\OpenSSH\DefaultShell`) so
   an agent's commands land somewhere scriptable, not `cmd.exe`.
3. Write `provision/mesh-authorized-keys`'s contents to
   `$env:ProgramData\ssh\administrators_authorized_keys`, then fix the ACL
   with `icacls` (OpenSSH refuses that file unless it's locked to
   Administrators/SYSTEM only) — re-run-safe (rewrite + re-ACL each time,
   matching the script's existing idempotent style).
4. Add a Windows Firewall inbound rule for port 22 scoped to remote addresses
   `10.0.0.0/24,192.168.8.0/24` (mesh + LAN, matching the NixOS hosts'
   dual-path rule — never the open internet), create-if-absent so re-running
   doesn't duplicate it.
5. Homeserver's AWG *peer* already exists on the VPS (`10.0.0.2`) — but that
   is not enough (see Preconditions): the script/runbook must confirm the AWG
   **tunnel autostarts on boot and stays up** (a persistent client/service,
   not the AmneziaVPN GUI toggled by hand) and that its client-side
   `AllowedIPs` covers `10.0.0.0/24`, or the homeserver is unreachable while
   the laptop roams. No *new* VPN client is needed, only these two checks.
6. Host-key pinning (§4) for the homeserver is best-effort: Windows OpenSSH
   generates `ssh_host_ed25519_key` on first `sshd` start; capture its
   `.pub` for `programs.ssh.knownHosts` if you want the NixOS clients to pin
   it, otherwise they fall through to `accept-new`. Preserving that host key
   across a Windows reinstall is out of scope for now (the reinstall runbook
   is deferred) — a one-time `accept-new` re-pin after reinstall is
   acceptable for the single Windows box.

### 6. RustDesk — no code change now

Already functionally complete (server + peer seeding). Follow-up only: once
latitude5520 has run RustDesk once and has an ID, add it to the `peers` attr
in `modules/home/rustdesk-config.nix` (same shape as the existing entries).

### 7. Dotfiles hookup (`~/.dotfiles`, per-machine branches)

The user's separate bare-repo dotfiles tracker (one branch per machine,
secrets never committed but their paths listed in that branch's
`.gitignore` as a "restore this on a fresh box" checklist) should get two new
entries on each NixOS host's branch:
- the new AmneziaWG private key path (e.g. `/etc/amnezia-wg/awg0.key`);
- the SSH **host** private key(s) (`/etc/ssh/ssh_host_ed25519_key*`) — so a
  reinstall *restores* rather than regenerates the host identity, keeping the
  committed `programs.ssh.knownHosts` pins (§4) valid and avoiding the
  "IDENTIFICATION HAS CHANGED" friction.

Windows' `administrators_authorized_keys` doesn't need one — it's fully
regenerated by `provision/windows.ps1` from the committed
`mesh-authorized-keys` file, nothing machine-local to remember there.

## Explicitly out of scope

- Replacing AmneziaWG with Tailscale/Headscale or any other mesh VPN.
- Full-tunnel (route-everything) client configs.
- A self-hosted DNS server, mDNS reflector, or router-level DNS/static
  leases for discovery.
- sops-nix/agenix or any secrets-encryption-in-git framework.
- Regenerating g16's or homeserver's already-working peer configs.
- Homeserver's OS-reinstall runbook itself (still deferred, per the
  2026-07-07 onboarding spec) — only its *SSH setup step* is in scope here,
  added to the already-existing `provision/windows.ps1`.

## Follow-ups (need user action outside this session)

**VPS side (do first — the mesh is inert until these are live):**

1. **Apply the hairpin rule to the *running* VPS**, not just the file.
   Editing `wg0.dist.conf`'s `PostUp` only takes effect on interface
   bring-up, and `setup-awg.sh` has already run. Either restart the tunnel
   (`wg-quick down wg0 && wg-quick up wg0`, or the systemd unit) or add it
   live once: `iptables -A FORWARD -i wg0 -o wg0 -j ACCEPT`. Without this,
   peer↔peer forwarding is dead even after both repos merge.
2. **Verify the two existing peers meet the Preconditions:**
   - homeserver's *and* g16's client-side `AllowedIPs` cover `10.0.0.0/24`
     (widen the one line in place if narrow — not a full regen);
   - the homeserver's AWG tunnel autostarts on boot and stays up.
3. **Run `manage-peers.sh add latitude5520` on the VPS** to get its real mesh
   IP + private key.

**latitude5520 bring-up — strict order (skipping ahead brings up a broken
`awg0` at `switch` time):**

4. (a) place latitude5520's private key at the configured path
   (`/etc/amnezia-wg/awg0.key`); (b) fill real values into
   `mesh-vpn-params.nix` — VPS pubkey/port/obfuscation params from `awg.env`,
   copied *verbatim* (one wrong digit = silent no-handshake) — and set
   latitude5520's `.address` to the IP from step 3; (c) **only then**
   `just switch`. Enabling the module before the key exists fails the wg
   systemd unit on activation.
5. **Pin host keys (optional but recommended):** collect each host's
   `ssh_host_ed25519_key.pub` into `programs.ssh.knownHosts` (§4); until then
   `accept-new` covers it.

**Other machines / deferred:**

6. **Apply the codified config to g16** (reusing its already-generated key,
   not regenerating) next time it's reachable/on-site; also append g16's
   public key to `provision/mesh-authorized-keys`.
7. **Run `provision/windows.ps1` on homeserver** to pick up the new SSH step.
8. **latitude5520's RustDesk peer entry** — once it has a RustDesk ID.
9. **Add to each NixOS host's `~/.dotfiles` branch `.gitignore`:** the AWG
   private-key path *and* the SSH host private key path
   (`/etc/ssh/ssh_host_ed25519_key*`) — the "restore this on reinstall"
   checklist entries (§7).

## Verification

- `just quick` / `nix flake check` pass after the new modules are wired in.
- On latitude5520 (this machine, once keys/IP are filled in): `awg show
  awg0` shows a handshake with the VPS; `ssh g16` / `ssh homeserver` connect
  without a host-key prompt and land as the right user.
- From g16 (once codified): `ssh latitude5520` works the same way, proving
  the hairpin rule enables peer↔peer, not just peer↔hub.
- **Marquee test — roaming reaches the homeserver:** from a laptop *off* the
  home LAN (tether/other network), `ssh homeserver` connects. This is the
  whole point and exercises the hairpin + both peers' `AllowedIPs` at once.
- **Inbound-after-idle (proves `persistentKeepalive`):** leave the homeserver
  idle for a few minutes, then `ssh homeserver` from the roaming laptop — it
  must still connect. If it only works right after the homeserver has sent
  traffic, keepalive is missing on the homeserver peer.
- **LAN direct path (proves port 22 is open on the LAN, not mesh-only):** with
  both boxes at home, `ssh g16.local` connects *without* the VPN up, and a
  traceroute/RTT check shows it isn't hairpinning through the VPS.
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
10. SSH trust is a committed `provision/mesh-authorized-keys` file (public
    keys only, one per host) consumed by `keyFiles` on NixOS and written
    into `administrators_authorized_keys` on Windows — not one shared
    private key, since each machine already has its own distinct keypair.
11. Windows SSH setup is baked into the existing `provision/windows.ps1` as
    a new idempotent step, not a separate manual runbook — it already runs
    on both g16 and homeserver.
12. The user's `~/.dotfiles` bare-repo tracker (per-machine branches,
    secrets gitignored but their paths listed as a restore checklist) gets
    entries for the new AWG private-key path *and* the SSH host private key
    path per NixOS host.
13. Every peer that must be an SSH target while idle sets
    `persistentKeepalive = 25`, and every spoke's client-side `AllowedIPs`
    covers `10.0.0.0/24` — the VPS hairpin alone does not make peer↔peer or
    roaming-inbound work (added after review).
14. The two existing ad-hoc peers (g16, homeserver) are treated as
    *preconditions to verify* (AllowedIPs breadth, homeserver tunnel
    autostart), not assumed-correct — the original "don't touch them" scope
    silently gated the primary use case on unchecked properties.
15. sshd is reachable on the **mesh and the LAN** interfaces (source-CIDR
    scoped, never public), not mesh-only — mesh-only hairpinned same-LAN SSH
    through the VPS and made the VPS a SPOF for local SSH, conflicting with
    the stated LAN-reachability requirement.
16. Host-key trust is declaratively **pinned** via `programs.ssh.knownHosts`
    with host keys *preserved across reinstall*, with `accept-new` as the
    transitional fallback — real host auth instead of blind TOFU, and no
    reinstall "IDENTIFICATION HAS CHANGED" friction.
17. The VPS gets an `ssh vps` client alias in `matchBlocks` pointed at its
    public domain `cyphy.kz` (not the `10.0.0.1` mesh IP), so managing the
    hub never depends on the tunnel it hosts being up. Client-side only —
    the VPS's sshd/`authorized_keys` stays owned by the `vps` repo, and it is
    not added to `provision/mesh-authorized-keys`. Reaffirms the boundary:
    VPS provisioning is not pulled into `machines`; only a convenience alias.
