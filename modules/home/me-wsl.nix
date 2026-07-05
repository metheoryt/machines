# Lean CLI home profile for the WSL host.
#
# Intentionally a separate, focused profile rather than modules/home/me.nix:
# me.nix is a full GUI workstation (Chrome, PyCharm, LibreOffice, GNOME dconf,
# ghostty, rustdesk, …), almost none of which belongs in WSL. This keeps the
# closure small and the config free of dead desktop settings, while still
# carrying the crown jewels — the version-controlled Claude Code / Codex config
# (claude.nix + codex.nix) that "sync from the laptop" was really about — plus
# the portable git / fish / starship / direnv shell and the gortex daemon.
#
# The portable blocks below are kept faithful to me.nix so behaviour matches;
# if they drift, consider extracting a shared modules/home/cli.nix that both
# import.
{
  pkgs,
  config,
  hostname,
  ...
}: let
  # Same derivation as the system package (modules/programs/development.nix);
  # referenced here for the daemon service's ExecStart store path.
  gortex = pkgs.callPackage ../../pkgs/gortex.nix {};
in {
  imports = [
    # Claude Code config: version-controlled in agents/, symlinked into ~/.claude
    ./claude.nix
    # Codex config: shares agents/ content, symlinked into ~/.codex
    ./codex.nix
  ];

  home.username = "me";
  home.homeDirectory = "/home/me";
  home.stateVersion = "25.05";

  home.packages = with pkgs; [
    claude-code
    codex # OpenAI Codex CLI (config synced via codex.nix)
    difftastic # structural diff tool — `difft`, also wired as `git dft`
    sox # for claude /voice audio recording
  ];

  # delta: syntax-highlighting pager for git diff/show/log/blame.
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      navigate = true;
      line-numbers = true;
      side-by-side = true;
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
      # HTTPS auth to github.com via the gh CLI's stored token.
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
      # work repo's project-scope .claude/settings.local.json (gitignored).
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

  # gortex code-intelligence daemon — holds the shared graph index that the MCP
  # clients (Claude Code etc.) and the CLI query. sqlite backend persists to
  # ~/.gortex so warm restarts skip re-indexing.
  systemd.user.services.gortex-daemon = {
    Unit = {
      Description = "gortex code-intelligence daemon";
      After = ["default.target"];
    };
    Service = {
      Type = "forking";
      ExecStart = "${gortex}/bin/gortex daemon start --no-progress";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = ["default.target"];
  };

  programs.home-manager.enable = true;
}
