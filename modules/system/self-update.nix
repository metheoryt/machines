# Periodic `git merge --ff-only` of this flake repo, so the machines keep
# themselves current without a manual pull.
#
# AUTO-PULL ONLY — deliberately does NOT run `nixos-rebuild`. Because the Claude
# config under claude/ is symlinked into ~/.claude (see modules/home/claude.nix),
# a pull makes config + memory edits go live immediately with no rebuild. Changes
# to system .nix modules just land on disk; actual convergence (nixos-rebuild) is
# fired separately by `services.machinesConverge`
# (modules/system/machines-converge.nix) via a root path unit watching
# .git/ORIG_HEAD, so this service stays a pure pull backend. (A new claude/
# hook/skill file is linked at that switch too — on NixOS the git-hook
# auto-relink in claude/git-hooks/ is intentionally a no-op.)
#
# Safety: runs as the repo owner (not root), only on the configured branch, only
# when the working tree is clean (never clobbers WIP), and skips + logs on a
# diverged (non-fast-forward) upstream rather than leaving the tree mid-merge.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nixRepoAutoPull;
in {
  options.services.nixRepoAutoPull = {
    enable = lib.mkEnableOption "periodic git merge --ff-only of the flake repo checkout";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "/home/me/machines";
      description = "Path to the flake repo checkout to keep updated.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "me";
      description = "User that owns the repo; its git/ssh config is used for the pull.";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Only auto-update when this branch is checked out (feature branches are left alone).";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "*:0/5";
      description = "systemd OnCalendar expression controlling how often a pull is attempted (default: every 5 min).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nix-repo-auto-pull = {
      description = "Merge --ff-only the flake repo (Claude config + memory go live via symlinks)";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # coreutils for `sleep` in the fetch retry — bash has no builtin, and a
      # system unit gets no ambient /run/current-system/sw/bin.
      path = [pkgs.git pkgs.openssh pkgs.coreutils];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        # git needs HOME to find its config and the SSH key / known_hosts used to
        # reach the remote non-interactively.
        Environment = ["HOME=/home/${cfg.user}"];
      };
      script = let
        repo = lib.escapeShellArg cfg.repo;
        branch = lib.escapeShellArg cfg.branch;
      in ''
        set -u
        cd ${repo} || exit 0

        # Only the configured branch, and only a clean tree — never touch WIP.
        cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
        [ "$cur" = ${branch} ] || { echo "on branch '$cur', not ${branch} — skipping"; exit 0; }
        git update-index -q --refresh || true
        if ! git diff --quiet || ! git diff --cached --quiet; then
          echo "working tree dirty — skipping auto-pull"; exit 0
        fi

        # A failed fetch is an ERROR, not a no-op. This used to `exit 0`, so an
        # unusable credential looked identical to "already up to date": the unit
        # logged `Permission denied (publickey)` and systemd still reported
        # "Finished successfully". latitude sat 23 commits behind for hours that
        # way, invisible to `systemctl status` — the only trace was journalctl.
        #
        # Retry once before failing, because one specific failure here is benign
        # and RECURRING: git-autofetch fetches the same repos on *:00/10:00 while
        # this unit runs on *:00/5:00, so they collide at :00/:20/:40 and the
        # loser dies with
        #   cannot lock ref 'refs/remotes/origin/main': is at X but expected Y
        # Observed live 2026-07-28 — both units started at the same second. That
        # race is self-correcting (the other fetch is updating the very ref we
        # want), so failing on it would mark the unit failed 3x/hour and train
        # you to ignore the status this change exists to make meaningful.
        if ! git fetch --quiet 2>/dev/null; then
          sleep 10
          if ! git fetch --quiet; then
            echo "fetch failed twice — remote unreachable (credential or network)" >&2
            exit 1
          fi
        fi
        git rev-parse '@{u}' >/dev/null 2>&1 || { echo "no upstream for ${branch} — skipping"; exit 0; }

        head_rev=$(git rev-parse HEAD)
        up_rev=$(git rev-parse '@{u}')
        [ "$head_rev" = "$up_rev" ] && exit 0

        if git merge --ff-only --quiet '@{u}'; then
          echo "auto-pulled ${repo}: $head_rev -> $(git rev-parse HEAD)"
        else
          echo "diverged (non-ff) in ${repo} — skipping, resolve manually" >&2
          exit 1
        fi
      '';
    };

    systemd.timers.nix-repo-auto-pull = {
      description = "Periodic flake repo auto-pull";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true; # catch up after the machine was off
        RandomizedDelaySec = "30s"; # small spread; must stay well under the interval
      };
    };
  };
}
