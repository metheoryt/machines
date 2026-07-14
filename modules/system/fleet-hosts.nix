# modules/system/fleet-hosts.nix
#
# Generates networking.hosts (static /etc/hosts entries) for the whole fleet from
# fleet.json's tailnet IPs, so every NixOS box resolves `homeserver`, `vps`,
# `g614jv`, `latitude5520` by name over the tailnet — no DNS/MagicDNS resolver
# needed. The Windows/Debian equivalent is the `hosts` provisioner role. Reuses
# the single fromJSON site in mesh-vpn-params.nix (its `machines`), so a box's IP
# is still changed in exactly one place (fleet.json).
#
# Design: docs/superpowers/specs/2026-07-14-fleet-ssh-over-tailnet-and-hosts-design.md
_: let
  params = import ./mesh-vpn-params.nix;
in {
  networking.hosts = builtins.listToAttrs (
    map (name: {
      name = params.machines.${name}.tailnet.ip; # IP is the attr key
      value = [name]; # the hostname(s) for that IP
    }) (builtins.attrNames params.machines)
  );
}
