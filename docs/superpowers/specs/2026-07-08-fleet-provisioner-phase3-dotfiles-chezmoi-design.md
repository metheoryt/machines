# Fleet Provisioner — Phase 3: `dotfiles` role executor (chezmoi) — design spec

> **Status:** design approved via brainstorming 2026-07-08; pending user review of
> this written spec, then → `writing-plans`.
> **Parent:** `docs/superpowers/specs/2026-07-08-unified-fleet-provisioner-design.md`
> (§4 state/ownership, §6 role catalog). **Predecessor:**
> `docs/superpowers/specs/2026-07-08-fleet-provisioner-phase2-agents-executor-design.md`
> established the role→executor pattern this reuses.

## 1. Goal & scope

Make `dotfiles` the fleet's **second real role executor**, adopting **chezmoi** as
the dotfiles engine for non-Nix boxes — the one engine from the parent design
(§4) not yet in use. Phase 3 stands up the **mechanism** (chezmoi wired behind
the dispatcher, dry-run preview + per-role confirm, same shape as `agents`) with
a **minimal real payload**: a single tracked file, `~/.gitconfig`.

**In scope:** chezmoi source tree in-repo; per-platform `dotfiles` executors
(nixos no-op, windows/wsl/debian → chezmoi); dispatcher registration; the
`dot_gitconfig.tmpl` seed; auto-install of chezmoi on apply.

**Out of scope (deferred, deliberate):** age-encrypted secrets via chezmoi (comes
with the secrets phase — parent §4/§11); migrating any further dotfiles (chezmoi
`chezmoi add` makes that incremental later); active teardown of the retired bare
`~/.dotfiles` repo (documented as retired, parent §4 — nothing meaningful to
migrate).

## 2. Decisions (resolved in brainstorming 2026-07-08)

- **Source location = subdir of THIS repo** (`machines/dotfiles/`). Not a separate
  repo. One source of truth, synced by the same `git pull` that carries
  `fleet.json` + `agents/`. Mirrors how `agents/` holds the Claude config.
- **Initial payload = git config only** (`~/.gitconfig`). Universal, non-secret,
  meaningful on every non-Nix box, and exercises chezmoi templating (the one known
  cross-platform divergence). Smallest surface that proves the mechanism
  end-to-end.
- **chezmoi install:** the executor auto-installs chezmoi on **apply** if missing
  (winget on Windows; official install script / apt on Linux); **dry-run** only
  reports "would install"; warn-and-continue if no installer is available.
  Convergence-first — the tool makes the box converge, it doesn't just complain.
- **age secrets: deferred.** No age dependency in Phase 3.
- **`~/.dotfiles` bare repo:** documented retired; no active teardown here.

## 3. Architecture — chezmoi in stateless `--source` mode

chezmoi normally owns a source repo at `~/.local/share/chezmoi` and pulls it with
`chezmoi update`. We do **not** use that mode — it would reintroduce a
second-source-of-truth and chezmoi-managed git. Instead:

- **Every invocation passes `--source "$repo/dotfiles"` explicitly.** No
  `chezmoi init`, no `~/.config/chezmoi/chezmoi.toml` state, no chezmoi-managed
  git. Destination is the default (`$HOME`), overridable via `--destination` for
  tests.
- **Updates arrive via `git pull` on `machines`**, exactly like every other role's
  source. chezmoi never fetches.
- **Dry-run = `chezmoi diff --source …`** — a unified diff of pending changes, the
  natural preview for the confirm gate. Empty diff = converged.
- **Apply = `chezmoi apply --source …`** — idempotent; overwrites local drift with
  the source default (parent §4: that's how a bumped default re-aligns the fleet).
- **No custom `promptString` templates in Phase 3** — the seed uses only built-in
  `.chezmoi.*` data (e.g. `.chezmoi.os`), so `apply`/`diff` run non-interactively
  with no config file present.

## 4. Components

- `machines/dotfiles/dot_gitconfig.tmpl` — **new**. The chezmoi source for
  `~/.gitconfig` (chezmoi decodes `dot_` → `.`, `.tmpl` → templated). Contents:
  - Universal git settings: `user.name`, `user.email` (personal
    `metheoryt@gmail.com`), sensible defaults (`init.defaultBranch`,
    `pull.rebase`, common aliases).
  - The one templated divergence:
    `{{ if eq .chezmoi.os "windows" }}autocrlf = true{{ else }}autocrlf = input{{ end }}`.
  - `[include] path = ~/.gitconfig.local` at the end, for machine-/identity-
    specific bits chezmoi does **not** own (work email, credential helpers). This
    keeps declared fleet-wide state and ambient local state cleanly separated —
    the parent §4 "declared, not ambient" divergence model.
  - **Seeded** from this box's current `~/.gitconfig`, then trimmed to the
    universal core (machine-specifics pushed to `~/.gitconfig.local`).
- `provision/roles/dotfiles.sh` — **new**. `role_dotfiles <mode> <platform>
  <machine>`, sourced by `provision.sh`. `nixos` ⇒ prints the home-manager-owned
  skip line, returns 0 (dotfiles on NixOS is home-manager's job — parent §6; add a
  `git.nix` there separately, not here). `wsl|debian` ⇒ ensure chezmoi (apply:
  install if missing; dry-run: report), then `chezmoi diff`/`apply --source`.
  `other` ⇒ skip line, return 0.
- `provision/roles/dotfiles.ps1` — **new**. `Invoke-RoleDotfiles -Mode -Platform
  -Machine`, dot-sourced by `provision.ps1`. `windows` ⇒ ensure chezmoi (winget),
  then `chezmoi diff`/`apply --source`; throws on apply failure so the dispatcher
  flags it. `nixos`/other ⇒ skip line.
- `provision/provision.sh` — **unchanged**. The Phase 2 `roles/*.sh` sourcing loop
  auto-loads the new `roles/dotfiles.sh`, and the generic dispatch
  (`fn="role_${role//-/_}"; declare -F "$fn"`) picks up `role_dotfiles` with no
  edit. (A smoke run confirms this rather than a code change.)
- `provision/provision.ps1` — **modify**: add `'dotfiles'` → scriptblock to the
  `$RoleExecutors` map (the `roles/*.ps1` dot-source loop already loads the file).

## 5. Interfaces & contract

- **Mode contract** (identical to `agents`): `dry-run` | `apply`. Executors set
  chezmoi's behavior accordingly; dry-run mutates nothing (no install, no
  `chezmoi apply`).
- **Dispatch names:** posix `role_dotfiles` (matches `role_${role//-/_}` for the
  un-hyphenated `dotfiles`); windows `$RoleExecutors['dotfiles']` → `Invoke-RoleDotfiles`.
- **Exit/throw:** posix returns chezmoi's exit code on apply; windows throws on
  non-zero (dispatcher's per-role `try/catch` sets `$rc=1`). Matches Phase 2.
- **Platform coverage from `fleet.json`:** `dotfiles` is currently on
  latitude5520 (nixos → no-op), g16 (nixos → no-op), g614jv (windows → chezmoi),
  homeserver (windows → chezmoi), vps (debian → chezmoi). So the first real
  exercises are the two Windows boxes + the VPS.

## 6. Testing (session-verifiable + Runbook)

Same discipline as Phase 2: **no unit tests** — `bash -n` / pwsh parse + **smoke
runs** with exact expected output. All session smokes use a throwaway
`--destination` temp dir so no real `~/.gitconfig` is touched.

- **Syntax/parse:** `bash -n` on both `.sh` files; `Parser::ParseFile` on both
  `.ps1` files.
- **nixos no-op:** `role_dotfiles dry-run nixos latitude5520` prints the
  home-manager skip line, exits 0, invokes no chezmoi.
- **chezmoi diff dry-run (windows/debian):** against a temp dest with chezmoi
  present, `dry-run` shows a would-change diff for `.gitconfig` and creates no
  file in the dest; reports converged (empty diff) on a second run after a manual
  apply into the temp dest.
- **apply-confirm "n" gate:** previews, answers `n` ⇒ `– dotfiles skipped.`,
  `rc=0`, dest unchanged. (ps1 gate driven via Git Bash `echo n | pwsh -File …` —
  the PowerShell tool's `-NonInteractive` mode makes `Read-Host` throw; Phase 2
  gotcha, carried forward.)
- **install-missing path:** with chezmoi absent (simulated via `PATH` scrub),
  dry-run prints "would install chezmoi" and installs nothing.

**Runbook (real-box, needs `git pull` first):** real `-Apply`/`--apply` answering
`y` on g614jv/homeserver (Windows) and vps (Debian) → `~/.gitconfig` (re)written
from the template, `~/.gitconfig.local` preserved. Confirm chezmoi auto-install
fires on a box without it. nixos boxes show the dotfiles skip and apply nothing
for that role.

## 7. Risks & open questions

- **chezmoi absent at first run** — handled by the auto-install path; the risk is
  installer variance (winget vs curl vs apt). Executor warns-and-continues if no
  installer, so a missing chezmoi degrades to a skip, not a crash.
- **Seeding `dot_gitconfig.tmpl` accurately** — must trim machine-specifics out of
  the committed template into `~/.gitconfig.local`, or `chezmoi apply` would
  overwrite a box's local git identity with another box's. Mitigation: the
  `[include] ~/.gitconfig.local` split + review the seed before commit.
- **NixOS `.gitconfig` ownership** — the role is a no-op on nixos by design, but
  nixos boxes may currently have an unmanaged `~/.gitconfig`. Out of scope here;
  a future `git.nix` home-manager module is the nixos path (noted, not built).
- **WSL not yet a manifest machine** — the posix executor handles `wsl` for when a
  WSL distro is registered, but no `fleet.json` entry exercises it yet (matches
  the `agents` executor).

## 8. Self-review

- **Scope:** single focused deliverable (one engine, one file, two new executors +
  one map entry). No decomposition needed.
- **Consistency with parent:** source-in-repo (§4 single source of truth),
  chezmoi-on-non-Nix / home-manager-on-nixos split (§4/§6), declared-not-ambient
  divergence via `.gitconfig.local` (§4), secrets deferred (§11).
- **Consistency with Phase 2:** identical mode contract, dispatch-name derivation,
  exit/throw semantics, testing discipline, and the `-NonInteractive` ps1-smoke
  gotcha.
- **No placeholders:** every component and test names literal files/commands.
- **Ambiguity resolved:** stateless `--source` mode (not `chezmoi update`);
  install on apply only; nixos = no-op.
