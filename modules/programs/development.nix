{pkgs, ...}: {
  # Enable nix-ld for compatibility with dynamically linked executables
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      # Standard C and C++ libraries
      stdenv.cc.cc.lib
      glibc
      libgcc

      # Common system libraries that compiled Python packages might need
      zlib
      openssl
      libffi
      bzip2
      xz
      ncurses
      readline
      sqlite

      # Graphics and system libraries
      libGL
      libGLU
      freetype
      fontconfig

      # Additional libraries for scientific computing
      openblas
      lapack

      # X11 libraries
      libx11
      libxext
      libxrender
      libxtst
    ];
  };

  # Development tools and environments
  environment.systemPackages = with pkgs; [
    # Version control
    git
    git-lfs
    gh # GitHub CLI

    # Text editors and IDEs
    vim
    neovim

    # Development utilities
    curl
    wget
    jq
    yq

    # Build tools
    gnumake
    cmake
    pkg-config

    # Debugging and profiling
    gdb
    valgrind
    strace
    ltrace

    # Network tools
    netcat
    nmap
    tcpdump
    wireshark

    # Container tools
    docker-compose

    # Language servers and formatters
    nixd
    alejandra

    # Database tools
    sqlite
    postgresql

    # File utilities
    fd
    ripgrep
    bat
    eza
    fzf

    # System monitoring
    htop
    btop
    iotop

    # Archive tools
    unzip
    zip
    p7zip
    gnutar

    # Development libraries
    openssl
    zlib
    libxml2
    libxslt

    # Python development environment
    python313
    python313Packages.pip
    python313Packages.virtualenv
    python313Packages.python-lsp-server
    uv # Fast Python package manager
  ];

  # Docker support
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # Podman as Docker alternative (disabled to avoid conflict with Docker)
  # virtualisation.podman = {
  #   enable = true;
  #   dockerCompat = true;
  #   defaultNetwork.settings.dns_enabled = true;
  # };

  # Enable AppImage support
  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  # Direnv for project-specific environments
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Shell improvements
  programs.fish.enable = true;
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
  };

  # Git configuration
  programs.git = {
    enable = true;
    config = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      core.autocrlf = "input";
      merge.conflictstyle = "diff3";
    };
  };

  # Development fonts
  fonts.packages = with pkgs; [
    nerd-fonts.fira-code
    nerd-fonts.jetbrains-mono
    nerd-fonts.hack
    fira-code
    fira-code-symbols
  ];

  # Environment variables for development
  environment.variables = {
    EDITOR = "vim";
    PAGER = "less";
    BROWSER = "google-chrome-stable";
    TERMINAL = "gnome-terminal";
  };

  # User groups for development
  users.groups.docker = {};

  # Development services (commented out by default - enable per project needs)
  services = {
    ollama = {
      enable = true;
      package = pkgs.ollama-cuda;
      host = "127.0.0.1"; # change to "0.0.0.0" only if you know the risks
    };
    open-webui = {
      enable = true;
      port = 3001;
      # Optional extra env; Open WebUI already detects local Ollama.
      environment = {
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";
      };
    };

    #   # PostgreSQL for development
    #   postgresql = {
    #     enable = true;
    #     package = pkgs.postgresql_15;
    #     enableTCPIP = true;
    #     authentication = pkgs.lib.mkOverride 10 ''
    #       local all all trust
    #       host all all 127.0.0.1/32 trust
    #       host all all ::1/128 trust
    #     '';
    #   };

    #   # Redis for development
    #   redis.servers.development = {
    #     enable = true;
    #     port = 6379;
    #   };
  };
}
