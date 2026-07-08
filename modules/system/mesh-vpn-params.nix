# modules/system/mesh-vpn-params.nix
#
# Non-secret AmneziaWG mesh constants + the fleet's machine records / mesh-IP
# map, the latter DERIVED from the repo-root fleet.json (the single source of
# truth for mesh IPs — Phase 5a). Plain data (imported by
# modules/system/mesh-vpn.nix and modules/home/ssh.nix), NOT a NixOS module.
#
# The constants below are the REAL non-secret AmneziaWG values, read from the
# live VPS (`awg show`) + ~/my/vps/vps/awg.env on 2026-07-08. They are
# interface-level and safe to commit (public key, port, obfuscation params).
# Only the per-host PRIVATE keys are secret and never live here. The obfuscation
# params MUST match the VPS exactly — one wrong digit = silent no-handshake, no
# error.
let
  # Single fromJSON site for the whole repo: every mesh-IP consumer derives from
  # here, so a box's IP is changed in exactly one place (fleet.json).
  fleet = builtins.fromJSON (builtins.readFile ../../fleet.json);
  inherit (fleet) machines;
in {
  # VPS_PUBLIC_KEY (public — safe to commit).
  vpsPublicKey = "Hm4m5Cce1RdzpbcOezzliDBxV4ZY2tp9mIMWXNivY1s=";

  # AWG_PORT (the VPS wg0 listening port).
  port = 64531;

  # Endpoint by domain (Decision 7): a VPS IP change is one DNS update.
  endpoint = "cyphy.kz";

  # AWG_JC/JMIN/JMAX/S1/S2/H1..H4 — MUST match the VPS interface exactly.
  obfuscation = {
    Jc = 4;
    Jmin = 40;
    Jmax = 70;
    S1 = 71;
    S2 = 64;
    H1 = 4170542315;
    H2 = 917531710;
    H3 = 2420372300;
    H4 = 330186316;
  };

  # Raw fleet machine records (platform/roles/mesh/ssh/detect), for consumers
  # that need role or ssh.user — e.g. the ssh.nix matchBlocks generator.
  inherit machines;

  # Derived name -> bare mesh IP (no /32), from fleet.json. Replaces the old
  # hand-maintained map that had drifted (missing g614jv/vps, listed dead g16).
  hosts = builtins.mapAttrs (_name: m: m.mesh.ip) machines;
}
