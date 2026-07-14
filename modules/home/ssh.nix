# modules/home/ssh.nix
#
# Non-interactive SSH client config for the fleet, so `ssh latitude` (etc.)
# Just Works for agents and humans: fixed HostName, User, and accept-new
# host-key policy (TOFU-then-pin, safe on a private self-controlled mesh).
# Imported by me.nix.
#
# The per-host blocks are GENERATED from fleet.json (via mesh-vpn-params.nix) —
# one block per fleet member, so adding/removing a machine or changing its IP is
# a one-line fleet.json edit. HostName now comes from MagicDNS (Headscale, suffix
# gg.ez), which resolves every fleet member's bare name fleet-wide — so no
# per-box HostName is emitted here, EXCEPT the hub (vps), which points at its
# public domain (cyphy.kz) so managing it never depends on the tunnel/tailnet
# it hosts. A User override is only emitted when a machine's fleet.json ssh.user
# differs from the default `me`. The old AmneziaWG mesh IPs (mesh.ip) and the
# tailnet IPs formerly used here are no longer needed for SSH.
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
  mkBlock = _name: m:
    (
      if m.mesh.role == "hub"
      then {HostName = params.endpoint;} # cyphy.kz — hub SSH must not depend on the transport it hosts
      else {} # MagicDNS resolves the bare name fleet-wide
    )
    // (
      if (m.ssh.user or "me") != "me"
      then {User = m.ssh.user;}
      else {}
    )
    // {StrictHostKeyChecking = "accept-new";};
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
