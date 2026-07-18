# Design: pre-commit hooks via git-hooks.nix

Date: 2026-07-08
Status: reverted (2026-07-18) — git-hooks.nix wiring + committed `.envrc`
(the persistent GC root this design relied on) removed. Lint/format is now a
manual gate (`just fmt` / `just check`), not enforced on commit.

## Goal

Add committed, Nix-pinned pre-commit hooks to the `machines` flake so
formatting/lint/hygiene issues are caught at commit time (on Nix machines) and
via `just check` / `nix flake check` (anywhere Nix runs).

## Approach

Use the `cachix/git-hooks.nix` flake input (successor to
`pre-commit-hooks.nix`). Rejected alternatives:

- **Standalone `pre-commit` (Python) + `.pre-commit-config.yaml`** — pulls a
  Python toolchain outside Nix, versions drift from the flake, duplicates what
  Nix provides.
- **Hand-written `.git/hooks/pre-commit`** — not shared/pinned; silently absent
  on fresh clones.

## Changes

### 1. Flake input (`flake.nix`)

```nix
git-hooks-nix = {
  url = "github:cachix/git-hooks.nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

### 2. Build the check, wire into devShell + checks (`flake.nix`)

- `pre-commit-check = git-hooks-nix.lib.${system}.run { src = ./.; hooks = {...}; };`
- `devShells.${system}.default`: add `pre-commit-check.shellHook` as the shell's
  `shellHook`, merge `pre-commit-check.enabledPackages` into `packages`. Entering
  `nix develop` / `just shell` installs `.git/hooks/pre-commit`.
- `checks.${system}.pre-commit = pre-commit-check;` so `just check` runs hooks.

### 3. Enabled hooks

- `alejandra` — Nix formatter (matches declared `formatter` + CLAUDE.md)
- `deadnix`, `statix` — Nix lint; **blocking** to start, loosen if too noisy
- `shellcheck` — bash in `scripts/` + `provision/*.sh` (skips `.ps1`)
- Hygiene: `trailing-whitespace`, `end-of-file-fixer`, `check-merge-conflicts`,
  `check-added-large-files`

### 4. Resolve formatter drift (`justfile`)

Change `just fmt` from `nixfmt` → `alejandra` so the recipe and the hook agree.
Keep `nixfmt` / `nil` / `nixd` in the devShell for editor use.

### 5. One-time cleanup pass

Run `alejandra .` (+ trailing-whitespace / EOF normalization on tracked text)
once so the tree starts hook-clean and the first real commit isn't noisy.

## Scope / non-goals

- Hooks auto-install only where `nix develop` runs (NixOS boxes). Windows
  provisioning side (PowerShell) is unaffected; `.ps1` is not shellchecked.
- `just check` enforces hooks anywhere Nix is available, covering CI-style use.

## As-built tuning (first-run findings)

Running the hooks over the existing tree surfaced predictable noise; loosened as
the "start strict, loosen if noisy" plan anticipated:

- **statix `repeated_keys` disabled** via `./statix.toml`. Collision-style
  `services.x = …; services.y = …;` is idiomatic across every module here — the
  lint fought the house style, not real smells. All other statix lints stay on
  (fixed: empty patterns → `_`, manual `inherit`, empty-list concat no-op).
- **`hardware-configuration.nix` excluded** from deadnix + statix (auto-generated,
  never hand-edited).
- **shellcheck `--severity=warning`** — drops intentional info-level style
  (SC2059/SC2016/SC1091) in the hand-tuned statusline/provision scripts. Fixed
  the real warnings/errors: missing `# shellcheck shell=bash` on sourced role
  fragments (SC2148), unused `machine` role param (SC2034, inline-disabled for
  signature parity), literal-tilde printf in bootstrap.sh (SC2088).
- **deadnix**: fixed 2 unused lambda args (overlay `final:/prev:`, pycharm
  `overrideAttrs old:`).
- One-time `alejandra .` + whitespace/EOF pass applied; tree is hook-clean.
- `.pre-commit-config.yaml` is gitignored (git-hooks.nix regenerates it with
  machine-specific store paths on `nix develop`).

## Risk / rollback

- If deadnix/statix produce too many findings, downgrade those two hooks to
  non-blocking (or scope their `excludes`) — a one-line change per hook.
- Backing the input out is: drop the input + the `pre-commit-check` wiring.
