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
        # Windows account on the homeserver, confirmed via the existing
        # `server-lan` ssh alias which connects as `methe`.
        user = "methe";
        extraOptions.StrictHostKeyChecking = "accept-new";
      };
      # The hub is a fleet member too. Points at the public domain (not the
      # 10.0.0.1 mesh IP) so managing the VPS never depends on the tunnel it
      # hosts. Client-side only — the VPS sshd/authorized_keys is owned by the
      # vps repo and is NOT in provision/mesh-authorized-keys.
      vps = {
        hostname = params.endpoint; # cyphy.kz
        user = "debian"; # confirmed: the ~/.ssh/config `cyphy` host connects as debian.
        extraOptions.StrictHostKeyChecking = "accept-new";
      };
    };
  };
}
