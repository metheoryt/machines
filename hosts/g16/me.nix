{ config, pkgs, ... }:

{    
  home.username = "me";
  home.homeDirectory = "/home/me";
  home.packages = with pkgs; [
    fish
    git
    brave
    telegram-desktop
    jetbrains.pycharm-professional
    windsurf
    fastfetch
    uv
    libreoffice-qt6-fresh
    sublime4-dev
  ];
  programs.git.enable = true;
  programs.git.userName = "Maxim Romanyuk";
  programs.git.userEmail = "metheoryt@gmail.com";
  programs.home-manager.enable = true;
  programs.firefox.enable = true;
  programs.fish.enable = true;

  # set custom UI scaling
  dconf = {
    enable = true;
    settings = {
      "org/gnome/mutter" = { experimental-features = [ "scale-monitor-framebuffer" ]; };
      "org/gnome/desktop/interface" = {
        text-scaling-factor = 1.15;
      };
    };
  };

  # The state version is required and should stay at the version you
  # originally installed.
  home.stateVersion = "25.05";
}
