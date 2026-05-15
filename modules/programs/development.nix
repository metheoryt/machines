{ pkgs, ... }:
{
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

      ### PURE
      #
      # kan-kan repo
      # Geospatial stack (Django GIS via ctypes: GDAL/GEOS/PROJ)
      gdal
      geos
      proj
      # Media / text processing
      libmediainfo
      file # libmagic (python-magic)
      glib # libgthread / libglib (opencv-python)
      libxcb
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
    nil
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

    # PURE org programs
    slack
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
    EDITOR = "nvim";
    PAGER = "less";
    BROWSER = "google-chrome-stable";
    TERMINAL = "ghostty";
  };

  # User groups for development
  users.groups.docker = { };

}
