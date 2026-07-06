# Periodic `git fetch` of every git repo under the configured roots, so an agent
# (or you) can see "behind by N" from `git status` / the shell prompt without
# having to fetch first.
#
# FETCH ONLY — deliberately never runs pull/merge/rebase and never touches a
# working tree or local branch. It only refreshes remote-tracking refs, so the
# ahead/behind counts shown by git are accurate within one interval. The actual
# pull is left to you / the agent, done deliberately when the tree is safe.
# (For the flake repo itself, services.nixRepoAutoPull additionally fast-forwards
# it via rebase — see modules/system/self-update.nix. The two are complementary.)
#
# Safety: runs as the repo owner (not root), never blocks on a credential or host
# prompt (BatchMode + GIT_TERMINAL_PROMPT=0), and times out per-repo so one
# unreachable remote can't wedge the run.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.gitAutoFetch;
in {
  options.services.gitAutoFetch = {
    enable = lib.mkEnableOption "periodic git fetch of all repos under the configured roots";

    user = lib.mkOption {
      type = lib.types.str;
      default = "me";
      description = "User that owns the repos; its git/ssh config is used for the fetch.";
    };

    roots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["/home/me"];
      description = "Directories scanned (up to maxDepth) for git repos to fetch.";
    };

    maxDepth = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "How deep under each root to look for a .git entry.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "*:0/10";
      description = "systemd OnCalendar expression controlling fetch frequency (default: every 10 min).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.git-auto-fetch = {
      description = "Fetch all git repos under the configured roots (refs only, no pull)";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      path = [pkgs.git pkgs.openssh pkgs.coreutils pkgs.findutils];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Environment = [
          "HOME=/home/${cfg.user}"
          # Never block on an auth prompt — skip repos we can't reach silently.
          "GIT_TERMINAL_PROMPT=0"
          "GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=10"
        ];
      };
      script = let
        depth = toString cfg.maxDepth;
        roots = lib.escapeShellArgs cfg.roots;
      in ''
        set -u
        for root in ${roots}; do
          [ -d "$root" ] || continue
          # -prune stops find from descending into a repo's own .git; skip the
          # usual heavy vendored trees. Match .git as dir (normal repo) or file
          # (submodule / linked worktree) — `git -C <parent> fetch` works for both.
          find "$root" -maxdepth ${depth} \
            \( -path '*/node_modules' -o -path '*/.cache' -o -name '.direnv' \) -prune -o \
            -name .git -prune -print 2>/dev/null \
          | while IFS= read -r gitentry; do
            repo=$(dirname "$gitentry")
            if timeout 60 git -C "$repo" fetch --all --prune --quiet 2>/dev/null; then
              :
            else
              echo "fetch failed/skipped: $repo" >&2
            fi
          done
        done
      '';
    };

    systemd.timers.git-auto-fetch = {
      description = "Periodic git fetch of all repos under the configured roots";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true; # catch up after the machine was off
        RandomizedDelaySec = "30s"; # small spread; must stay well under the interval
      };
    };
  };
}
