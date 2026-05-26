{pkgs, ...}: {
  # Enable the X11 windowing system and Wayland
  services.xserver.enable = true;

  # GNOME Desktop Environment
  # Wayland is the only supported mode in GNOME 50+; the `wayland` option
  # was removed.
  services.displayManager.gdm.enable = true;

  services.desktopManager.gnome = {
    enable = true;
    extraGSettingsOverridePackages = [pkgs.mutter];
    extraGSettingsOverrides = ''
      [org.gnome.mutter]
      experimental-features=['scale-monitor-framebuffer']

      [org.gnome.desktop.interface]
      gtk-theme='Adwaita'
      icon-theme='Adwaita'
      cursor-theme='Adwaita'

      [org.gnome.desktop.wm.preferences]
      button-layout='appmenu:minimize,maximize,close'
    '';
  };

  # Essential GNOME services
  services.gnome.gnome-keyring.enable = true;
  services.udev.packages = with pkgs; [gnome-settings-daemon];

  # Configure keymap
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Audio with PipeWire
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };

  # XDG portals for better desktop integration
  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk
      xdg-desktop-portal-gnome
    ];
  };

  # Fonts
  fonts = {
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
      nerd-fonts.jetbrains-mono
      nerd-fonts.fira-code
      liberation_ttf
      dejavu_fonts
    ];

    fontconfig = {
      defaultFonts = {
        serif = ["Noto Serif"];
        sansSerif = ["Noto Sans"];
        monospace = ["JetBrainsMono Nerd Font"];
        emoji = ["Noto Color Emoji"];
      };
    };
  };

  # Remove unwanted GNOME applications
  environment.gnome.excludePackages = with pkgs; [
    epiphany # GNOME web browser
    geary # email client
    totem # video player
    tali # poker game
    iagno # go game
    hitori # sudoku game
    atomix # puzzle game
    yelp # help viewer
    gnome-contacts
    gnome-initial-setup
    gnome-maps
    gnome-music
    gnome-weather
    simple-scan
  ];

  # Additional desktop packages
  environment.systemPackages = with pkgs; [
    gnome-tweaks
    gnome-extension-manager
    dconf-editor
  ];
}
