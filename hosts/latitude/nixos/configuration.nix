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
    ../../../modules/system/base.nix
    ../../../modules/system/laptop.nix
    ../../../modules/system/self-update.nix
    ../../../modules/system/git-autofetch
    ../../../modules/system/mesh-vpn.nix
    ../../../modules/system/fleet-hosts.nix

    # Desktop environment
    ../../../modules/desktop/gnome.nix

    # Hardware-specific modules
    ../../../modules/hardware/dell-latitude.nix

    # Program modules
    ../../../modules/programs/development.nix

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

  # Keep the flake repo auto-pulled (Claude config/memory go live via symlinks;
  # system changes still wait for `just switch`).
  services.nixRepoAutoPull.enable = true;

  # Background `git fetch` of all repos under /home/me every 10 min, so
  # "behind by N" is visible without fetching first (no pull — refs only).
  services.gitAutoFetch.enable = true;

  # AmneziaVPN background service (required for VPN connections)
  systemd.packages = [pkgs.amnezia-vpn];
  systemd.services.AmneziaVPN.wantedBy = ["multi-user.target"];

  # AmneziaWG mesh spoke — DISABLED for the Headscale fleet-mesh probe
  # (2026-07-13). Nothing load-bearing rides latitude's awg0 (backups go over
  # LAN), so dropping it lets Tailscale be tested on the raw ISP network with no
  # split-tunnel interference. Re-enable by flipping to true. address is kept for
  # a clean revert; it matches mesh-vpn-params.nix `hosts.latitude` (+ /32).
  # See docs/superpowers/specs/2026-07-13-headscale-fleet-mesh-probe-design.md.
  fleet.meshVpn = {
    enable = false;
    address = "10.0.0.8/32";
  };

  # Headscale/Tailscale fleet transport (probe). tailscaled only — the tailnet
  # is joined imperatively after switch:
  #   sudo tailscale up --login-server https://cc.cyphy.kz --authkey <KEY>
  services.tailscale.enable = true;

  # Host-specific packages
  environment.systemPackages = with pkgs; [
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

  # Dell battery charge limit
  hardware.dell.battery = {
    chargeUpto = 85;
    enableChargeUptoScript = true;
  };

  # Home Manager configuration
  home-manager = {
    extraSpecialArgs = {
      inherit inputs;
      hostname = "latitude";
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
