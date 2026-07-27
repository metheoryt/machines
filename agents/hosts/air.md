# Host: air

<!--
Per-host memory + instructions for this machine. Symlinked to
~/.claude/host-memory.md and imported by ~/.claude/CLAUDE.md, so it loads ONLY
when the hostname matches. Tracked in git, synced everywhere, inert on other
hosts. Do NOT put secrets here.
-->

## Notes

- This is `air` — the MacBook Air M5 (Apple Silicon, arm64), platform `darwin`,
  tailnet `100.64.0.7`. Becoming the primary to-go dev machine in the 2026-07
  fleet migration; repos live locally here.
- Tool install is Homebrew via `provision/macos.sh`, NOT apt — this box has no
  Nix and no home-manager. `agents/bootstrap.sh` runs directly (it branches on
  `uname -s` and handles Darwin), same as on WSL/Debian.
- `git-autofetch` is a launchd LaunchAgent here, not a systemd user timer.
- Orca pairs against `desktop` (`ws://100.64.0.4:6768`) for amd64 work. It does
  NOT pair against `latitude` — that box is the always-on services host.
