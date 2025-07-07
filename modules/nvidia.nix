{ config, lib, pkgs, ... }:

{
  hardware.graphics.enable = true;
  hardware.nvidia.open = true;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.stable;
}
