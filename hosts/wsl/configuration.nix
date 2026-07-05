# WSL2 host — the portable half of the fleet config, nothing bare-metal.
#
# Deliberately does NOT import base.nix / laptop.nix / gnome.nix /
# dell-latitude.nix: base.nix hard-enables systemd-boot + EFI (which fails to
# activate under WSL — there is no /boot/EFI) and pulls NetworkManager /
# bluetooth / printing / avahi that WSL either owns or doesn't need. Instead we
# inline just the nix settings we want and lean on:
#   - the NixOS-WSL module (kernel, init, rootfs, `wsl.*` options)
#   - modules/programs/development.nix (the reusable dev toolchain)
#   - modules/home/me-wsl.nix (a lean CLI home profile — claude/codex synced,
#     git/fish/starship, gortex daemon; no GUI)
#
# Build a tarball from a Nix host (or an existing NixOS-WSL instance):
#   sudo nix run .#nixosConfigurations.wsl.config.system.build.tarballBuilder
# then on Windows:
#   wsl --install --from-file nixos.wsl        # WSL >= 2.4.4 (.wsl format)
#   # older WSL: wsl --import NixOS <dir> nixos.wsl --version 2
{
  pkgs,
  lib,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix

    # Reusable dev toolchain (git/gh, editors, python/node, docker, nix-ld,
    # gortex/openclaude, direnv, fonts). Note: also pulls slack + zoom-us (GUI)
    # since it's shared with the desktop hosts — harmless prebuilt binaries here.
    ../../modules/programs/development.nix

    # Home Manager (NixOS-integrated so home modules see `osConfig`).
    inputs.home-manager.nixosModules.default
  ];

  # NixOS-WSL core.
  wsl = {
    enable = true;
    defaultUser = "me";
  };

  networking.hostName = "wsl";

  # Localization — match the laptop (user is in Almaty).
  time.timeZone = "Asia/Almaty";
  i18n.defaultLocale = "ru_RU.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "ru_RU.UTF-8";
    LC_IDENTIFICATION = "ru_RU.UTF-8";
    LC_MEASUREMENT = "ru_RU.UTF-8";
    LC_MONETARY = "ru_RU.UTF-8";
    LC_NAME = "ru_RU.UTF-8";
    LC_NUMERIC = "ru_RU.UTF-8";
    LC_PAPER = "ru_RU.UTF-8";
    LC_TELEPHONE = "ru_RU.UTF-8";
    LC_TIME = "ru_RU.UTF-8";
  };

  # Nix settings — the portable subset of base.nix (flakes, caches, GC). No
  # boot/hardware/desktop options.
  nix = {
    settings = {
      experimental-features = ["nix-command" "flakes"];
      auto-optimise-store = true;
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
      max-jobs = "auto";
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
    optimise = {
      automatic = true;
      dates = ["weekly"];
    };
  };

  programs.fish.enable = true;

  # User — must match wsl.defaultUser.
  users.users.me = {
    isNormalUser = true;
    description = "Maxim";
    shell = pkgs.fish;
    extraGroups = [
      "wheel"
      "docker"
    ];
  };

  environment.systemPackages = with pkgs; [
    just
    home-manager
    wslu # `wslview` etc. — open Windows apps / URLs from inside WSL
  ];

  # Home Manager configuration — lean CLI profile (no GUI stack).
  home-manager = {
    extraSpecialArgs = {
      inherit inputs;
      hostname = "wsl";
    };
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "backup";
    users = {
      "me" = import ../../modules/home/me-wsl.nix;
    };
  };

  # DO NOT CHANGE.
  system.stateVersion = "25.05";
}
