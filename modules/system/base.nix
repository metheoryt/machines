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

    # LTS kernel (nixpkgs default). Kept off linuxPackages_latest as the safer
    # track for the NVIDIA driver (see CLAUDE.md); the AWG mesh that formerly also
    # required it has been retired.
    kernelPackages = pkgs.linuxPackages;

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

  # Disable Intel WiFi (iwlwifi/iwlmvm) power management. NetworkManager's
  # wifi.powersave only controls 802.11 PS-Poll; the driver still defaults to
  # power_scheme=2 (balanced), which causes periodic latency spikes that show
  # up as stutter/freezes in latency-sensitive traffic (e.g. RustDesk, VoIP).
  boot.extraModprobeConfig = ''
    options iwlwifi power_save=0 d0i3_disable=1 uapsd_disable=1
    options iwlmvm power_scheme=1
  '';

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
      # Announce THIS host's hostname/addresses on the LAN, so other machines
      # can resolve <host>.local (the direct-LAN SSH path when the VPN is off).
      publish = {
        enable = true;
        addresses = true;
      };
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

      # Passwordless nixos-rebuild + GC for `me`, so the just switch/upgrade/
      # test/clean recipes run unattended (e.g. driven by an agent) with no tty
      # password prompt. NOPASSWD nixos-rebuild is effectively passwordless root
      # for `me` — accepted on these personal boxes; the agent still gates each
      # invocation behind its own approval prompt.
      extraRules = [
        {
          users = ["me"];
          commands = [
            {
              command = "/run/current-system/sw/bin/nixos-rebuild";
              options = ["NOPASSWD"];
            }
            {
              command = "/run/current-system/sw/bin/nix-collect-garbage";
              options = ["NOPASSWD"];
            }
          ];
        }
      ];
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
