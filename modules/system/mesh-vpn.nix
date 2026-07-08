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
      ips = [cfg.address];
      inherit (cfg) privateKeyFile;
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
          allowedIPs = ["10.0.0.0/24"];
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
    networking.firewall.interfaces.awg0.allowedTCPPorts = [22];

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
