# Fleet AmneziaWG mesh + SSH access — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give agents and humans `ssh <hostname>` into any fleet machine (roaming or on-LAN) by extending the existing VPS AmneziaWG hub into a full mesh and declaring sshd on every spoke.

**Architecture:** Two repos, additive. `~/my/vps` (bash) grows a VPS→peer hairpin route + interactive peer-add. `machines` (NixOS + PowerShell) grows two NixOS modules (shared constants + a mesh spoke), sshd wired to mesh+LAN, a Home-Manager SSH client config, and a Windows OpenSSH step. Private keys stay out-of-git at fixed paths; only public keys and non-secret AmneziaWG constants are committed.

**Tech Stack:** AmneziaWG (obfuscated WireGuard) via NixOS `networking.wireguard.interfaces.<n>.type = "amneziawg"`; NixOS Home-Manager `programs.ssh.matchBlocks`; Windows OpenSSH.Server capability; Debian bash provisioning scripts on the VPS.

## Global Constraints

- **Design source of truth:** `docs/superpowers/specs/2026-07-07-fleet-mesh-vpn-ssh-design.md`. Every decision below traces to it.
- **Secrets never committed.** Only *public* keys and *non-secret* AmneziaWG constants (pubkey, port, obfuscation params) go in git. Private keys live at fixed out-of-store paths, provisioned once.
- **This is config, not testable code.** Per-task "tests" are `nix-instantiate --parse`, `nix build --dry-run .#nixosConfigurations.<host>...`, `just quick`, and `bash -n`. **Do NOT invent pass/fail unit tests.** Anything needing real secrets, the VPS, or another machine is **unverifiable in this session** — it lives in the "Runbook" section at the end, not in a task.
- **Do NOT use `nix flake check` as a gate.** It is *already red* on `main` for a pre-existing, unrelated reason (the standalone `homeConfigurations."me@g16"` output has `home.file.".codex/host-memory.md".source == null`). The real target — `nixosConfigurations.<host>.config.system.build.toplevel` — evaluates green, and `just quick` treats the flake-check failure as a non-fatal warning (its hard gate is the g16 dry-build). Validate with dry-build, not flake check.
- **Split tunnel:** every client routes only `10.0.0.0/24`. LAN (`192.168.8.x`) is never entangled with the mesh.
- **AmneziaWG obfuscation params must match the VPS *exactly*** (Jc/Jmin/Jmax/S1/S2/H1-H4) or the tunnel silently fails to handshake. They are interface-level, shared by all peers. Placeholders here are wrong-until-filled from `~/my/vps/vps/awg.env` (Runbook).
- **`nixos-rebuild switch` is NOT run in any task.** Enabling the mesh module wires `enable = true`, but activation (bringing up `awg0`) requires the private key to already be on disk. Tasks validate by *dry-build only*; the Runbook owns the ordered `place key → fill params → switch`.
- **Staging hygiene:** the working tree already has an *uncommitted* `modules/home/me.nix` (the user's `dotfiles` fish alias, lines ~195-198). Never `git add modules/home/me.nix` wholesale in a way that sweeps it in. Task B6 handles this explicitly.

## File Structure

**`~/my/vps` repo (bash, committed with that repo's git):**
- `vps/awg/wg0.dist.conf` — VPS server config template; add the peer↔peer hairpin `FORWARD` rule.
- `vps/awg/wg0-homeserver.dist.conf` — homeserver client template; verify/widen its `AllowedIPs`.
- `vps/manage-peers.sh` — extract a client-config renderer, make `add` interactive, switch template to split-tunnel + `cyphy.kz`.

**`machines` repo (this repo):**
- `modules/system/mesh-vpn-params.nix` — **new**, plain data attrset: non-secret AmneziaWG constants + host→mesh-IP map. Imported by the module *and* the SSH client config.
- `modules/system/mesh-vpn.nix` — **new**, NixOS module: `fleet.meshVpn.*` options → `awg0` interface + sshd + firewall + authorized-keys.
- `provision/mesh-authorized-keys` — **new**, committed public keys (one per host), consumed by NixOS `keyFiles` and Windows.
- `modules/home/ssh.nix` — **new**, Home-Manager `programs.ssh.matchBlocks` for `g16`/`latitude5520`/`homeserver`/`vps`.
- `hosts/g16/nixos/configuration.nix`, `hosts/latitude5520/nixos/configuration.nix` — import `mesh-vpn.nix`, set `enable`/`address`.
- `modules/home/me.nix` — add `./ssh.nix` to `imports` (one line, away from the uncommitted alias).
- `modules/system/base.nix` — enable avahi `publish.addresses`.
- `provision/windows.ps1` — add the OpenSSH server step.

---

## Group A — VPS hub (`~/my/vps` repo)

> All Group A tasks run in `~/my/vps`. Commit there (that repo's own `git`), **not** in `machines`. No `shellcheck` is installed locally — validate with `bash -n` and by inspection. These scripts cannot be *executed* here (need root + `awg.env` + a live `wg0`); the renderer refactor must be byte-identical except the three intended lines.

### Task A1: VPS peer↔peer hairpin route

**Files:**
- Modify: `~/my/vps/vps/awg/wg0.dist.conf` (the `# NAT and forwarding rules` block)
- Inspect/modify: `~/my/vps/vps/awg/wg0-homeserver.dist.conf`

**Interfaces:**
- Produces: a running VPS that forwards `wg0 → wg0` traffic (peer-to-peer), once the config is re-applied (Runbook R1).

- [ ] **Step 1: Add the hairpin PostUp/PreDown pair.** In `wg0.dist.conf`, the block currently reads:

```
# NAT and forwarding rules
PostUp = iptables -t nat -A POSTROUTING -o VPS_NETWORK_INTERFACE -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -o VPS_NETWORK_INTERFACE -j ACCEPT
PostUp = iptables -A FORWARD -i VPS_NETWORK_INTERFACE -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

PreDown = iptables -t nat -D POSTROUTING -o VPS_NETWORK_INTERFACE -j MASQUERADE
PreDown = iptables -D FORWARD -i wg0 -o VPS_NETWORK_INTERFACE -j ACCEPT
PreDown = iptables -D FORWARD -i VPS_NETWORK_INTERFACE -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

Change it to (adds one `PostUp` and one `PreDown` — the `-i wg0 -o wg0` hairpin):

```
# NAT and forwarding rules
PostUp = iptables -t nat -A POSTROUTING -o VPS_NETWORK_INTERFACE -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -o VPS_NETWORK_INTERFACE -j ACCEPT
PostUp = iptables -A FORWARD -i VPS_NETWORK_INTERFACE -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
# Peer-to-peer (mesh): let one wg0 peer reach another through the hub.
PostUp = iptables -A FORWARD -i wg0 -o wg0 -j ACCEPT

PreDown = iptables -t nat -D POSTROUTING -o VPS_NETWORK_INTERFACE -j MASQUERADE
PreDown = iptables -D FORWARD -i wg0 -o VPS_NETWORK_INTERFACE -j ACCEPT
PreDown = iptables -D FORWARD -i VPS_NETWORK_INTERFACE -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PreDown = iptables -D FORWARD -i wg0 -o wg0 -j ACCEPT
```

- [ ] **Step 2: Verify the homeserver client template routes the whole mesh.** Read `wg0-homeserver.dist.conf`. Find its `[Peer]` (the one pointing at the VPS) `AllowedIPs`. If it is `0.0.0.0/0` it already covers the mesh — leave it. If it is anything narrower (e.g. `10.0.0.1/32` or `10.0.0.2/32`), change that one line to `AllowedIPs = 10.0.0.0/24` so the homeserver can reach the laptops, not just the hub. (This widens a route only — no key change, not a regeneration.)

- [ ] **Step 3: Validate.** This is a `wg-quick`-style config, not a shell script — validate by inspection: confirm the new `PostUp`/`PreDown` lines are balanced (one add, one delete, identical match) and `wg0-homeserver.dist.conf`'s `AllowedIPs` is `10.0.0.0/24` or `0.0.0.0/0`.

- [ ] **Step 4: Commit (in the vps repo).**

```bash
cd ~/my/vps
git add vps/awg/wg0.dist.conf vps/awg/wg0-homeserver.dist.conf
git commit -m "awg: add peer-to-peer hairpin FORWARD rule; ensure homeserver routes full mesh"
```

### Task A2: Interactive `manage-peers.sh add` + split-tunnel client template

**Files:**
- Modify: `~/my/vps/vps/manage-peers.sh` (`cmd_add`, `cmd_show`, and a new shared renderer)

**Interfaces:**
- Consumes: `awg.env` vars `AWG_JC/AWG_JMIN/AWG_JMAX/AWG_S1/AWG_S2/AWG_H1..H4`, `AWG_PORT`, `VPS_PUBLIC_KEY` (unchanged).
- Produces: client configs with `AllowedIPs = 10.0.0.0/24`, no `DNS` line, `Endpoint = cyphy.kz:<port>`; an `add` that prompts for name and IP.

- [ ] **Step 1: Add a shared renderer** (DRY — the config was duplicated verbatim in `cmd_add` and `cmd_show`, which is exactly how the two copies would drift). Insert this function *above* `cmd_add()` (after the `usage()` function, ~line 28):

```bash
# Single source of truth for the client config text (was duplicated in
# cmd_add/cmd_show). Split tunnel: AllowedIPs = mesh only, no DNS. Endpoint by
# domain so a VPS IP change is one DNS update, not a peer regeneration.
render_client_conf() {
    local privkey="$1" ip="$2"
    cat <<EOF
[Interface]
PrivateKey = $privkey
Address = $ip/32
MTU = 1280
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

[Peer]
PublicKey = $VPS_PUBLIC_KEY
Endpoint = cyphy.kz:$AWG_PORT
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF
}
```

- [ ] **Step 2: Rewrite `cmd_add` to be interactive.** Replace the whole `cmd_add()` (current lines ~30-110) with:

```bash
cmd_add() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        read -rp "Peer name: " name
    fi
    if [[ -z "$name" ]]; then
        echo "Name required." >&2
        exit 1
    fi

    # check name is not already used
    if grep -q "^# $name$" "$AWG_CONF" 2>/dev/null; then
        echo "Peer '$name' already exists." >&2
        exit 1
    fi

    # suggest next free IP (skip .1 = VPS, .2 = homeserver, floor at .3)
    local max_octet=2
    while IFS= read -r line; do
        octet=$(echo "$line" | grep -oP '10\.0\.0\.\K\d+')
        if [[ -n "$octet" && "$octet" -gt "$max_octet" ]]; then
            max_octet=$octet
        fi
    done < <(grep -oP 'AllowedIPs\s*=\s*10\.0\.0\.\d+/32' "$AWG_CONF" || true)
    local suggested="10.0.0.$((max_octet + 1))"

    # prompt for IP, Enter accepts the suggestion
    local peer_ip
    read -rp "IP [$suggested]: " peer_ip
    peer_ip="${peer_ip:-$suggested}"

    # validate: 10.0.0.X, 3<=X<=254, not already in use
    if [[ ! "$peer_ip" =~ ^10\.0\.0\.([0-9]{1,3})$ ]]; then
        echo "IP must be in 10.0.0.0/24 (e.g. $suggested)." >&2
        exit 1
    fi
    local host_octet="${BASH_REMATCH[1]}"
    if (( host_octet < 3 || host_octet > 254 )); then
        echo "IP host octet must be 3-254 (.1=VPS, .2=homeserver reserved)." >&2
        exit 1
    fi
    if grep -qP "AllowedIPs\s*=\s*${peer_ip//./\\.}/32" "$AWG_CONF"; then
        echo "IP $peer_ip is already in use." >&2
        exit 1
    fi

    # generate keypair
    mkdir -p "$PEERS_DIR"
    local peer_private_key peer_public_key
    peer_private_key=$(awg genkey)
    peer_public_key=$(echo "$peer_private_key" | awg pubkey)
    echo "$peer_private_key" > "$PEERS_DIR/$name.key"
    chmod 600 "$PEERS_DIR/$name.key"

    # append peer block to server config
    cat >> "$AWG_CONF" <<EOF

[Peer]
# $name
PublicKey = $peer_public_key
AllowedIPs = $peer_ip/32
EOF

    # apply live without restarting
    awg set wg0 peer "$peer_public_key" allowed-ips "$peer_ip/32"

    local client_conf
    client_conf=$(render_client_conf "$peer_private_key" "$peer_ip")

    echo "Peer '$name' added at $peer_ip"
    echo ""

    if command -v qrencode &>/dev/null; then
        echo "=== QR Code (scan with AmneziaWG app) ==="
        echo "$client_conf" | qrencode -t ansiutf8
        echo ""
    fi

    echo "=== Client config for '$name' ==="
    echo "$client_conf"
}
```

- [ ] **Step 3: Point `cmd_show` at the renderer.** In `cmd_show`, replace the inline `client_conf=$(cat <<EOF ... EOF )` heredoc (current lines ~192-215) with:

```bash
    local client_conf
    client_conf=$(render_client_conf "$peer_private_key" "$peer_ip")
```

- [ ] **Step 4: Validate syntax.**

Run: `cd ~/my/vps && bash -n vps/manage-peers.sh`
Expected: no output, exit 0.

- [ ] **Step 5: Inspection check.** Confirm `render_client_conf` output differs from the old template in exactly three ways: no `DNS = 1.1.1.1` line, `AllowedIPs = 10.0.0.0/24` (was `0.0.0.0/0`), `Endpoint = cyphy.kz:$AWG_PORT` (was `$VPS_PUBLIC_IP:$AWG_PORT`). Everything else byte-identical.

- [ ] **Step 6: Commit (in the vps repo).**

```bash
cd ~/my/vps
git add vps/manage-peers.sh
git commit -m "manage-peers: interactive add (name+IP), split-tunnel client template, DRY renderer"
```

---

## Group B — NixOS spokes (`machines` repo)

### Task B1: Shared non-secret constants (`mesh-vpn-params.nix`)

**Files:**
- Create: `modules/system/mesh-vpn-params.nix`

**Interfaces:**
- Produces (plain attrset, imported by B2 and B5):
  - `vpsPublicKey :: str`, `port :: int`, `endpoint :: str`
  - `obfuscation :: { Jc,Jmin,Jmax,S1,S2,H1,H2,H3,H4 :: int }`
  - `hosts :: { g16, latitude5520, homeserver :: str }` (bare mesh IPs, no CIDR)

- [ ] **Step 1: Write the file.** It is **plain data** (not a NixOS module — no `{ config, ... }:` args), so both a system module and a Home-Manager module can `import` it.

```nix
# modules/system/mesh-vpn-params.nix
#
# Non-secret AmneziaWG mesh constants + host -> mesh-IP map. Plain data
# (imported by modules/system/mesh-vpn.nix and modules/home/ssh.nix), NOT a
# NixOS module.
#
# !!! EVERY VALUE BELOW IS A PLACEHOLDER !!!
# Source of truth: ~/my/vps/vps/awg.env (gitignored, never committed here).
# Copy the real values in before the tunnel can handshake. The obfuscation
# params are interface-level and MUST match the VPS exactly — one wrong digit
# = silent no-handshake, no error message. See the Runbook in
# docs/superpowers/plans/2026-07-07-fleet-mesh-vpn-ssh.md.
{
  # VPS_PUBLIC_KEY from awg.env (public — safe to commit once real).
  vpsPublicKey = "REPLACE_WITH_VPS_PUBLIC_KEY_FROM_awg_env";

  # AWG_PORT from awg.env.
  port = 51820; # PLACEHOLDER

  # Endpoint by domain (Decision 7): a VPS IP change is one DNS update.
  endpoint = "cyphy.kz";

  # AWG_JC/JMIN/JMAX/S1/S2/H1..H4 from awg.env. PLACEHOLDERS — must match VPS.
  obfuscation = {
    Jc = 4;
    Jmin = 8;
    Jmax = 80;
    S1 = 0;
    S2 = 0;
    H1 = 1;
    H2 = 2;
    H3 = 3;
    H4 = 4;
  };

  # Bare mesh IPs (no /32). g16 + homeserver are live today; latitude5520 is a
  # PLACEHOLDER until `manage-peers.sh add latitude5520` assigns the real one.
  hosts = {
    g16 = "10.0.0.6";
    homeserver = "10.0.0.2";
    latitude5520 = "10.0.0.7"; # PLACEHOLDER
  };
}
```

- [ ] **Step 2: Validate syntax.**

Run: `cd ~/machines && nix-instantiate --parse modules/system/mesh-vpn-params.nix >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit.**

```bash
cd ~/machines
git add modules/system/mesh-vpn-params.nix
git commit -m "mesh-vpn: add non-secret AmneziaWG constants + host IP map (placeholders)"
```

### Task B2: The mesh spoke module (`mesh-vpn.nix`)

**Files:**
- Create: `modules/system/mesh-vpn.nix`

**Interfaces:**
- Consumes: `./mesh-vpn-params.nix` (B1); `provision/mesh-authorized-keys` (B3, referenced by path — the file must exist before a host that enables this module dry-builds, so B3 precedes B4).
- Produces: options `fleet.meshVpn.enable :: bool`, `fleet.meshVpn.address :: str` (CIDR, e.g. `"10.0.0.7/32"`), `fleet.meshVpn.privateKeyFile :: str` (default `/etc/amnezia-wg/awg0.key`). When enabled: interface `awg0`, sshd on mesh+LAN, `me`'s authorized keys.

- [ ] **Step 1: Write the module.**

```nix
# modules/system/mesh-vpn.nix
#
# AmneziaWG mesh SPOKE + SSH-over-mesh for NixOS fleet members. The VPS
# (~/my/vps) is the hub; this is the client side. Non-secret constants come
# from ./mesh-vpn-params.nix; the private key is provisioned out-of-git at
# `privateKeyFile` and is NEVER committed.
#
# Design: docs/superpowers/specs/2026-07-07-fleet-mesh-vpn-ssh-design.md
{
  config,
  lib,
  ...
}: let
  cfg = config.fleet.meshVpn;
  params = import ./mesh-vpn-params.nix;
in {
  options.fleet.meshVpn = {
    enable = lib.mkEnableOption "AmneziaWG mesh spoke + SSH reachable over mesh/LAN";

    address = lib.mkOption {
      type = lib.types.str;
      example = "10.0.0.7/32";
      description = ''
        This host's mesh address in CIDR form. Must match this host's entry in
        mesh-vpn-params.nix `hosts` (with /32 appended) and the VPS peer block.
      '';
    };

    privateKeyFile = lib.mkOption {
      # str, NOT path: a `path` type copies the file into the Nix store at eval
      # (leaking the secret and failing when it doesn't exist yet). Keep it a
      # bare string so it's read at activation, off-store.
      type = lib.types.str;
      default = "/etc/amnezia-wg/awg0.key";
      description = "Out-of-store path to this host's AmneziaWG private key.";
    };
  };

  config = lib.mkIf cfg.enable {
    # --- AmneziaWG spoke interface ---
    networking.wireguard.interfaces.awg0 = {
      type = "amneziawg";
      ips = [ cfg.address ];
      privateKeyFile = cfg.privateKeyFile;
      mtu = 1280;
      # Interface-level obfuscation (module lowercases these keys on render —
      # write them capitalised as the nixpkgs example does).
      extraOptions = params.obfuscation;
      peers = [
        {
          publicKey = params.vpsPublicKey;
          # Whole mesh through the tunnel (split tunnel + full mesh). With
          # allowedIPsAsRoutes (default true) this installs the 10.0.0.0/24
          # route automatically.
          allowedIPs = [ "10.0.0.0/24" ];
          endpoint = "${params.endpoint}:${toString params.port}";
          # Keep the NAT mapping open so the VPS can forward inbound packets to
          # us while we're idle (required for this host to be an SSH target).
          persistentKeepalive = 25;
        }
      ];
    };

    # --- sshd, reachable over mesh AND LAN, never the public interface ---
    services.openssh = {
      enable = true;
      openFirewall = false; # we scope the firewall ourselves, below
      settings.PasswordAuthentication = false;
      settings.KbdInteractiveAuthentication = false;
    };

    # Mesh: allow 22 on the awg0 interface.
    networking.firewall.interfaces.awg0.allowedTCPPorts = [ 22 ];

    # LAN: allow 22 only from the home subnet. Uses the iptables escape hatch
    # (extraCommands) rather than extraInputRules — the latter requires
    # networking.nftables.enable, a fleet-wide backend flip that can disrupt
    # Docker. Source-CIDR scoped, so it's independent of the wlan/eth name.
    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -p tcp -s 192.168.8.0/24 --dport 22 -j nixos-fw-accept
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D nixos-fw -p tcp -s 192.168.8.0/24 --dport 22 -j nixos-fw-accept || true
    '';

    # Trust: one committed public-keys file (public keys only), shared by all
    # fleet hosts. No per-host key duplication.
    users.users.me.openssh.authorizedKeys.keyFiles = [
      ../../provision/mesh-authorized-keys
    ];

    # Host-key pinning (Decision 16) is a follow-up: no host has an
    # ssh_host_ed25519_key.pub collected yet. Once collected, add e.g.
    #   programs.ssh.knownHosts.g16 = {
    #     hostNames = [ "10.0.0.6" "g16" "g16.local" ];
    #     publicKey = "ssh-ed25519 AAAA... root@g16";
    #   };
    # Until then clients fall through to StrictHostKeyChecking=accept-new (B5).
  };
}
```

- [ ] **Step 2: Validate syntax.**

Run: `cd ~/machines && nix-instantiate --parse modules/system/mesh-vpn.nix >/dev/null && echo OK`
Expected: `OK`. (Full evaluation happens in B4 once a host imports it.)

- [ ] **Step 3: Commit.**

```bash
cd ~/machines
git add modules/system/mesh-vpn.nix
git commit -m "mesh-vpn: add AmneziaWG spoke module (awg0 + sshd on mesh/LAN + authorized keys)"
```

### Task B3: Committed authorized-keys file

**Files:**
- Create: `provision/mesh-authorized-keys`

**Interfaces:**
- Produces: the file B2 references via `keyFiles` and C1 writes on Windows. One `ssh-...` public key per line.

- [ ] **Step 1: Write the file, seeded with latitude5520's real public key** (verified this session):

```
# Fleet SSH trust — PUBLIC keys only, one per host. Safe to commit.
# Consumed by NixOS (users.users.me.openssh.authorizedKeys.keyFiles) and by
# Windows (provision/windows.ps1 -> administrators_authorized_keys).
# Append g16's and (optionally) homeserver's keys when reachable (Runbook).
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBnlGSKtGHQwJNyODkQK0QyKX3h3hAOP2jjy5eAiEY8n me-nixos-latitude5520
```

- [ ] **Step 2: Commit.**

```bash
cd ~/machines
git add provision/mesh-authorized-keys
git commit -m "mesh-vpn: seed committed fleet authorized-keys file (latitude5520 pubkey)"
```

### Task B4: Wire the module into both hosts

**Files:**
- Modify: `hosts/latitude5520/nixos/configuration.nix` (imports list + host config)
- Modify: `hosts/g16/nixos/configuration.nix` (imports list + host config)

**Interfaces:**
- Consumes: `fleet.meshVpn.enable`, `fleet.meshVpn.address` (B2).

- [ ] **Step 1: latitude5520 — add the import.** In `hosts/latitude5520/nixos/configuration.nix`, in the `imports` list after `../../../modules/system/git-autofetch` (line ~15), add:

```nix
    ../../../modules/system/mesh-vpn.nix
```

- [ ] **Step 2: latitude5520 — enable it.** Add this block after the existing `systemd.services.AmneziaVPN.wantedBy` lines (~line 75):

```nix
  # AmneziaWG mesh spoke + SSH over mesh/LAN. address MUST match
  # mesh-vpn-params.nix `hosts.latitude5520` (+ /32). PLACEHOLDER until
  # `manage-peers.sh add latitude5520` on the VPS assigns the real IP.
  # NOTE: do NOT `switch` until the private key exists at privateKeyFile
  # (default /etc/amnezia-wg/awg0.key) — see the plan's Runbook.
  fleet.meshVpn = {
    enable = true;
    address = "10.0.0.7/32";
  };
```

- [ ] **Step 3: g16 — add the import.** In `hosts/g16/nixos/configuration.nix`, in the `imports` list after `../../../modules/system/git-autofetch` (line ~14), add:

```nix
    ../../../modules/system/mesh-vpn.nix
```

- [ ] **Step 4: g16 — enable it.** Add this block after the `services.gitAutoFetch.enable` line (~line 61):

```nix
  # AmneziaWG mesh spoke + SSH over mesh/LAN. g16 is already peer 10.0.0.6 on
  # the VPS; this codifies it. address MUST match mesh-vpn-params.nix
  # `hosts.g16` (+ /32). Reuse g16's existing key at privateKeyFile; do NOT
  # regenerate. Do NOT `switch` until the key is in place — see the Runbook.
  fleet.meshVpn = {
    enable = true;
    address = "10.0.0.6/32";
  };
```

- [ ] **Step 5: Dry-build both hosts (the real validation).** No activation — this only evaluates + builds the derivation graph.

Run:
```bash
cd ~/machines
nix build --dry-run ".#nixosConfigurations.latitude5520.config.system.build.toplevel" 2>&1 | tail -3
nix build --dry-run ".#nixosConfigurations.g16.config.system.build.toplevel" 2>&1 | tail -3
```
Expected: each prints derivations to be built and exits 0, with **no** evaluation error. (A "dirty git tree" warning is fine.)

- [ ] **Step 6: Commit.**

```bash
cd ~/machines
git add hosts/latitude5520/nixos/configuration.nix hosts/g16/nixos/configuration.nix
git commit -m "mesh-vpn: enable AmneziaWG spoke on g16 and latitude5520"
```

### Task B5: Home-Manager SSH client config (`ssh.nix`)

**Files:**
- Create: `modules/home/ssh.nix`
- Modify: `modules/home/me.nix` (imports list only)

**Interfaces:**
- Consumes: `../system/mesh-vpn-params.nix` (B1) for host IPs.
- Produces: `ssh g16 / latitude5520 / homeserver / vps` aliases with fixed HostName/User and `StrictHostKeyChecking=accept-new`.

- [ ] **Step 1: Write `modules/home/ssh.nix`.**

```nix
# modules/home/ssh.nix
#
# Non-interactive SSH client config for the fleet, so `ssh g16` (etc.) Just
# Works for agents and humans: fixed HostName (mesh IP), User, and
# accept-new host-key policy (TOFU-then-pin, safe on a private self-controlled
# mesh). Imported by me.nix.
#
# Design: docs/superpowers/specs/2026-07-07-fleet-mesh-vpn-ssh-design.md §4
{...}: let
  params = import ../system/mesh-vpn-params.nix;
in {
  programs.ssh = {
    enable = true;
    matchBlocks = {
      g16 = {
        hostname = params.hosts.g16;
        user = "me";
        extraOptions.StrictHostKeyChecking = "accept-new";
      };
      latitude5520 = {
        hostname = params.hosts.latitude5520;
        user = "me";
        extraOptions.StrictHostKeyChecking = "accept-new";
      };
      homeserver = {
        hostname = params.hosts.homeserver;
        # CONFIRM: the Windows account name on the homeserver, NOT necessarily
        # "me". A wrong User silently breaks `ssh homeserver`. Verify on the box.
        user = "me";
        extraOptions.StrictHostKeyChecking = "accept-new";
      };
      # The hub is a fleet member too. Points at the public domain (not the
      # 10.0.0.1 mesh IP) so managing the VPS never depends on the tunnel it
      # hosts. Client-side only — the VPS sshd/authorized_keys is owned by the
      # vps repo and is NOT in provision/mesh-authorized-keys.
      vps = {
        hostname = params.endpoint; # cyphy.kz
        user = "root"; # CONFIRM: whatever admin account you SSH the VPS as.
        extraOptions.StrictHostKeyChecking = "accept-new";
      };
    };
  };
}
```

- [ ] **Step 2: Import it from me.nix.** In `modules/home/me.nix`, add `./ssh.nix` to the `imports` list (lines 18-25), after `./rustdesk-config.nix`:

```nix
    # SSH client config for the fleet (mesh matchBlocks) — see ./ssh.nix
    ./ssh.nix
```

- [ ] **Step 3: Dry-build to validate the HM eval.**

Run: `cd ~/machines && nix build --dry-run ".#nixosConfigurations.latitude5520.config.system.build.toplevel" 2>&1 | tail -3`
Expected: exits 0, no evaluation error. (Home-Manager runs as a NixOS module here, so this exercises `ssh.nix`.)

- [ ] **Step 4: Commit — staging the two files EXPLICITLY.** The working tree has an *uncommitted* user change in `me.nix` (the `dotfiles` alias). Stage `ssh.nix` fully, but add **only your one-line import hunk** from `me.nix` — do not sweep the user's alias in.

```bash
cd ~/machines
git add modules/home/ssh.nix
git add -p modules/home/me.nix   # accept ONLY the ./ssh.nix imports hunk; 'n' to the alias hunk
git commit -m "mesh-vpn: add fleet SSH client matchBlocks (g16/latitude5520/homeserver/vps)"
```

If `git add -p` shows the import and the alias in one indivisible hunk, instead ask the user to commit their `me.nix` alias first, then re-run `git add modules/home/me.nix`.

### Task B6: Announce this host over mDNS (avahi `publish.addresses`)

**Files:**
- Modify: `modules/system/base.nix` (avahi block, ~lines 145-149)

**Interfaces:**
- Produces: `<host>.local` resolvable by other LAN machines (needed for the `ssh <host>.local` direct-LAN path in §4).

- [ ] **Step 1: Enable address publishing.** The avahi block currently is:

```nix
    avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };
```

Change to:

```nix
    avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
      # Announce THIS host's hostname/addresses on the LAN, so other machines
      # can resolve <host>.local (the direct-LAN SSH path when the VPN is off).
      publish = {
        enable = true;
        addresses = true;
      };
    };
```

- [ ] **Step 2: Dry-build.**

Run: `cd ~/machines && nix build --dry-run ".#nixosConfigurations.latitude5520.config.system.build.toplevel" 2>&1 | tail -3`
Expected: exits 0, no error.

- [ ] **Step 3: Commit.**

```bash
cd ~/machines
git add modules/system/base.nix
git commit -m "base: publish avahi addresses so <host>.local resolves on the LAN"
```

---

## Group C — Windows homeserver SSH (`machines` repo)

### Task C1: OpenSSH server step in `provision/windows.ps1`

**Files:**
- Modify: `provision/windows.ps1` (insert a new step before the `# ---- Done ----` block, ~line 202)

**Interfaces:**
- Consumes: `provision/mesh-authorized-keys` (B3).
- Produces: a homeserver reachable via `ssh` over mesh+LAN, landing in PowerShell.

> No PowerShell linter is available locally — validate by inspection: ASCII-only, idempotent (re-run-safe), matches the existing `Step/Info/Warn/Have` helper style. It cannot be executed here (Windows-only).

- [ ] **Step 1: Insert the SSH step.** Immediately before the `# ---- Done ----` line, add:

```powershell
# ---- 7. OpenSSH server (agent/human SSH into this box over mesh+LAN) --------
Step "7. OpenSSH server"
# 7a. Ensure the OpenSSH.Server capability is present. The '~~~~0.0.1.0' suffix
#     is a FIXED Windows-capability identifier, not a version to bump.
$sshCap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue |
          Where-Object Name -like 'OpenSSH.Server*' | Select-Object -First 1
if ($sshCap -and $sshCap.State -eq 'Installed') {
    Info "OpenSSH.Server already installed."
} else {
    Warn "installing OpenSSH.Server capability..."
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
}
# 7b. Service: start now + start on boot.
Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
Info "sshd: $((Get-Service sshd).Status), startup Automatic."

# 7c. Default shell = PowerShell, so an agent's commands land somewhere
#     scriptable rather than cmd.exe. Idempotent (rewrite each run).
$pwshExe = (Get-Command powershell.exe).Source
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value $pwshExe -PropertyType String -Force | Out-Null
Info "default shell: $pwshExe"

# 7d. Authorized keys. For an admin user, OpenSSH on Windows reads
#     ProgramData\ssh\administrators_authorized_keys and REFUSES it unless the
#     ACL is locked to Administrators/SYSTEM. Rewrite + re-ACL each run.
$adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
$srcKeys   = Join-Path $RepoDir 'provision\mesh-authorized-keys'
if (Test-Path $srcKeys) {
    # Strip comment/blank lines; write with no BOM (sshd rejects a BOM).
    $keyLines = Get-Content $srcKeys | Where-Object { $_ -and ($_ -notmatch '^\s*#') }
    [System.IO.File]::WriteAllLines($adminKeys, $keyLines, (New-Object System.Text.UTF8Encoding($false)))
    icacls $adminKeys /inheritance:r /grant 'Administrators:F' 'SYSTEM:F' | Out-Null
    Info "wrote $($keyLines.Count) key(s) to administrators_authorized_keys (ACL locked)."
} else {
    Warn "provision\mesh-authorized-keys not found - skipped authorized_keys."
}

# 7e. Firewall: inbound 22 from mesh + LAN only (never the open internet).
#     Create-if-absent so re-running doesn't duplicate the rule.
$fwRule = 'OpenSSH-Server-Mesh-LAN'
if (-not (Get-NetFirewallRule -Name $fwRule -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $fwRule -DisplayName 'OpenSSH Server (mesh+LAN)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 `
        -RemoteAddress @('10.0.0.0/24','192.168.8.0/24') | Out-Null
    Info "firewall rule '$fwRule' created (22 from 10.0.0.0/24, 192.168.8.0/24)."
} else {
    Info "firewall rule '$fwRule' already present."
}
Warn "Reachable over the mesh only while this box's AmneziaWG tunnel is up (autostart on boot) and its AllowedIPs covers 10.0.0.0/24 - verify separately."
```

- [ ] **Step 2: Inspection validation.** Confirm: (a) ASCII-only (no smart quotes / em-dashes / box characters); (b) every sub-step is re-run-safe (capability guarded by state check, service idempotent, keys rewritten, firewall create-if-absent); (c) uses the existing `Step/Info/Warn` helpers; (d) references `$RepoDir` (defined at the top of the script) for the keys path.

- [ ] **Step 3: Commit.**

```bash
cd ~/machines
git add provision/windows.ps1
git commit -m "windows: add OpenSSH server step (capability, pwsh shell, authorized keys, firewall)"
```

---

## Runbook (post-merge — needs real secrets / other machines; NOT session-verifiable)

Do these in order. This is where the placeholders become real. Nothing here can be validated in the authoring session (no VPS access, no local `awg.env`, g16/homeserver not reachable).

**On the VPS first (the mesh is inert until R1):**

- **R1. Apply the hairpin to the *running* VPS.** Editing `wg0.dist.conf` only takes effect on interface bring-up. Either re-apply the tunnel or add the rule live once:
  `sudo iptables -A FORWARD -i wg0 -o wg0 -j ACCEPT`
- **R2. Verify the two existing peers meet the preconditions:** homeserver's *and* g16's client-side `AllowedIPs` cover `10.0.0.0/24` (widen the one line if narrow); the homeserver's AmneziaWG tunnel autostarts on boot and stays up (a service, not the GUI toggled by hand).
- **R3. `sudo bash manage-peers.sh add latitude5520`** — accept or set its mesh IP; save the printed private key.

**latitude5520 bring-up — strict order (a premature `switch` fails `awg0` activation):**

- **R4.** Place the key: `sudo install -Dm600 <the-private-key> /etc/amnezia-wg/awg0.key`.
- **R5.** Fill real values in `modules/system/mesh-vpn-params.nix` — `vpsPublicKey`, `port`, all of `obfuscation.*` copied **verbatim** from `~/my/vps/vps/awg.env` (one wrong digit = silent no-handshake), and set `hosts.latitude5520` (and `hosts.g16` if it differs) to the real IP. If R3 gave latitude5520 an IP other than `10.0.0.7`, update `fleet.meshVpn.address` in its host config to match.
- **R6.** `just switch`. Then verify: `awg show awg0` shows a handshake with the VPS.
- **R7. (optional, recommended) Pin host keys:** once `sshd` has generated `/etc/ssh/ssh_host_ed25519_key.pub`, add a `programs.ssh.knownHosts.<host>` entry (see the commented scaffold in `mesh-vpn.nix`) and add `ssh_host_ed25519_key*` to this host's `~/.dotfiles` branch `.gitignore` so a reinstall restores rather than regenerates it.

**Other machines / deferred:**

- **R8.** On g16 (on-site, reusing its existing key — do NOT regenerate): place its key at `/etc/amnezia-wg/awg0.key`, `just switch`, and append g16's `~/.ssh/id_*.pub` to `provision/mesh-authorized-keys`.
- **R9.** On the homeserver: run `provision\windows.ps1` to pick up the OpenSSH step; confirm the `homeserver` `matchBlocks` `User` in `ssh.nix` matches the real Windows account name.
- **R10.** Add the AWG private-key path (`/etc/amnezia-wg/awg0.key`) to each NixOS host's `~/.dotfiles` branch `.gitignore` (restore checklist).
- **R11.** Once latitude5520 has run RustDesk once and has an ID, add it to `peers` in `modules/home/rustdesk-config.nix`.

**End-to-end verification (from the design's Verification section):** roaming laptop `ssh homeserver` connects; still connects after the homeserver has been idle a few minutes (proves keepalive); `ssh g16.local` on the home LAN connects without the VPN and without hairpinning through the VPS; `ssh homeserver` lands in PowerShell; VPN off doesn't break `192.168.8.x` / `*.local` LAN access.

---

## Self-Review

- **Spec coverage:** VPS hairpin (A1) ✓; interactive peer-add + split-tunnel template (A2) ✓; `mesh-vpn-params.nix` (B1) ✓; `mesh-vpn.nix` + host imports (B2/B4) ✓; SSH trust file + keyFiles + firewall mesh/LAN (B2/B3) ✓; matchBlocks incl. `vps` (B5) ✓; avahi publish (B6) ✓; Windows SSH step (C1) ✓; persistentKeepalive (B2) ✓; existing-peer preconditions (A1 S2, R2) ✓; host-key pinning scaffold + Runbook (B2/R7) ✓; dotfiles entries (R7/R10) ✓; RustDesk follow-up (R11) ✓.
- **Type consistency:** `mesh-vpn-params.nix` exposes `vpsPublicKey/port/endpoint/obfuscation/hosts`; consumed identically in `mesh-vpn.nix` (`params.obfuscation`, `params.vpsPublicKey`, `params.endpoint`, `params.port`) and `ssh.nix` (`params.hosts.*`, `params.endpoint`). `fleet.meshVpn.{enable,address,privateKeyFile}` defined in B2, set in B4. `hosts.*` are bare IPs (no CIDR); `.address` adds `/32` — kept consistent by the comments in B1/B4.
- **Placeholder scan:** the only placeholders are *data values* that cannot exist in-session (awg.env secrets, latitude5520's real IP), each loudly marked and owned by the Runbook — not missing implementation. All code is complete.
- **Refinement noted:** B2 uses `firewall.extraCommands` (iptables) rather than the spec's `extraInputRules` (nftables) to avoid a fleet-wide backend flip that could disrupt Docker — same effect, lower risk.
