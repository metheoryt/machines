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

## Mesh / secrets (paths only — never the key)

- This host's AmneziaWG mesh key (`awg0`, mesh IP `10.0.0.8`, peer
  `nix-lat5520`) lives at two paths, both git-ignored (paths recorded here, key
  content never committed):
  - `/etc/amnezia-wg/awg0.key` — the OPERATIONAL copy `awg0` actually reads.
    Outside `$HOME`, so neither dotfiles nor home-manager tracks it; must be
    placed by hand on a fresh box or `awg0` won't come up (`wireguard-awg0`
    fails). Requires the LTS kernel (see project memory) for the module to load.
  - `~/.ssh/vps_awg_private.key` — spare copy; recorded as a restore-checklist
    marker in the `latitude5520` dotfiles branch `.gitignore`.
  - Regenerate/restore source of truth: VPS `vps/vps/peers/nix-lat5520.key`.
