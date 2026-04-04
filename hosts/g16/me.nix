{pkgs, ...}: {
  home.username = "me";
  home.homeDirectory = "/home/me";
  home.stateVersion = "25.05";

  # Core packages
  home.packages = with pkgs; [
    # Browsers
    firefox
    google-chrome

    # Communication
    telegram-desktop

    # Development tools
    jetbrains.pycharm
    windsurf
    zed-editor

    # Node.js for Claude Code and other tools
    nodejs_22

    # System utilities
    fastfetch

    # Office suite
    libreoffice-qt6-fresh

    # Remote access
    rustdesk

    # Additional utilities
    dconf-editor
    gnome-tweaks
    gnome-extension-manager

    # Media tools
    vlc
    gimp

    # Archive tools
    file-roller

    # Development fonts
    cascadia-code
    source-code-pro
  ];

  # Git configuration
  programs.git = {
    enable = true;

    settings = {
      user = {
        name = "Maxim Romanyuk";
        email = "metheoryt@gmail.com";
        signingkey = ""; # Add your GPG key if you use one
      };

      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      core.autocrlf = "input";
      merge.conflictstyle = "diff3";
      diff.tool = "vimdiff";

      alias = {
        st = "status";
        co = "checkout";
        br = "branch";
        up = "pull --rebase";
        ci = "commit";
        unstage = "reset HEAD --";
        last = "log -1 HEAD";
        visual = "!gitk";
        graph = "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit";
      };
    };
  };

  # Firefox configuration (minimal to avoid conflicts)
  programs.firefox.enable = true;

  # Fish shell configuration
  programs.fish = {
    enable = true;

    shellAliases = {
      ll = "ls -alF";
      la = "ls -A";
      l = "ls -CF";
      ".." = "cd ..";
      "..." = "cd ../..";
      grep = "grep --color=auto";
      fgrep = "fgrep --color=auto";
      egrep = "egrep --color=auto";

      # Git shortcuts
      gs = "git status";
      gd = "git diff";
      ga = "git add";
      gc = "git commit";
      gp = "git push";
      gl = "git pull";

      # NixOS specific
      nrs = "sudo nixos-rebuild switch --flake .#g16";
      nrt = "sudo nixos-rebuild test --flake .#g16";
      nrb = "sudo nixos-rebuild boot --flake .#g16";

      # Claude Code (installed via npm)
      cc = "claude";

      # System utilities
      df = "df -h";
      du = "du -h";
      free = "free -h";
      ps = "ps aux";
      top = "htop";
    };

    functions = {
      # Function to rebuild NixOS from anywhere
      rebuild = {
        description = "Rebuild NixOS configuration";
        body = ''
          set current_dir (pwd)
          cd ~/nix
          sudo nixos-rebuild switch --flake .#g16
          cd $current_dir
        '';
      };

      # Function to update flake
      update = {
        description = "Update NixOS flake";
        body = ''
          set current_dir (pwd)
          cd ~/nix
          nix flake update
          cd $current_dir
        '';
      };

      # Function to cleanup system
      cleanup = {
        description = "Cleanup NixOS system";
        body = ''
          sudo nix-collect-garbage -d
          sudo nixos-rebuild switch --flake ~/nix#g16
        '';
      };
    };

    interactiveShellInit = ''
      # Set greeting
      set fish_greeting "Welcome to NixOS on G16!"

      # Set editor
      set -x EDITOR vim

      # Add local bin to path
      fish_add_path ~/.local/bin

      # Set up direnv if available
      if command -v direnv >/dev/null
          direnv hook fish | source
      end

      # Set up npm global packages path
      fish_add_path ~/.npm-global/bin
    '';
  };

  # Bash configuration (fallback)
  programs.bash = {
    enable = true;
    enableCompletion = true;

    bashrcExtra = ''
      # Custom prompt
      PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

      # History settings
      HISTCONTROL=ignoreboth
      HISTSIZE=1000
      HISTFILESIZE=2000

      # Colored ls
      alias ls='ls --color=auto'
      alias grep='grep --color=auto'

      # Add npm global bin to PATH
      export PATH="$HOME/.npm-global/bin:$PATH"

      # Claude Code alias
      alias cc='claude'
    '';
  };

  # Starship prompt (works with both fish and bash)
  programs.starship = {
    enable = true;

    settings = {
      format = "$all$character";

      character = {
        success_symbol = "[➜](bold green)";
        error_symbol = "[➜](bold red)";
      };

      git_branch = {
        symbol = "🌱 ";
        truncation_length = 20;
      };

      git_status = {
        conflicted = "🏳";
        ahead = "🏎💨";
        behind = "😰";
        diverged = "😵";
        up_to_date = "✓";
        untracked = "🤷";
        stashed = "📦";
        modified = "📝";
        staged = "[++\($count\)](green)";
        renamed = "👅";
        deleted = "🗑";
      };

      nix_shell = {
        disabled = false;
        impure_msg = "[impure shell](bold red)";
        pure_msg = "[pure shell](bold green)";
        format = "via [☃️ $state( \($name\))](bold blue) ";
      };
    };
  };

  # Direnv integration
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Home Manager's dconf settings for GNOME
  dconf = {
    enable = true;
    settings = {
      # Enable fractional scaling
      "org/gnome/mutter" = {
        experimental-features = ["scale-monitor-framebuffer"];
      };

      # UI scaling and theme settings
      "org/gnome/desktop/interface" = {
        text-scaling-factor = 1;
        gtk-theme = "Adwaita";
        icon-theme = "Adwaita";
        cursor-theme = "Adwaita";
        font-name = "Noto Sans 11";
        document-font-name = "Noto Sans 11";
        monospace-font-name = "JetBrainsMono Nerd Font 10";
        show-battery-percentage = true;
        clock-show-weekday = true;
        clock-show-seconds = false;
      };

      # Window manager preferences
      "org/gnome/desktop/wm/preferences" = {
        button-layout = "appmenu:minimize,maximize,close";
        titlebar-font = "Noto Sans Bold 11";
        resize-with-right-button = true;
      };

      # Keyboard shortcuts
      "org/gnome/desktop/wm/keybindings" = {
        close = ["<Alt>F4"];
        toggle-fullscreen = ["F11"];
        switch-to-workspace-left = ["<Control><Alt>Left"];
        switch-to-workspace-right = ["<Control><Alt>Right"];
        move-to-workspace-left = ["<Control><Alt><Shift>Left"];
        move-to-workspace-right = ["<Control><Alt><Shift>Right"];
      };

      # Custom keybindings
      "org/gnome/settings-daemon/plugins/media-keys" = {
        custom-keybindings = [
          "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
        ];
      };

      "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
        binding = "<Control><Alt>t";
        command = "gnome-terminal";
        name = "Terminal";
      };

      # Privacy settings
      "org/gnome/desktop/privacy" = {
        disable-microphone = false;
        disable-camera = false;
        report-technical-problems = false;
      };

      # Power settings
      "org/gnome/settings-daemon/plugins/power" = {
        sleep-inactive-ac-type = "nothing";
        sleep-inactive-battery-type = "suspend";
        sleep-inactive-battery-timeout = 1800; # 30 minutes
      };

      # Nautilus (file manager) settings
      "org/gnome/nautilus/preferences" = {
        default-folder-viewer = "list-view";
        search-filter-time-type = "last_modified";
        show-hidden-files = false;
      };

      # Terminal settings
      "org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9" = {
        background-color = "rgb(23,20,33)";
        foreground-color = "rgb(208,207,204)";
        palette = ["rgb(23,20,33)" "rgb(192,28,40)" "rgb(38,162,105)" "rgb(162,115,76)" "rgb(18,72,139)" "rgb(163,71,186)" "rgb(42,161,179)" "rgb(208,207,204)" "rgb(94,92,100)" "rgb(246,97,81)" "rgb(51,218,122)" "rgb(233,173,12)" "rgb(42,123,222)" "rgb(192,97,203)" "rgb(51,199,222)" "rgb(255,255,255)"];
        use-theme-colors = false;
        font = "JetBrainsMono Nerd Font 10";
        use-system-font = false;
      };
    };
  };

  # XDG user directories (minimal to avoid conflicts)
  xdg.enable = true;

  # Enable Home Manager
  programs.home-manager.enable = true;
}
