# Periodic fast-forward of every personal fleet-sync repo on this box, by running
# the SAME provision/fleet-selfpull.sh the non-Nix members use. Replaces the
# NixOS-only nix-repo-auto-pull (modules/system/self-update.nix, removed): one
# auto-pull mechanism fleet-wide instead of two implementations to keep in step.
#
# PULL ONLY — deliberately does NOT run `nixos-rebuild`. Convergence is fired
# separately by services.machinesConverge (modules/system/machines-converge.nix),
# whose path unit watches .git/logs/HEAD. That works no matter who moved HEAD, so
# this service stays a pure pull backend. (On non-Nix boxes the repo's post-merge
# hook fires converge instead; NixOS has no such hook by design.)
#
# Two properties differ from the module this replaces, both deliberate:
#
#   1. It pulls EVERY fleet-sync repo under the scan roots (~, ~/my, ~/cyphy671,
#      …), not just the flake checkout. Work repos (thepureapp/) are excluded by
#      the script. So ~/my/vps keeps itself current here too.
#   2. The script is read from the WORKING TREE, not baked into /nix/store. That
#      is what makes it the same code as the rest of the fleet, but it also means
#      a bad commit to fleet-selfpull.sh can break self-updating on every box at
#      once — where the old inline script stayed frozen in the running generation
#      until the next rebuild. provision/fleet-selfpull.test.sh is the guard;
#      keep it meaningful.
#
# Safety: runs as the repo owner (not root); the script itself gates on branch
# main and a clean tree, skips a diverged upstream, and exits non-zero only for a
# real error (unreachable remote / bad credential) so systemd surfaces it.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.fleetSelfpull;
in {
  options.services.fleetSelfpull = {
    enable = lib.mkEnableOption "periodic fast-forward of the personal fleet-sync repos via provision/fleet-selfpull.sh";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "/home/me/machines";
      description = "Path to the machines checkout that provides provision/fleet-selfpull.sh.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "me";
      description = "User that owns the repos; its git/ssh config is used for the pull.";
    };

    roots = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Space-separated scan roots, passed as FLEET_ROOTS. Empty means the
        script's own default ($HOME $HOME/my $HOME/pure $HOME/cyphy671
        $HOME/exactly), which is what keeps this box consistent with the others.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "*:03/10";
      description = ''
        systemd OnCalendar controlling how often a pull is attempted. Defaults to
        every 10 min OFFSET BY 3 (:03, :13, :23 …) so it never lands on
        git-autofetch's *:00/10:00 boundary. Sharing that boundary made two
        concurrent fetches of the same repo collide, and the loser died with
        "cannot lock ref 'refs/remotes/origin/main'" — observed on latitude
        2026-07-28, both units starting in the same second. The script also
        retries once, so this offset is defence in depth rather than the only fix.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.fleet-selfpull = {
      description = "Fast-forward the personal fleet-sync repos (pull only; converge fires separately)";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # bash: the script is bash, not sh. coreutils: `sleep` in the fetch retry —
      # a system unit gets no ambient /run/current-system/sw/bin.
      path = [pkgs.git pkgs.openssh pkgs.bash pkgs.coreutils];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        # git needs HOME to find its config and the SSH key used to reach the
        # remote non-interactively.
        Environment =
          ["HOME=/home/${cfg.user}"]
          ++ lib.optional (cfg.roots != "") "FLEET_ROOTS=${cfg.roots}";
      };
      # Invoked THROUGH bash, never exec'd directly: provision/fleet-selfpull.sh
      # is committed mode 644 and carries no executable bit, because the Windows
      # members clone it onto NTFS where the mode bit does not survive. Every
      # other scheduler (launchd / systemd-user / cron in provision/lib/tiers.sh)
      # therefore spells it `/usr/bin/env bash <script>`. Exec'ing it directly
      # fails with 126 "Permission denied" — observed on latitude 2026-07-28,
      # this unit's first real run.
      script = ''
        exec ${pkgs.bash}/bin/bash ${lib.escapeShellArg "${cfg.repo}/provision/fleet-selfpull.sh"}
      '';
    };

    systemd.timers.fleet-selfpull = {
      description = "Periodic fleet-sync repo fast-forward";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true; # catch up after the machine was off
        RandomizedDelaySec = "30s"; # small spread; must stay well under the interval
      };
    };
  };
}
