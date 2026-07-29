---
name: hermes-fleet-config
description: "Hermes compact display, statusline, fleet config patterns."
version: 1.1.0
platforms: [linux, wsl]
metadata:
  hermes:
    tags: [hermes, configuration, fleet, nixos, wsl, compact, statusline, bootstrap]
    related_skills: [hermes-agent, hermes-dashboard-service]
---

# Hermes Fleet Configuration

Patterns for managing Hermes Agent configuration across a multi-machine fleet (NixOS hosts + WSL instances). Covers repo-managed config baselines, compact display recipes, the in-session status bar limitation, and known config-key quirks.

## When to Use

- Making Hermes output more compact (less noise per turn)
- Debugging `hermes config set` warnings for display keys
- Deploying Hermes settings across NixOS and WSL fleet members
- Understanding what the Hermes in-session status bar can (and cannot) be customized

## Hermes In-Session Status Bar vs Shell Prompt Statusline

**These are two completely different things.** Do not confuse them when a user asks about "status bar" or "statusline." This was the primary correction from the 2026-07-26 session — the agent wasted time wiring a Starship statusline when the user was asking about the Hermes in-session bar.

| | Shell prompt statusline | Hermes in-session status bar |
|---|---|---|
| **Where** | Your bash/fish prompt, rendered by Starship before every `$` | Bottom bar inside an interactive `hermes` session |
| **What it shows** | Whatever you script (project, branch, model, gateway, etc.) | `⚕ model │ ctx used/total │ [████░░] pct% │ duration │ ⏲ elapsed │ ✓ idle` |
| **Customizable?** | Fully — edit the shell script, Starship TOML, or Nix config | **No** — hardcoded in `cli.py`, no config keys, no plugin hooks |
| **Toggled by** | Shell rc files, Starship config | `/statusbar` slash command or `display.tui_status_indicator` |
| **Extra fields** | — | Battery (if `display.battery: true`), compressions, bg tasks/processes/subagents, YOLO |

The in-session status bar's fields (what it shows, the order, the icons) are **not user-configurable**. The only controls are:
- `/statusbar` — toggle visibility on/off
- `/battery` or `display.battery` — toggle battery read-out
- `display.tui_status_indicator` — change or hide the leading indicator (`kaomoji` → `⚕`, `none` to hide)
- Skin color tokens (`status_bar_bg`, `status_bar_text`, `status_bar_strong`, etc.)

Do not attempt to customize the in-session bar by modifying `cli.py` — changes will be lost on every `hermes update`.

## Compact Display Recipe

For minimal CLI output, disable all noise sources. The full stack:

```bash
hermes config set display.tool_progress false
hermes config set display.show_reasoning false
hermes config set display.compact true
hermes config set display.credits_notices false
hermes config set display.turn_completion_explainer false
hermes config set display.show_commentary false
hermes config set display.show_cost false
hermes config set display.streaming false
hermes config set display.timestamps false
```

What each does:

| Key | Effect when false |
|-----|------------------|
| `tool_progress` | No tool-call progress bubbles — silent until final response |
| `show_reasoning` | No thinking/reasoning blocks |
| `compact` | Less whitespace and padding throughout |
| `credits_notices` | No Nous credits usage nudges |
| `turn_completion_explainer` | No "task complete" commentary |
| `show_commentary` | No Codex commentary channel (irrelevant for non-Codex models) |
| `show_cost` | No cost estimate in status bar |
| `streaming` | No token-by-token streaming |
| `timestamps` | No `[HH:MM]` prefix on messages |

If you want *some* awareness of what tools are running, set `tool_progress: new` instead — it shows a one-line indicator only when the tool type changes, not on every call.

## Known Config-Key Quirk: `display.tool_progress`

```bash
hermes config set display.tool_progress off
# ⚠ 'display.tool_progress' is not a recognized config key — it was saved anyway, but Hermes may not read it.
```

This warning is a **false positive** from the config-key validator. The key exists, works, and is read correctly by Hermes. The validator just doesn't have it in its recognized list. The value gets saved as `false` (boolean) rather than `"off"` (string), which is correct behavior — both are equivalent.

Ignore this warning; verify with `hermes config get display.tool_progress` to confirm it took effect.

## Fleet Config Deployment Flow

The repo at `hermes/config.yaml` is the **baseline seed**. The bootstrap script (`hermes/bootstrap.sh`) uses `copy_managed` — it re-seeds `~/.hermes/config.yaml` only when the committed baseline changes (srchash stamp). Machine-local settings (dashboard auth, onboarding flags) survive across re-seeds.

```
hermes/config.yaml (repo, committed)
       │
       ▼  bootstrap.sh (copy_managed)
~/.hermes/config.yaml (live, with local overrides preserved)
```

### NixOS host

The Starship config lives in `modules/home/me.nix` under `programs.starship.settings`. A `just switch` rebuild applies it.

### WSL host

Starship config is a local `~/.config/starship.toml` — not Nix-managed. Hermes config deploys via bootstrap.

### Adding a new setting fleet-wide

1. Set it live: `hermes config set display.<key> <value>`
2. Sync it to the repo baseline: update `hermes/config.yaml`
3. Commit and push
4. On each fleet member: `bash hermes/bootstrap.sh` (or `git pull && bash hermes/bootstrap.sh`)

## Pitfalls

- **`display.tool_progress` warned as unrecognized**: false alarm, see §Known Config-Key Quirk above. Value saved anyway — verify with `hermes config get`.
- **Hermes in-session status bar ≠ shell prompt statusline**: the bottom bar in `hermes` interactive mode is hardcoded. Do not try to customize it. When a user says "statusline" or "status bar," clarify which one they mean before acting.
- **`nix_shell` format escaping in Nix**: the `\\($name\\)` pattern uses single backslash-paren escapes. When patching via `patch` tool, watch for accidental doubling to `\\\\\\($name\\\\\\)` — verify with `grep '\\\\(' modules/home/me.nix` after editing.
- **Don't hand-edit `config.yaml` for settings**: use `hermes config set KEY VAL` — a stray indent can corrupt the file and break the live gateway.