# Root convergence trigger for the `machines` repo on NixOS (spec §1b).
#
# NixOS gets NO git post-merge hook (bootstrap skips core.hooksPath there to
# avoid racing home-manager), and an ExecStartPost on the pull service is a trap
# (runs as User=me, and fires only on the timer's own HEAD-advancing pull — it
# misses /ship's direct pull, the common case). So a path unit, decoupled from
# which process pulled, watches .git/ORIG_HEAD — rewritten by EVERY ff-pull —
# and starts a ROOT oneshot that runs converge.sh. Native root => nixos-rebuild
# has privilege, no polkit. self-update.nix stays a pure pull backend.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.machinesConverge;
in {
  options.services.machinesConverge = {
    enable = lib.mkEnableOption "root convergence on ff-pull of the machines repo";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "/home/me/machines";
      description = "Path to the machines checkout whose pulls trigger convergence.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Root oneshot: run converge.sh. converge.sh self-gates (primary worktree,
    # on main) and routes to nixos-rebuild switch --flake against the committed
    # lock. Runs as root (default) so the rebuild has privilege.
    systemd.services.machines-converge = {
      description = "Converge this box to the pulled machines state (root)";
      # converge.sh calls: git, nixos-rebuild, hostname, date, grep, bash.
      path = [pkgs.git pkgs.nixos-rebuild pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.nettools];
      serviceConfig = {
        Type = "oneshot";
        # nixos-rebuild needs a writable /nix, network, and the flake path.
        # GIT_CONFIG_*: root git over a repo owned by `me` otherwise aborts
        # every git call with "detected dubious ownership" (git >=2.35.2) —
        # inject safe.directory as ephemeral command-scope config, scoped to
        # this service only, instead of polluting root's global gitconfig.
        Environment = [
          "HOME=/root"
          "GIT_CONFIG_COUNT=1"
          "GIT_CONFIG_KEY_0=safe.directory"
          "GIT_CONFIG_VALUE_0=${cfg.repo}"
        ];
      };
      script = "${pkgs.bash}/bin/bash ${cfg.repo}/scripts/converge.sh";
    };

    # Path unit: fire the service whenever .git/ORIG_HEAD changes. PathChanged
    # (not PathModified) so it also catches the file's first creation. Git
    # rewrites ORIG_HEAD on every merge/ff-pull; an already-up-to-date pull skips
    # merge and does NOT rewrite it — correct (nothing to converge).
    systemd.paths.machines-converge = {
      description = "Fire convergence when the machines repo pulls (ORIG_HEAD changes)";
      wantedBy = ["paths.target"];
      pathConfig = {
        PathChanged = "${cfg.repo}/.git/ORIG_HEAD";
        Unit = "machines-converge.service";
      };
    };
  };
}
