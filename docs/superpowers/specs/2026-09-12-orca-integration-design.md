# Orca integration — design

**Date:** 2026-09-12 · **Status:** approved, unimplemented · **Branch:** `orca-integration`

Orca (the IDE + its agent runtime) is installed by hand on this fleet, and the
four skills that make it usable from an agent session were installed by hand
too. Nothing in this repo produces either, so the set has already drifted apart
across boxes. This spec makes the *skills* reproducible, writes down the one
routing rule that is dangerous to get wrong, and sketches which of our workflows
should move onto Orca.

## What was measured (2026-09-12, all live)

These five facts drive every decision below. Re-measure before contradicting one.

1. **Bare `orca` on Linux is the GNOME screen reader.** `/usr/bin/orca` (Ubuntu
   package `orca`, 13 KB, present on every desktop install) is what a clean
   login shell resolves — verified with `env -i HOME=$HOME bash -lc 'command -v
   orca'` on g15. An interactive Orca-managed session is the exception: it puts
   `~/.config/orca/linux-orca-cli-shim` ahead of `/usr/bin`, which is why bare
   `orca` *looks* fine when typed by hand. A systemd unit, an ssh command, an
   automation or a provisioning script gets the screen reader and starts speech
   synthesis on the user's machine. The correct name everywhere is
   **`orca-ide`** (`~/.local/bin/orca-ide` → `~/.cache/orca/appimage/launcher/orca-ide`,
   installed by Orca's own CliInstaller). Note `provision/orca-serve.sh`'s
   `orca_cli_name()` would pick a third name, `orca-cli`, which **does not exist
   on g15** — Orca's installer got there first.
2. **The Orca APP lives on two boxes; the place skills must land is a third
   thing — wherever the agent process runs.** g15 runs the Linux AppImage. desktop
   runs the Windows app, and its **agent runtime is set to WSL (desktop-wsl)**, so
   worktrees, terminals and the `claude` process are all inside the distro.
   Measured there 2026-09-12: `~/.local/bin/orca-ide` is a 1148-byte shim Orca
   itself installed (`# Orca managed WSL CLI launcher`) that `exec`s
   `powershell.exe` → `orca-wsl-bridge.ps1` →
   `…\AppData\Local\Programs\orca\resources\bin\orca.exe`; there is no
   AppImage (`~/.cache/orca` absent) and no serve unit. **So the earlier reading
   of that file as serve-era leftover was wrong — it is Orca's own bridge and it
   stays**, and the distro is a REAL skills target: `claude` is installed there
   and reads the distro's `$HOME`. air runs the GUI app and is **hand-managed by
   decision** (see 4). latitude has node but no npx; hub has no node at all. The
   posix tier below therefore has TWO targets: g15 and desktop-wsl.

   The corollary is a rule, not a fact about today: **skills follow the agent
   runtime, not the app.** Flip desktop's runtime to Windows and the store that
   matters becomes `%USERPROFILE%`, with nothing in the distro consulted.
3. **The skill set has already drifted — on both non-g15 boxes.** Measured in
   desktop-wsl 2026-09-12: `~/.agents/skills` holds `find-skills`, `orca-cli`,
   `orchestration` (no `computer-use`), while `~/.claude/skills` links
   **`orchestration` alone** — so the agent that actually runs there sees one of
   the three it has. That is the same half-installed shape as air, on the box
   Orca drives daily. Further: g15 has all four
   (`computer-use`, `orca-cli`, `orchestration`, `find-skills`); **air has only
   `orchestration` in `~/.claude/skills` and `find-skills` + `orchestration` in
   `~/.agents/skills`** — the box used as the client that proxies to the g15 and
   desktop runtimes is the most incomplete one.
4. **air has no Orca CLI on `PATH` at all**, not even under `zsh -lc`. npx is
   there (`/opt/homebrew/bin/npx`). Resolving a CLI there means guessing at an
   app-bundle path on a box that is usually asleep, for one machine — so **air is
   installed by hand and the tier is Linux-only** (decided 2026-09-12). What
   stands regardless: `provision/orca-serve.sh` — AppImage, `serve` units —
   cannot be where this lives.
5. **The four skills come from two sources, and `--all` is wrong.**
   `npx skills list --global` reports `computer-use`, `orca-cli`,
   `orchestration` as `stablyai/orca` and `find-skills` as `vercel-labs/skills`.
   `orca skills list` (the bundled registry) does **not** contain `find-skills`,
   and `--all` would additionally drag in `orca-linear`, `linear-tickets`,
   `orca-emulator`, `orca-emulator-android` and `orca-per-workspace-env`, none
   of which this fleet uses.

## Non-goals

- **The skill files are never tracked in dotfiles.** `orchestration/SKILL.md` is
  a discovery stub by design; the real guide is served by the binary
  (`orca-ide skills get orchestration`) precisely so it cannot drift from the
  binary that will run the commands. Freezing those files at `$HOME` would
  recreate the gortex-pin problem in reverse — a pinned copy fighting a
  version-matched source. The reproducible artifact is the *install command*.
- **No new role, no `PLANNED_ROLES` edit.** This is behaviour, so it is a tier
  (`AGENTS.md`, *Key patterns*).
- **No migration of existing systemd timers to Orca automations.** An automation
  needs the Orca runtime up; a timer does not. Checked: the `G15 memory harvest`
  automation (Saturdays 4:20, host `self`) has **no** systemd counterpart, so
  there is no second writer to the consolidation queue today. Adding automations
  is in scope (L3); moving script-shaped jobs onto the runtime is not.

## L1 — `tier_orca_skills`

A new best-effort tier in `provision/lib/tiers.sh`. **Not PORTABLE — Linux-only
by decision**: its targets are g15 and desktop-wsl (measurement 2), and air is
hand-managed. On Darwin it skips with a message. Both targets run
`provision/linux.sh` with the `workstation` profile, so one tier-list entry
reaches both and the distro needs no separate wiring.

**Open, and it is per-box:** `computer-use` drives OS windows, and desktop-wsl has
none — its windows are Windows-side. Either the desired set is three skills in a
WSL distro and four on a GUI box, or `computer-use` is installed everywhere and
simply unused where it cannot act. Decide at implementation time; the diff logic
is the same either way.

**Resolution.** A small pure function, `_orca_cli()`, prints the executable or
nothing:

- Linux: `orca-ide` only. **Never bare `orca`** — measurement 1. If a future box
  has `orca-cli` (what `orca-serve.sh` would install where `/usr/bin/orca`
  exists), accept it as a second candidate; still never `orca`.
- Darwin: no branch at all. air is hand-managed (measurement 4), so `_is_darwin`
  is a skip-with-a-message, not a second resolver. If air ever joins, add the
  branch then — with a measured bundle path, not a guessed one.

**Gates, all skip-with-a-message, never fail:**

| Condition | Register | Why |
|---|---|---|
| no Orca CLI | `info` | latitude, hub — expected state, like `tier_docker` on WSL |
| no `npx` | `warn` | `orca skills install` is a wrapper over `npx --yes skills add`; wanted to and could not |
| CLI found, install fails | `warn`, continue | best-effort tier semantics |

**Desired set**, explicit, as two commands from two sources:

```sh
"$ORCA" skills install --skill computer-use --skill orca-cli --skill orchestration \
    --agent claude-code,universal
npx --yes skills add vercel-labs/skills --skill find-skills --global \
    --agent claude-code --agent universal -y
```

**`--agent` takes ONE comma-separated value, and repeating the flag is
last-wins — measured on g15 2026-09-12 with `--dry-run`.**
`--agent claude-code --agent universal` resolves to
`npx … --global --agent universal -y`: `claude-code` is dropped, silently, rc 0.
That installs into `~/.agents/skills` with **no link in `~/.claude/skills`** —
precisely the drift state on air that this tier exists to close, manufactured by
the tier itself. `--agent claude-code,universal` resolves to both. The wrapper is
the only layer with this behaviour: the raw `npx skills add` form below takes the
repeated flag, which is how all four skills came to be dual-store on g15.

`--agent` is explicit at all on purpose: Orca's own help warns that without it the
skills CLI installs into every agent it knows about and litters the host with
config directories for agents it does not have. `claude-code` + `universal`
(`~/.agents/skills`) is what this box already has, and `universal` is what makes
Codex and Zed see them too.

**Idempotency is a filesystem check, not `orca skills installed`.** That
subcommand talks to the Orca runtime (unlike `skills install`, which says out
loud that it reads the registry locally), and the tier has to work on a box
where Orca is installed but not running.

The check has to read **two** paths, because the install writes one real
directory and one link: measured on g15 and air, `~/.agents/skills/<name>/` is
the real store and `~/.claude/skills/<name>` is a relative symlink into it
(same inode for `SKILL.md` on both boxes). A skill therefore counts as present
only when the real directory exists **and** the Claude-side link resolves to it.
A `~/.agents`-only probe would be wrong on a live box today: air has
`find-skills` in `~/.agents/skills` with **no** link in `~/.claude/skills`, so
the universal target is satisfied while the agent that actually reads skills in
a session cannot see it — the precise drift class this tier exists to close.
Missing on either side → re-run the add for that skill; present on both →
`skills update`.

**Wiring.** INSERTED after `"agent_clis claude"` in the `workstation` tier list of
`provision/linux.sh` — **not `macos.sh`**, air being hand-managed — and not
appended, which would
land it after `dotfiles`, whose own comment in `linux.sh` records that it stays
LAST (the bare-repo checkout is refused when an untracked file occupies a tracked
path). After `agents_config` and `agent_clis` because the
skills CLI detects install targets by looking for agent config directories, so
`~/.claude` must exist first. Not in the `server` or `hub` lists: neither box has
Orca and neither should grow it. `provision/orca-serve.sh` calls the tier at the
end of its own install so a fresh Orca box is complete in one run — and that call
site must set the globals `tiers.sh` declares in its header (`REPO SUDO PRIV
WARNINGS APT_UPDATED`). orca-serve.sh sets `SUDO` only and its own `warn()` never
touches `WARNINGS`, so under `set -u` the first warn inside a tier body aborts the
script.

**Tests** — `provision/tests/orca-skills-tier.test.sh`, modelled on
`docker-tier.test.sh`: pure decisions only, no network, `TIERS_LIB_ONLY=1`.
Cases — **two mutations matter, and the second is the worse one**, because it
fails with a correctly-resolved CLI and exit 0: the constructed argv must carry
`--agent claude-code,universal` as ONE comma-joined value (a split back into two
`--agent` flags installs the universal store only), and **resolution must never
return bare `orca` on Linux even when `/usr/bin/orca` exists**. Plus: CLI
resolution prefers `orca-ide`; darwin → skip rc 0; no
CLI → skip rc 0; no npx → warn rc 0; desired-vs-present diff yields add for
missing and update for present; the desired list contains exactly the four names
and none of the Linear/emulator bundle.

## L2 — routing rules

Two short additions, no new mechanism:

- **`AGENTS.md`, under *Key patterns*:** the `orca-ide` rule with its
  measurement, because a script in this repo calling bare `orca` is the failure
  it prevents.
- **`~/.claude/host-memory.md`** (g15) and **`~/.claude/memory/global.md`**: which
  skill answers which need —
  `orca-cli` for Orca state (worktrees, terminals, the embedded browser,
  handoffs), `orchestration` for supervised multi-agent work (DAGs, ask/reply,
  escalations), `computer-use` for OS-level control of windows outside Orca,
  and the plain Agent tool when none of the above is involved. Plus air's role as
  a client to the g15 and desktop runtimes (`orca environment` / `orca host`),
  which is why its skill set matters as much as the hosts'.

## L3 — workflows onto Orca (outline; planned separately)

Approved in principle, specified after L1 and L2 land:

1. **worktree agents → Orca worktrees.** Today isolation is the Agent tool's
   `isolation: "worktree"` plus the `worktree-agent` skill. An Orca worktree is
   visible in the IDE and outlives the session. Open question: whether the
   `worktree-agent` skill grows an Orca branch or the Orca path becomes the
   default on boxes that have it.
2. **Long multi-step work → an `orchestration` DAG** with a supervising
   coordinator, instead of fire-and-forget background subagents.
3. **More automations, but only where an agent is genuinely required** — the
   existing memory harvest is the model. A job that a shell script can do stays a
   systemd timer, for the runtime-availability reason in *Non-goals*.
4. **Orca's per-repo Setup/Archive hooks must wire themselves for a NEW repo.**
   Today `/orca-setup` scaffolds the committed `.orca/worktree-setup.sh` and then
   PRINTS a one-liner for the user to paste into Orca's per-repo settings, by
   design — the skill refuses to write `orca-data.json`. Measured on g15
   2026-09-12: 6 of 7 registered repos carry
   `hookSettings.scripts = {setup: "wt-setup", archive: "wt-teardown"}` and
   `/home/me/my/DeMarket` carries `{"", ""}` — so the manual step is already the
   drift source, exactly like the skills set in L1. Blocker to measure first:
   **the CLI has no writer for that field.** `orca repo …` exposes `add`, `show`,
   `list`, `set-base-ref`, `search-refs` and nothing that sets `hookSettings`, so
   the options are (a) ask upstream for `orca repo set-hooks`, (b) extend the
   `orca-repair` precedent — it already edits `orca-data.json` behind an
   Orca-closed guard with a backup — or (c) a default that applies to every repo
   rather than per-repo settings, if Orca grows one. (a) first: (b) is surgery on
   a file the app owns, and writing it on every provision run is worse than
   pasting a line once.

   **Second measurement, same day, and it raises the stakes: that state is not
   even host-local in practice.** Deleting the `machines` project from Orca on
   desktop removed g15's registration too — `orca repo list` went from 7 to 6 and
   `project setups` lost the row entirely, on a box that was not touched.
   Projects are keyed by git remote (`github:metheoryt/machines`) while setups
   carry a `hostId`, so one delete reaches every host's setup. Re-adding with
   `orca repo add --path …` restores the repo but comes back with
   `scripts: {setup: "", archive: ""}` — the hook wiring is lost with it and has
   to be pasted again by hand. Worth reporting upstream as its own bug: removing
   a project on one host should not delete another host's setup silently.

Each of the three needs its own measurement pass before it is written; none of
them blocks L1.

## Risks

- **npx in desktop-wsl is Windows' node** (`/mnt/c/Program Files/nodejs/npx`),
  reached over interop — measured again 2026-09-12, no Linux node in the distro.
  It works, it is slow, and it writes through the 9P boundary. If the tier is
  painful there, install a Linux node in the distro rather than skipping the tier.
- **Two target boxes, and reproducibility is still the stronger argument than
  fan-out.** g15 has been reinstalled once already; the point of a tier over a
  written-down command is that the next reinstall does not depend on anyone
  reading the doc.
- **`vercel-labs/skills` is a third-party source.** It is already installed and
  in use; the spec only makes the existing choice reproducible. If that
  dependency is unwanted, drop `find-skills` from the desired set — nothing else
  in the design depends on it.
- **air's drift is not fixed by this spec at all.** It is installed by hand, so
  its four skills stay a manual step (`npx --yes skills add …`, the same two
  commands) whenever it drifts.

## Follow-ups this decision opens (not in L1)

- **DELETE `provision/orca-serve.sh`'s `serve` half** (decided 2026-09-12 — no
  need for a headless Orca while the desktop box runs it Windows-native and
  switches into the distro itself). The `desktop` mode (AppImage, g15) stays, so
  the script survives; what goes is the systemd unit + linger, the
  `--appimage-extract` path, `orca_want_autostart`, and the `serve` arm of
  `orca_install_mode` — with their cases in `provision/orca-serve.test.sh`.
  `orca_cli_name()` goes too: with WSL out, the only Linux box is g15, where
  `/usr/bin/orca` exists and Orca's own installer already owns `orca-ide`.
  **Nothing to clean up in desktop-wsl**: measurement 2 found no serve unit, no
  AppImage, and an `orca-ide` that is Orca's own Windows bridge — leave it.
- **A Windows skills path is needed only if desktop's agent runtime is switched
  to Windows.** It is WSL today, so the distro's stores are the live ones and the
  Windows side has the app and nothing else to install. When it is wanted, it is
  the same two `npx skills add …` commands Orca's Settings UI prints, as a
  `provision/windows.ps1` step — and it needs one measurement first: node/npx on
  that box, and whether the skills CLI writes the same two stores under
  `%USERPROFILE%`.
- **`tier_agents_config`'s comment still says bootstrap mirrors config into an
  Orca-managed account profile.** That mechanism was deleted 2026-09-09 and
  bootstrap now refuses such a dir (exit 3); profiles are managed in Orca itself.
  Fixed in this branch.
- **Windows-native Orca on desktop has no skills path here.** The posix tier
  cannot reach it; whether `provision/windows.ps1` should grow one is unasked.
