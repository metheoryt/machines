# Host: latitude5520

<!--
Per-host memory + instructions for latitude5520 (Dell Latitude 5520, NixOS —
Intel Tiger Lake). Symlinked to ~/.claude/host-memory.md and injected by the
global-memory-load.sh hook, so it is loaded ONLY when the hostname matches. Tracked in git
and synced to every machine, but inert on the others. Put machine-specific facts
here: installed tooling, local paths, hardware quirks, per-host overrides. Do NOT
put secrets here (this file is tracked in git).
-->

## Environment

- **This box = `latitude5520`** (fleet label `latitude`): **Dell Latitude
  5520**, Intel Tiger Lake, **NixOS**. Standalone — no Windows sibling identity.
  Mesh peer `nix-lat5520`, mesh IP `.8`.

## Notes

- `security.sudo.extraRules` grants `me` NOPASSWD for `nixos-rebuild` +
  `nix-collect-garbage`, so `just switch/upgrade/test/clean` run without a TTY
  password prompt — an accepted tradeoff (effectively passwordless root on
  this personal box); Claude's own Y/n gate is the only remaining control on
  agent-driven runs.
- LAN devices going unreachable (ARP resolves, no ICMP/TCP) while the
  AmneziaVPN client (`amn0`, split-tunnel `AllowedIPs=10.0.0.0/24`) is
  connected is NOT caused by anything in `machines` or by routing/iptables/
  nftables (verified clean at every layer) — the cause is the router/AP
  (likely band-steering / client isolation triggered by VPN traffic).
- Ghostty's `ssh-env,ssh-terminfo` integration works even on the 1.3.1 package
  (it's a fish-function wrapper in the package's own integration script,
  distinct from the standalone `+ssh` CLI that needs 1.4.0+). Its `sudo`
  integration wraps `sudo --preserve-env=TERMINFO` — matters here because
  nearly every daily `just` command shells through `sudo` and would otherwise
  lose Ghostty's terminfo.

## Mesh / secrets (RETIRED — paths only)

- The AmneziaWG *mesh* has been retired from this repo, so `awg0` is no longer
  brought up on this host. The paths below are retained only as a
  historical/restore record of key material that may still exist on disk —
  never the key content itself. (The AmneziaVPN *client* app on latitude is
  KEPT and is separate from this retired mesh spoke key.)
  - `/etc/amnezia-wg/awg0.key` — the OPERATIONAL copy `awg0` used to read.
    Outside `$HOME`, so neither dotfiles nor home-manager tracks it.
  - `~/.ssh/vps_awg_private.key` — spare copy; recorded as a restore-checklist
    marker in the `latitude5520` dotfiles branch `.gitignore`.
  - Regenerate/restore source of truth (if ever needed again): VPS
    `vps/vps/peers/nix-lat5520.key`.
