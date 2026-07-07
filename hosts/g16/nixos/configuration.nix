{
  pkgs,
  inputs,
  ...
}: {
  imports = [
    # Hardware configuration
    ./hardware-configuration.nix

    # System modules
    ../../../modules/system/base.nix
    ../../../modules/system/laptop.nix
    ../../../modules/system/self-update.nix
    ../../../modules/system/git-autofetch
    ../../../modules/system/mesh-vpn.nix

    # Desktop environment
    ../../../modules/desktop/gnome.nix

    # Hardware-specific modules
    ../../../modules/nvidia.nix
    ../../../modules/hardware/asus-rog.nix

    # Program modules
    ../../../modules/programs/development.nix

    # Home manager
    inputs.home-manager.nixosModules.default
  ];

  # Host-specific configuration
  networking.hostName = "g16";

  # Localization (override defaults from base.nix)
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

  # ASUS ROG-specific services
  services.supergfxd.enable = true; # GPU mode switching
  services.asusd.enable = true;

  # Flatpak support
  services.flatpak.enable = true;

  # Keep the flake repo auto-pulled (Claude config/memory go live via symlinks;
  # system changes still wait for `just switch`).
  services.nixRepoAutoPull.enable = true;

  # Background `git fetch` of all repos under /home/me every 10 min, so
  # "behind by N" is visible without fetching first (no pull — refs only).
  services.gitAutoFetch.enable = true;

  # AmneziaWG mesh spoke + SSH over mesh/LAN. g16 is already peer 10.0.0.6 on
  # the VPS; this codifies it. address MUST match mesh-vpn-params.nix
  # `hosts.g16` (+ /32). Reuse g16's existing key at privateKeyFile; do NOT
  # regenerate. Do NOT `switch` until the key is in place — see the Runbook.
  fleet.meshVpn = {
    enable = true;
    address = "10.0.0.6/32";
  };

  # Host-specific packages
  environment.systemPackages = with pkgs; [
    # AppImage support
    appimage-run

    # System utilities
    os-prober
  ];

  # User configuration
  users.users.me = {
    isNormalUser = true;
    description = "Maxim";
    shell = pkgs.fish;
    extraGroups = [
      "networkmanager"
      "wheel"
      "docker"
    ];
  };

  # ASUS ROG specific configuration
  hardware.asus.battery = {
    chargeUpto = 85; # Charge to 85% to preserve battery health
    enableChargeUptoScript = true; # Enables charge-upto command
  };

  # Home Manager configuration
  home-manager = {
    extraSpecialArgs = {
      inherit inputs;
      hostname = "g16";
    };
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "backup";
    users = {
      "me" = import ../../../modules/home/me.nix;
    };
  };

  # System state version - DO NOT CHANGE
  system.stateVersion = "25.05";
}
