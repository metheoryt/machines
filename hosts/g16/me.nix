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
      "org/gnome/desktop/interface" = {
        scaling-factor = 1.25;
      };
    };
  };

  # The state version is required and should stay at the version you
  # originally installed.
  home.stateVersion = "25.05";
}
