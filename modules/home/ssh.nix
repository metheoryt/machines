# modules/home/ssh.nix
#
# Non-interactive SSH client config for the fleet, so `ssh latitude5520` (etc.)
# Just Works for agents and humans: fixed HostName, User, and accept-new
# host-key policy (TOFU-then-pin, safe on a private self-controlled mesh).
# Imported by me.nix.
#
# The per-host blocks are GENERATED from fleet.json (via mesh-vpn-params.nix) —
# one block per fleet member, so adding/removing a machine or changing its IP is
# a one-line fleet.json edit. HostName keys on mesh.role: the hub (vps) points at
# its public domain (cyphy.kz) so managing it never depends on the tunnel/tailnet
# it hosts; every other member points at its TAILNET IP (fleet.json tailnet.ip).
# The old AmneziaWG mesh IPs (mesh.ip) are no longer used for SSH — the fleet's
# SSH transport is the Headscale tailnet.
#
# Uses the current `programs.ssh.settings` API (upstream OpenSSH directive names
# directly), NOT the deprecated `matchBlocks`/`extraOptions`. `enableDefaultConfig`
# is turned off and the old implicit `Host *` defaults re-declared verbatim under
# `settings."*"` (rendered last), so behaviour is unchanged and no home-manager
# deprecation warnings fire.
#
# Design: docs/superpowers/specs/2026-07-08-fleet-provisioner-phase5-mesh-executor-design.md
_: let
  params = import ../system/mesh-vpn-params.nix;
  mkBlock = name: m: {
    HostName =
      if m.mesh.role == "hub"
      then params.endpoint # e.g. cyphy.kz — hub SSH must not depend on the transport it hosts
      else m.tailnet.ip; # tailnet IP; was the dead AWG params.hosts.${name}
    User = m.ssh.user or "me";
    StrictHostKeyChecking = "accept-new";
  };
in {
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings =
      {
        # Home Manager's former `enableDefaultConfig = true` defaults, kept explicit.
        "*" = {
          ForwardAgent = false;
          AddKeysToAgent = "no";
          Compression = false;
          ServerAliveInterval = 0;
          ServerAliveCountMax = 3;
          HashKnownHosts = false;
          UserKnownHostsFile = "~/.ssh/known_hosts";
          ControlMaster = "no";
          ControlPath = "~/.ssh/master-%r@%n:%p";
          ControlPersist = "no";
        };
      }
      // builtins.mapAttrs mkBlock params.machines;
  };
}
