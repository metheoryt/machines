# modules/system/mesh-vpn-params.nix
#
# Non-secret AmneziaWG mesh constants + host -> mesh-IP map. Plain data
# (imported by modules/system/mesh-vpn.nix and modules/home/ssh.nix), NOT a
# NixOS module.
#
# !!! EVERY VALUE BELOW IS A PLACEHOLDER !!!
# Source of truth: ~/my/vps/vps/awg.env (gitignored, never committed here).
# Copy the real values in before the tunnel can handshake. The obfuscation
# params are interface-level and MUST match the VPS exactly — one wrong digit
# = silent no-handshake, no error message. See the Runbook in
# docs/superpowers/plans/2026-07-07-fleet-mesh-vpn-ssh.md.
{
  # VPS_PUBLIC_KEY from awg.env (public — safe to commit once real).
  vpsPublicKey = "REPLACE_WITH_VPS_PUBLIC_KEY_FROM_awg_env";

  # AWG_PORT from awg.env.
  port = 51820; # PLACEHOLDER

  # Endpoint by domain (Decision 7): a VPS IP change is one DNS update.
  endpoint = "cyphy.kz";

  # AWG_JC/JMIN/JMAX/S1/S2/H1..H4 from awg.env. PLACEHOLDERS — must match VPS.
  obfuscation = {
    Jc = 4;
    Jmin = 8;
    Jmax = 80;
    S1 = 0;
    S2 = 0;
    H1 = 1;
    H2 = 2;
    H3 = 3;
    H4 = 4;
  };

  # Bare mesh IPs (no /32). g16 + homeserver are live today; latitude5520 is a
  # PLACEHOLDER until `manage-peers.sh add latitude5520` assigns the real one.
  hosts = {
    g16 = "10.0.0.6";
    homeserver = "10.0.0.2";
    latitude5520 = "10.0.0.7"; # PLACEHOLDER
  };
}
