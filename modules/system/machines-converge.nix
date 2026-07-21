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
        Environment = ["HOME=/root"];
        # Root running git/nixos-rebuild over a repo owned by `me` aborts on
        # ownership: the git CLI says "detected dubious ownership" (git
        # >=2.35.2), and Nix's flake fetcher fails with libgit2 error 7
        # ("repository path is not owned by current user"). The git CLI honours
        # GIT_CONFIG_* env, but libgit2 does NOT — it only reads real git config
        # files. So mark the repo safe in root's GLOBAL gitconfig (HOME=/root =>
        # /root/.gitconfig), which BOTH the git CLI and libgit2 consult.
        # --replace-all keeps it idempotent (no duplicate lines across runs).
        ExecStartPre = "${pkgs.git}/bin/git config --global --replace-all safe.directory ${cfg.repo}";
      };
      script = "${pkgs.bash}/bin/bash ${cfg.repo}/scripts/converge.sh";
    };

    # Path unit: fire the service whenever the repo's HEAD advances. We watch
    # .git/logs/HEAD (the HEAD reflog), NOT .git/ORIG_HEAD, for two reasons:
    #   1. Coverage: ORIG_HEAD is written by `git merge`/`reset`/`rebase`, but a
    #      plain fast-forward `git pull` (the fleet's common path, --ff-only
    #      everywhere) does NOT reliably rewrite it — so ORIG_HEAD silently
    #      misses real advances. logs/HEAD is APPENDED on every HEAD movement,
    #      fast-forward included, so it can't miss a pull that moved HEAD.
    #   2. Robustness: git updates ORIG_HEAD by atomic rename-replace (write
    #      .lock, rename over the file), which swaps the inode and lets
    #      systemd's inotify watch go stale after the first event — the observed
    #      "first pull fires, second is missed" failure. logs/HEAD is appended
    #      in place (stable inode), so the watch survives repeated events.
    # PathChanged fires on IN_CLOSE_WRITE, which git's append-and-close on
    # logs/HEAD produces, and also catches the file's first creation.
    # A refs-only `git fetch` (the git-autofetch timer) does NOT move HEAD, so it
    # never appends here — no spurious fires. converge.sh's own git calls
    # (rev-parse/diff/ls-files) don't move HEAD either, so no self-retrigger.
    # A no-op fire is harmless regardless: converge.sh's range is
    # converged-rev..HEAD, so an empty diff skips the rebuild.
    systemd.paths.machines-converge = {
      description = "Fire convergence when the machines repo's HEAD advances (reflog append)";
      wantedBy = ["paths.target"];
      pathConfig = {
        PathChanged = "${cfg.repo}/.git/logs/HEAD";
        Unit = "machines-converge.service";
      };
    };
  };
}
