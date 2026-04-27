{
  pkgs,
  lib,
  inputs,
  ...
}: {
  imports = [
    # Hardware configuration
    ./hardware-configuration.nix

    # System modules
    ../../modules/system/base.nix
    ../../modules/system/laptop.nix

    # Desktop environment
    ../../modules/desktop/gnome.nix

    # Hardware-specific modules
    ../../modules/hardware/dell-latitude.nix

    # Program modules
    ../../modules/programs/development.nix

    # Home manager
    inputs.home-manager.nixosModules.default
  ];

  # Host-specific configuration
  networking.hostName = "latitude5520";

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

  # nixos-hardware's common-cpu-intel adds intel-ocl whose download URL is dead
  # and which doesn't support Gen 11+ (Tiger Lake) anyway. Override with
  # intel-compute-runtime, which is the correct OpenCL runtime for this CPU.
  hardware.graphics.extraPackages = lib.mkForce (with pkgs; [
    intel-media-driver
    intel-vaapi-driver
    libva-vdpau-driver
    libvdpau-va-gl
    intel-compute-runtime
  ]);

  # Thunderbolt device authorization
  services.hardware.bolt.enable = true;

  # Flatpak support
  services.flatpak.enable = true;

  # Host-specific packages
  environment.systemPackages = with pkgs; [
    # System utilities
    os-prober
  ];

  # User configuration
  users.users.me = {
    isNormalUser = true;
    description = "Maxim";
    extraGroups = [
      "networkmanager"
      "wheel"
      "docker"
    ];
  };

  # Dell battery charge limit
  hardware.dell.battery = {
    chargeUpto = 85;
    enableChargeUptoScript = true;
  };

  # Home Manager configuration
  home-manager = {
    extraSpecialArgs = {
      inherit inputs;
      hostname = "latitude5520";
    };
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "backup";
    users = {
      "me" = import ../../modules/home/me.nix;
    };
  };

  # System state version - DO NOT CHANGE
  system.stateVersion = "25.05";
}
