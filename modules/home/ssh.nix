# modules/home/ssh.nix
#
# Non-interactive SSH client config for the fleet, so `ssh latitude5520` (etc.)
# Just Works for agents and humans: fixed HostName, User, and accept-new
# host-key policy (TOFU-then-pin, safe on a private self-controlled mesh).
# Imported by me.nix.
#
# matchBlocks are GENERATED from fleet.json (via mesh-vpn-params.nix) — one
# block per fleet member, so adding/removing a machine or changing its IP is a
# one-line fleet.json edit. HostName keys on mesh.role: the hub (vps) points at
# its public domain so managing it never depends on the tunnel it hosts; every
# other member points at its mesh IP.
#
# Design: docs/superpowers/specs/2026-07-08-fleet-provisioner-phase5-mesh-executor-design.md
{...}: let
  params = import ../system/mesh-vpn-params.nix;
  mkBlock = name: m: {
    hostname =
      if m.mesh.role == "hub"
      then params.endpoint # e.g. cyphy.kz — never the 10.0.0.1 mesh IP
      else params.hosts.${name};
    user = m.ssh.user or "me";
    extraOptions.StrictHostKeyChecking = "accept-new";
  };
in {
  programs.ssh = {
    enable = true;
    matchBlocks = builtins.mapAttrs mkBlock params.machines;
  };
}
