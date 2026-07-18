# modules/system/fleet.nix
#
# Fleet machine records — the single source of truth is the repo-root fleet.json.
# Plain data (imported by modules/home/ssh.nix), NOT a NixOS module.
#
# The former AmneziaWG mesh constants (vpsPublicKey / port / endpoint /
# obfuscation and the derived mesh-IP map) were removed when the AWG mesh was
# retired from the repo (2026-07-17). Only the fleet records remain, consumed by
# the ssh.nix client-config generator.
let
  fleet = builtins.fromJSON (builtins.readFile ../../fleet.json);
in {
  inherit (fleet) machines;
}
