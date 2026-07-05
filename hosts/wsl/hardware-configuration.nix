# WSL has no bare-metal hardware to describe: the NixOS-WSL module
# (inputs.nixos-wsl.nixosModules.default, wired in flake.nix) provides the root
# filesystem, the Microsoft-supplied kernel, and the init shim. This stub only
# exists because `mkHost` in flake.nix imports
# ./hosts/<hostname>/hardware-configuration.nix unconditionally.
{...}: {}
