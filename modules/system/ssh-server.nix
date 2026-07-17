# modules/system/ssh-server.nix
#
# Fleet SSH-server role: keys-only sshd reachable over the Headscale tailnet
# (tailscale0 / 100.64.0.0/10) and the home LAN, never the public interface.
# Decoupled from the (retired) AmneziaWG mesh — this is the single owner of the
# fleet's SSH-server role on NixOS. Trust comes from one committed public-keys
# file shared by all fleet hosts.
#
# Design: docs/superpowers/specs/2026-07-17-fleet-ssh-tailnet-retire-awg-design.md
{
  config,
  lib,
  ...
}: let
  cfg = config.fleet.sshServer;
in {
  options.fleet.sshServer = {
    enable = lib.mkEnableOption "keys-only sshd reachable over the tailnet + LAN";
  };

  config = lib.mkIf cfg.enable {
    # Keys-only sshd; we scope the firewall ourselves (openFirewall = false).
    services.openssh = {
      enable = true;
      openFirewall = false;
      settings.PasswordAuthentication = false;
      settings.KbdInteractiveAuthentication = false;
    };

    # Tailnet: allow 22 on the tailscale0 interface. Bound to the actual tailnet
    # iface (Tailscale crypto + Headscale ACLs are the source auth); tighter than
    # a source-CIDR. iptables matches -i tailscale0 at packet time, so it is safe
    # even before tailscaled brings the interface up.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [22];

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
      ../../provision/fleet-authorized-keys
    ];

    # Host-key pinning is a follow-up: no host has an ssh_host_ed25519_key.pub
    # collected yet. Once collected, add e.g.
    #   programs.ssh.knownHosts.latitude = {
    #     hostNames = [ "latitude" "100.64.0.2" ];
    #     publicKey = "ssh-ed25519 AAAA... root@latitude";
    #   };
    # Until then clients fall through to StrictHostKeyChecking=accept-new.
  };
}
