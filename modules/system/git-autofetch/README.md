# git-autofetch

Periodic **fetch-only** refresh of every git repo under the configured roots, so
`git status` / the shell prompt show an accurate "behind by N" without anyone
fetching first. It **never** pulls/merges/rebases and never touches a working
tree — the actual pull is left to you / the agent, done deliberately when the
tree is safe. Both platform implementations of this one concept live here.

| Platform | Impl | Install |
|---|---|---|
| NixOS | `default.nix` | `services.gitAutoFetch.enable = true;` (imported per host) — installs a systemd timer running every ~10 min. |
| Windows | `git-autofetch.ps1` | Register a Scheduled Task once using the snippet in the script's header `.EXAMPLE` block (run from the repo root). |
| Ubuntu/WSL (disposable box) | inlined in `bootstrap/ubuntu.sh` | Installed automatically: drops `~/.local/bin/git-autofetch` and schedules it via a systemd *user* timer (every ~10 min), falling back to cron. Scans `$HOME`. |

The script derives its own repo root via `git rev-parse` from `$PSScriptRoot`, so
it always adds this checkout as a scan root regardless of where the repo lives or
where in the tree the script sits. The NixOS timer runs as the repo owner (not
root) and both sides use `BatchMode` + `GIT_TERMINAL_PROMPT=0` so an unreachable
remote can never wedge or block the run.
