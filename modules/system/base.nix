{
  pkgs,
  lib,
  ...
}: {
  # Boot configuration
  boot = {
    loader = {
      systemd-boot = {
        enable = true;
        consoleMode = "keep";
        editor = false;
        configurationLimit = 10; # Trim old boot entries
      };
      efi.canTouchEfiVariables = true;
      grub.enable = false;
    };

    # Use latest kernel for better hardware support
    kernelPackages = pkgs.linuxPackages_latest;

    # Kernel parameters for better performance and security
    kernelParams = [
      "quiet" # Reduce boot noise
      "splash" # Show splash screen
      "mitigations=auto" # Security mitigations
    ];

    # Tmp on tmpfs for better performance
    tmp = {
      useTmpfs = lib.mkDefault true;
      tmpfsSize = lib.mkDefault "50%";
    };
  };

  # Nix configuration
  nix = {
    settings = {
      # Enable flakes and new command
      experimental-features = ["nix-command" "flakes"];

      # Optimize store automatically
      auto-optimise-store = true;

      # Use substituters for faster builds
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];

      # Build settings
      max-jobs = "auto";
      # cores omitted — defaults to all available cores

      # Keep failed builds for debugging
      keep-failed = false;
      keep-outputs = false;
      keep-derivations = false;
    };

    # Garbage collection
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };

    # Optimize nix store weekly
    optimise = {
      automatic = true;
      dates = ["weekly"];
    };
  };

  # Networking
  networking = {
    networkmanager = {
      enable = true;
      wifi.powersave = false; # Better WiFi performance
    };

    # Firewall
    firewall = {
      enable = true;
      # allowedTCPPorts = [];
      # allowedUDPPorts = [];
    };
  };

  # systemd-resolved: required by openvpn3's netcfg service for VPN DNS
  # (NetworkManager integrates with it automatically).
  services.resolved.enable = true;

  # Localization
  time.timeZone = lib.mkDefault "UTC";

  i18n = {
    defaultLocale = lib.mkDefault "en_US.UTF-8";
    extraLocaleSettings = lib.mkDefault {
      LC_ADDRESS = "en_US.UTF-8";
      LC_IDENTIFICATION = "en_US.UTF-8";
      LC_MEASUREMENT = "en_US.UTF-8";
      LC_MONETARY = "en_US.UTF-8";
      LC_NAME = "en_US.UTF-8";
      LC_NUMERIC = "en_US.UTF-8";
      LC_PAPER = "en_US.UTF-8";
      LC_TELEPHONE = "en_US.UTF-8";
      LC_TIME = "en_US.UTF-8";
    };
  };

  # Hardware support
  hardware = {
    enableAllFirmware = true;
    enableRedistributableFirmware = true;
  };

  # Services
  services = {
    # Firmware updates
    fwupd.enable = true;

    # Printing support
    printing.enable = true;

    # Bluetooth
    blueman.enable = true;

    # Color management
    colord.enable = true;

    # Local network discovery
    avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };

    # DBus
    dbus.enable = true;
  };

  # Bluetooth
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = false; # Don't auto-enable Bluetooth on boot (saves battery; enable manually)
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socket";
        Experimental = true;
      };
    };
  };

  # ZRAM for better memory management
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # Security
  security = {
    rtkit.enable = true;
    polkit.enable = true;

    # Sudo configuration
    sudo = {
      enable = true;
      wheelNeedsPassword = true;
    };
  };

  # Allow unfree packages
  nixpkgs.config = {
    allowUnfree = true;
    # Permissive for broken packages (use sparingly)
    allowBroken = false;
    allowUnsupportedSystem = false;
  };

  # Essential system packages
  environment.systemPackages = with pkgs; [
    # System utilities
    vim
    nano
    wget
    curl
    git
    htop
    tree
    file
    which

    # Archive tools
    unzip
    zip
    p7zip

    # Network tools
    networkmanagerapplet

    # Hardware info
    pciutils
    usbutils
    lshw

    # Boot management
    efibootmgr

    # Command runner
    just

    # Home Manager CLI
    home-manager
  ];

  programs.fish.enable = true;

  # OpenVPN 3 client (supports browser-based SSO/OAuth web-auth,
  # which networkmanager-openvpn cannot do)
  programs.openvpn3.enable = true;

  # System state version
  system.stateVersion = lib.mkDefault "25.05";
}
