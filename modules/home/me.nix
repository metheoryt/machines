{
  pkgs,
  config,
  hostname,
  ...
}: let
  # Upstream 1.4.7 Flutter build, repackaged from the official .deb because
  # nixpkgs lags (rustdesk-flutter 1.4.5). Already wraps in WAYLAND_DISPLAY="".
  rustdesk = pkgs.callPackage ./rustdesk-bin.nix {};
  # Upstream Zed, repackaged from the official tarball (nixpkgs lags at 1.3.6).
  zed-bin = pkgs.callPackage ./zed-bin.nix {};
  # nixpkgs jetbrains.pycharm bumped to latest upstream (it's the same tarball).
  pycharm = pkgs.callPackage ./pycharm-bin.nix {};
  # Same derivation as the system package (modules/programs/development.nix);
  # referenced here for the daemon service's ExecStart store path.
  gortex = pkgs.callPackage ../../pkgs/gortex.nix {};
in {
  imports = [
    # Claude Code config: version-controlled in claude/, symlinked into ~/.claude
    ./claude.nix
    # Codex config: shares claude/ content, codex/-specific files, symlinked into ~/.codex
    ./codex.nix
    # RustDesk: seed self-hosted server + known peers (seed-only, see module)
    ./rustdesk-config.nix
  ];

  home.username = "me";
  home.homeDirectory = "/home/me";
  home.stateVersion = "25.05";

  home.packages = with pkgs; [
    # Browsers
    google-chrome

    # Communication
    telegram-desktop

    # Development tools
    pycharm # upstream-latest override — see ./pycharm-bin.nix (nixpkgs lags)
    claude-code
    codex # OpenAI Codex CLI (config synced via codex.nix); attr unverified on Windows — confirm with `just check` on a Nix host
    sox # for claude /voice audio recording
    difftastic # structural diff tool — `difft`, also wired as `git dft`

    # Office suite
    libreoffice-qt6-fresh

    # Remote access
    remmina
    moonlight-qt

    # Remote access — see ./rustdesk-bin.nix (upstream 1.4.7, WAYLAND_DISPLAY="" baked in)
    rustdesk

    # VPN
    proton-vpn # free tier for occasional geo-unblocking

    (pkgs.symlinkJoin {
      name = "amnezia-vpn-wrapped";
      paths = [pkgs.amnezia-vpn];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        wrapProgram $out/bin/AmneziaVPN \
          --prefix XDG_DATA_DIRS : "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}"
      '';
    })

    # Additional utilities
    dconf-editor
    gnome-tweaks
    gnome-extension-manager

    # Media tools
    vlc
    gimp

    # cameractrls — nixpkgs ships only the CLI; override to also install the
    # GTK GUI (cameractrlsgtk) plus desktop entry & icon, wrapped with the
    # GTK3 typelib path so `import gi; gi.require_version('Gtk', '3.0')` works.
    (pkgs.cameractrls.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.makeWrapper];
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin $out/lib/python3.13/site-packages/CameraCtrls
        for file in cameractrls cameractrlsd cameractrlsgtk cameraptzgame cameraptzmidi cameraptzspnav cameraview; do
          install -Dm755 $file.py -t $out/lib/python3.13/site-packages/CameraCtrls
        done
        for file in cameractrls cameractrlsd cameraptzgame cameraptzmidi cameraptzspnav cameraview; do
          ln -s $out/lib/python3.13/site-packages/CameraCtrls/$file.py $out/bin/$file
        done
        makeWrapper ${pkgs.python3.withPackages (ps: [ps.pygobject3])}/bin/python3 $out/bin/cameractrlsgtk \
          --add-flags $out/lib/python3.13/site-packages/CameraCtrls/cameractrlsgtk.py \
          --prefix GI_TYPELIB_PATH : "${pkgs.gtk3}/lib/girepository-1.0:${pkgs.glib}/lib/girepository-1.0:${pkgs.pango.out}/lib/girepository-1.0:${pkgs.gdk-pixbuf}/lib/girepository-1.0:${pkgs.harfbuzz}/lib/girepository-1.0:${pkgs.atk}/lib/girepository-1.0"
        install -Dm644 pkg/hu.irl.cameractrls.desktop $out/share/applications/hu.irl.cameractrls.desktop
        substituteInPlace $out/share/applications/hu.irl.cameractrls.desktop \
          --replace-fail 'Exec=cameractrlsgtk.py' 'Exec=cameractrlsgtk'
        install -Dm644 pkg/hu.irl.cameractrls.svg $out/share/icons/hicolor/scalable/apps/hu.irl.cameractrls.svg
        runHook postInstall
      '';
    }))

    # Archive tools
    file-roller

    # Terminal
    ghostty
  ];

  # delta: syntax-highlighting pager for git diff/show/log/blame.
  # enableGitIntegration wires it up as core.pager + interactive.diffFilter.
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      navigate = true; # n/N to jump between files/hunks
      line-numbers = true;
      side-by-side = true;
      # follow ghostty's dark:Dracula / light:GitHub theme split
      syntax-theme = "Dracula";
    };
  };

  programs.git = {
    enable = true;

    settings = {
      user = {
        name = "Maxim Romanyuk";
        email = "metheoryt@gmail.com";
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      core.autocrlf = "input";
      merge.conflictstyle = "diff3";
      # difftastic: structural (AST-aware) diffs, on demand via `git dft`.
      diff.tool = "difftastic";
      difftool.prompt = false;
      difftool.difftastic.cmd = "${pkgs.difftastic}/bin/difft \"$LOCAL\" \"$REMOTE\"";
      # HTTPS auth to github.com via the gh CLI's stored token
      # (requires the token to be SAML-SSO authorized for any private orgs).
      credential."https://github.com".helper = "!gh auth git-credential";
      credential."https://gist.github.com".helper = "!gh auth git-credential";
      alias = {
        st = "status";
        co = "checkout";
        br = "branch";
        up = "pull --rebase";
        ci = "commit";
        unstage = "reset HEAD --";
        last = "log -1 HEAD";
        dft = "difftool";
        graph = "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit";
      };
    };
  };

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

      gs = "git status";
      gd = "git diff";
      ga = "git add";
      gc = "git commit";
      gp = "git push";
      gl = "git pull";

      nrs = "sudo nixos-rebuild switch --flake .#${hostname}";
      nrt = "sudo nixos-rebuild test --flake .#${hostname}";
      nrb = "sudo nixos-rebuild boot --flake .#${hostname}";

      cc = "claude";
      # Work profile. The Sentry secret is NOT delivered here — it lives in each
      # work repo's project-scope .claude/settings.local.json (gitignored), which
      # Claude reads natively. (A config-dir-root settings.local.json is NOT read.)
      ccw = "CLAUDE_CONFIG_DIR=~/.claude-work claude";

      df = "df -h";
      du = "du -h";
      free = "free -h";
      ps = "ps aux";
      top = "htop";
    };

    functions = {
      rebuild = {
        description = "Rebuild NixOS configuration";
        body = ''
          set current_dir (pwd)
          cd ~/nix
          sudo nixos-rebuild switch --flake .#${hostname}
          cd $current_dir
        '';
      };
      update = {
        description = "Update NixOS flake";
        body = ''
          set current_dir (pwd)
          cd ~/nix
          nix flake update
          cd $current_dir
        '';
      };
      cleanup = {
        description = "Cleanup NixOS system";
        body = ''
          sudo nix-collect-garbage -d
          sudo nixos-rebuild switch --flake ~/nix#${hostname}
        '';
      };
    };

    interactiveShellInit = ''
      set fish_greeting ""
      set -x EDITOR nvim
      fish_add_path ~/.local/bin
      if command -v direnv >/dev/null
          direnv hook fish | source
      end
      fastfetch
      printf '\n\033[1;35m Ghostty\033[0m\n'
      printf '\033[90m tabs   \033[0m new \033[1mC-S-t\033[0m  close \033[1mC-w\033[0m  next \033[1mC-Tab\033[0m  prev \033[1mC-S-Tab\033[0m\n'
      printf '\033[90m splits \033[0m new \033[1mC-S-o\033[0m / \033[1mC-S-e\033[0m  focus \033[1mC-A-↑↓←→\033[0m  zoom \033[1mC-S-Enter\033[0m\n'
      printf '\033[90m window \033[0m new \033[1mC-S-n\033[0m\n'
      printf '\033[90m text   \033[0m copy \033[1mC-S-c\033[0m  paste \033[1mC-S-v\033[0m  font \033[1mC-+\033[0m / \033[1mC--\033[0m / \033[1mC-0\033[0m\n'
      printf '\033[90m scroll \033[0m \033[1mS-PgUp\033[0m / \033[1mS-PgDn\033[0m\n\n'
    '';
  };

  programs.bash = {
    enable = true;
    enableCompletion = true;
    bashrcExtra = ''
      PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
      HISTCONTROL=ignoreboth
      HISTSIZE=1000
      HISTFILESIZE=2000
      alias ls='ls --color=auto'
      alias grep='grep --color=auto'
      alias cc='claude'
    '';
  };

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

  programs.fastfetch = {
    enable = true;
    settings = {
      logo.source = "nixos_small";
      modules = [
        "title"
        "separator"
        "os"
        "kernel"
        "shell"
        "cpu"
        "memory"
        "uptime"
      ];
    };
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.ghostty = {
    enable = true;
    settings = {
      font-family = "JetBrainsMono Nerd Font";
      font-size = 10;
      shell-integration = "fish";
      theme = "Belafonte Day";
      quit-after-last-window-closed = true;
      desktop-notifications = false;
      gtk-titlebar = false;
      keybind = [
        "ctrl+w=close_tab"
        "alt+shift+left=goto_split:left"
        "alt+shift+right=goto_split:right"
        "alt+shift+up=goto_split:up"
        "alt+shift+down=goto_split:down"
      ];
    };
  };

  dconf = {
    enable = true;
    settings = {
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
      "org/gnome/desktop/wm/preferences" = {
        button-layout = "appmenu:minimize,maximize,close";
        titlebar-font = "Noto Sans Bold 11";
        resize-with-right-button = true;
      };
      "org/gnome/desktop/wm/keybindings" = {
        close = ["<Alt>F4"];
        toggle-fullscreen = ["F11"];
        switch-to-workspace-left = ["<Control><Alt>Left"];
        switch-to-workspace-right = ["<Control><Alt>Right"];
        move-to-workspace-left = ["<Control><Alt><Shift>Left"];
        move-to-workspace-right = ["<Control><Alt><Shift>Right"];
      };
      "org/gnome/settings-daemon/plugins/media-keys" = {
        custom-keybindings = [
          "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
        ];
      };
      "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
        binding = "<Control><Alt>t";
        command = "ghostty";
        name = "Terminal";
      };
      "org/gnome/desktop/privacy" = {
        disable-microphone = false;
        disable-camera = false;
        report-technical-problems = false;
      };
      "org/gnome/settings-daemon/plugins/power" = {
        sleep-inactive-ac-type = "nothing";
        sleep-inactive-battery-type = "suspend";
        sleep-inactive-battery-timeout = 1800;
      };
      "org/gnome/nautilus/preferences" = {
        default-folder-viewer = "list-view";
        search-filter-time-type = "last_modified";
        show-hidden-files = false;
      };
    };
  };

  xdg.enable = true;

  xdg.desktopEntries.rustdesk = {
    name = "RustDesk";
    exec = "${rustdesk}/bin/rustdesk %U";
    icon = "rustdesk";
    terminal = false;
    categories = [
      "Network"
      "RemoteAccess"
    ];
  };

  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    setSessionVariables = true;
    desktop = "${config.home.homeDirectory}/Desktop";
    download = "${config.home.homeDirectory}/Downloads";
    templates = "${config.home.homeDirectory}/Templates";
    publicShare = "${config.home.homeDirectory}/Public";
    documents = "${config.home.homeDirectory}/Documents";
    music = "${config.home.homeDirectory}/Music";
    pictures = "${config.home.homeDirectory}/Pictures";
    videos = "${config.home.homeDirectory}/Videos";
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = "google-chrome.desktop";
      "x-scheme-handler/http" = "google-chrome.desktop";
      "x-scheme-handler/https" = "google-chrome.desktop";
      "x-scheme-handler/about" = "google-chrome.desktop";
      "x-scheme-handler/unknown" = "google-chrome.desktop";
      "x-scheme-handler/tg" = "org.telegram.desktop.desktop";
      "x-scheme-handler/tonsite" = "org.telegram.desktop.desktop";
    };
    associations.added = {
      "x-scheme-handler/tg" = "org.telegram.desktop.desktop";
      "x-scheme-handler/tonsite" = "org.telegram.desktop.desktop";
    };
  };

  programs.zed-editor = {
    enable = true;
    # Upstream prebuilt — see ./zed-bin.nix. nixpkgs zed-editor lags.
    package = zed-bin;
    userSettings = {
      # Auto-update is compiled into the upstream binary; the Nix store is
      # read-only and we manage versions via `just update-zed`, so disable it.
      auto_update = false;
      agent = {
        default_model = {
          provider = "anthropic";
          model = "claude-sonnet-4-6-latest";
          enable_thinking = false;
        };
        favorite_models = [];
        model_parameters = [];
      };
      agent_servers."claude-acp".type = "registry";
      ui_font_size = 16;
      buffer_font_size = 15;
      theme = {
        mode = "system";
        light = "One Light";
        dark = "One Dark";
      };
    };
  };

  # gortex code-intelligence daemon — holds the shared graph index that the
  # MCP clients (Claude Code etc.) and the CLI query. Runs in the foreground
  # under systemd; the sqlite backend persists to ~/.gortex so warm restarts
  # skip re-indexing tracked repos.
  systemd.user.services.gortex-daemon = {
    Unit = {
      Description = "gortex code-intelligence daemon";
      After = ["default.target"];
    };
    Service = {
      # `gortex daemon start` spawns the daemon and the launcher exits, so the
      # supervisor must treat it as forking (Type=simple would tear the daemon
      # down when the launcher exits).
      Type = "forking";
      ExecStart = "${gortex}/bin/gortex daemon start --no-progress";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = ["default.target"];
  };

  programs.home-manager.enable = true;
}
