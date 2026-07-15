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
{lib, ...}: let
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

  # Materialize ~/.ssh/config as a REAL, me-owned file instead of the
  # home-manager store symlink.
  #
  # Why: OpenSSH strict-checks the owner of the *resolved* config file and
  # refuses it ("Bad owner or permissions") unless it's owned by the caller or
  # root. Home Manager places ~/.ssh/config as a symlink into the (root-owned)
  # nix store — which is fine on a normal host. But the Orca IDE (orca-bin.nix)
  # runs each terminal inside a nested user namespace that maps only uid 1000,
  # so root — and thus the whole store — reads as `nobody:nogroup` in there.
  # OpenSSH then sees the config owned by neither `me` nor root and bails,
  # breaking git-over-ssh and every `ssh <fleet-host>` from inside Orca.
  #
  # A real file owned by uid 1000 is accepted both inside and outside that
  # namespace, so we dereference the symlink into a plain 0600 file after HM
  # links it. Two phases because HM's `checkLinkTargets` aborts activation if it
  # finds a non-store-symlink where it wants to place its managed link — so we
  # first remove last activation's real file (letting HM relink cleanly), then
  # re-materialize after `linkGeneration`. Idempotent and harmless on hosts that
  # never run Orca (a real me-owned config works everywhere).
  home.activation = {
    sshConfigUnmaterialize = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
      if [ -e "$HOME/.ssh/config" ] && [ ! -L "$HOME/.ssh/config" ]; then
        $DRY_RUN_CMD rm -f "$HOME/.ssh/config"
      fi
    '';
    sshConfigMaterialize = lib.hm.dag.entryAfter ["linkGeneration"] ''
      if [ -L "$HOME/.ssh/config" ]; then
        _hm_ssh_target="$(readlink -f "$HOME/.ssh/config")"
        $DRY_RUN_CMD rm -f "$HOME/.ssh/config"
        $DRY_RUN_CMD install -m600 "$_hm_ssh_target" "$HOME/.ssh/config"
      fi
    '';
  };
}
