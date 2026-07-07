# modules/system/mesh-vpn-params.nix
#
# Non-secret AmneziaWG mesh constants + host -> mesh-IP map. Plain data
# (imported by modules/system/mesh-vpn.nix and modules/home/ssh.nix), NOT a
# NixOS module.
#
# Values below are the REAL non-secret AmneziaWG constants, read from the live
# VPS (`awg show`) + ~/my/vps/vps/awg.env on 2026-07-08. They are interface-
# level and safe to commit (public key, port, obfuscation params). Only the
# per-host PRIVATE keys are secret and never live here. The obfuscation params
# MUST match the VPS exactly — one wrong digit = silent no-handshake, no error.
{
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

  # Bare mesh IPs (no /32), verified against the live VPS peer table (2026-07-08).
  # - latitude5520 = .8: its NixOS side already meshes as peer `nix-lat5520`.
  # - g16 = .6: currently the `me-g614jv` peer (the ROG G16's Windows/app side);
  #   the NixOS g16 spoke shares this slot for now (one OS booted at a time) —
  #   revisit when g16-NixOS gets its own peer/key.
  # - homeserver = .2 (static baked peer on the VPS).
  hosts = {
    g16 = "10.0.0.6";
    homeserver = "10.0.0.2";
    latitude5520 = "10.0.0.8";
  };
}
