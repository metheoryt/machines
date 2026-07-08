{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hardware.asus.battery;
in {
  # Battery charge limiting options
  options.hardware.asus.battery = {
    chargeUpto = lib.mkOption {
      description = "Maximum level of charge for your battery, as a percentage.";
      default = 85;
      type = lib.types.int;
    };
    enableChargeUptoScript = lib.mkOption {
      description = "Whether to add charge-upto to environment.systemPackages. `charge-upto 75` temporarily sets the charge limit to 75%.";
      default = true;
      type = lib.types.bool;
    };
  };

  config = {
    # ROG-specific keyboard fixes from nixos-hardware
    services.udev.extraHwdb = ''
      evdev:name:*:dmi:bvn*:bvr*:bd*:svnASUS*:pn*:*
        KEYBOARD_KEY_ff31007c=f20    # fixes mic mute button
        KEYBOARD_KEY_ff3100b2=home   # Set fn+LeftArrow as Home
        KEYBOARD_KEY_ff3100b3=end    # Set fn+RightArrow as End
    '';

    # System packages for ROG functionality
    environment.systemPackages = with pkgs;
      lib.optionals cfg.enableChargeUptoScript [
        # Battery charge control script
        (pkgs.writeScriptBin "charge-upto" ''
          #!${pkgs.bash}/bin/bash
          echo ''${1:-${toString cfg.chargeUpto}} > /sys/class/power_supply/BAT?/charge_control_end_threshold
        '')
      ];

    systemd.services.battery-charge-threshold = {
      wantedBy = [
        "local-fs.target"
        "suspend.target"
      ];
      after = [
        "local-fs.target"
        "suspend.target"
      ];
      description = "Set the battery charge threshold to ${toString cfg.chargeUpto}%";
      startLimitBurst = 5;
      startLimitIntervalSec = 1;
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        ExecStart = "${pkgs.runtimeShell} -c 'echo ${toString cfg.chargeUpto} > /sys/class/power_supply/BAT?/charge_control_end_threshold'";
      };
    };

    # Backlight control improvements for hybrid graphics (from nixos-hardware)
    boot.kernelParams = [
      "i915.enable_dpcd_backlight=1"
      "nvidia.NVreg_EnableBacklightHandler=0"
      "nvidia.NVReg_RegistryDwords=EnableBrightnessControl=0"
    ];

    # Enable SSD optimization
    services.fstrim.enable = lib.mkDefault true;
  };
}
