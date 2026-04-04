{
  pkgs,
  lib,
  ...
}: {
  # Laptop-specific power management
  services.power-profiles-daemon.enable = true; # Don't pair with TLP

  # Intel CPU thermal management
  services.thermald.enable = true;

  # Better power management for Intel CPUs
  powerManagement = {
    enable = true;
    cpuFreqGovernor = lib.mkDefault "powersave";
  };

  # Laptop lid settings
  services.logind = {
    settings.Login.HandleLidSwitchExternalPower = "lock";
    settings.Login.HandleLidSwitch = "suspend";
    settings.Login.HandlePowerKey = "suspend";
  };

  # Battery optimization
  services.upower = {
    enable = true;
    percentageLow = 20;
    percentageCritical = 5;
    percentageAction = 3;
    criticalPowerAction = "Hibernate";
  };

  # Auto-cpufreq for better battery life (alternative to power-profiles-daemon)
  # services.auto-cpufreq = {
  #   enable = false; # Enable if you disable power-profiles-daemon
  #   settings = {
  #     battery = {
  #       governor = "powersave";
  #       turbo = "never";
  #     };
  #     charger = {
  #       governor = "performance";
  #       turbo = "auto";
  #     };
  #   };
  # };

  # Backlight control
  hardware.acpilight.enable = true;
  services.actkbd = {
    enable = true;
    bindings = [
      {
        keys = [224];
        events = ["key"];
        command = "/run/current-system/sw/bin/brightnessctl set 10%-";
      }
      {
        keys = [225];
        events = ["key"];
        command = "/run/current-system/sw/bin/brightnessctl set +10%";
      }
    ];
  };

  # Enable touchpad
  services.libinput = {
    enable = true;
    touchpad = {
      tapping = true;
      naturalScrolling = true;
      disableWhileTyping = true;
    };
  };

  # Laptop-specific kernel parameters
  boot.kernelParams = [
    "intel_pstate=active" # Better Intel CPU power management
    "i915.fastboot=1" # Faster boot with Intel graphics
  ];

  # Hardware specific optimizations
  hardware = {
    # Enable hardware video acceleration
    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        intel-media-driver # For modern Intel GPUs
        intel-vaapi-driver # For older Intel GPUs
        libva-vdpau-driver
        libvdpau-va-gl
      ];
    };

    # CPU microcode updates
    cpu.intel.updateMicrocode = lib.mkDefault true;
  };

  # Laptop-specific environment variables
  environment.variables = {
    # Better Intel graphics performance
    VDPAU_DRIVER = lib.mkDefault "va_gl";
  };

  # Additional laptop packages
  environment.systemPackages = with pkgs; [
    # Battery monitoring
    acpi
    powertop

    # Hardware control
    brightnessctl

    # System monitoring
    lm_sensors

    # Wifi management
    iw
    wirelesstools
  ];

  # Enable laptop mode for better disk power management
  powerManagement.scsiLinkPolicy = "med_power_with_dipm";
}
