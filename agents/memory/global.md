# Global memory

<!--
Claude-written persistent memory, loaded into every session on every machine
(injected by the global-memory-load.sh hook). Append durable, CROSS-PROJECT facts here: who the
user is, preferences that hold everywhere, confirmed feedback, long-running
context. One bullet per fact under a topical heading. Keep it curated — edit or
remove stale entries. Tracked in git: committed from this repo and pulled
elsewhere to sync. Do NOT put secrets here.
-->

## User

## Git workflow

- **Personal fleet-sync repos use one framework:** `machines/agents/docs/git-workflow.md`
  (one model, two modes — main-checkout / worktree). In a non-blocklisted linked
  worktree the `worktree-workflow` hook surfaces the worktree-mode rules + live
  `main`↔branch divergence. Work repos (`github.com:thepureapp/*`) are excluded —
  they keep the pure-dev PR flow.

## Fleet SSH reachability

- **The fleet machines are mutually reachable over SSH via the Tailscale/Headscale
  tailnet — assume it, don't re-probe each session.** SSH aliases live in
  `~/.ssh/config` (generated from `fleet.json` (repo root) → `ssh.nix`): `latitude`
  (latitude5520), `desktop` (the ROG G16 2024 laptop — Windows hostname `g614jv`
  inside WSL / `ME-G614JV` native; its old NixOS identity `g16` is retired), `server`
  (g513ie — SSH lands in its Linux/WSL env), `hub` (the cyphy.kz VPS, not a
  fleet workstation). Keys-only, no public exposure.
- **The remote login shell differs by box.** NixOS/Linux members (e.g. `latitude`)
  log in to **fish**, which chokes on `$(...)` / POSIX-test syntax passed as
  `ssh host '<script>'` (fails silently / non-zero). The **Windows fleet members
  (`desktop`=g614jv, `server`=g513ie) SSH into PowerShell**, which chokes on
  `&&` and shell quoting. Either way, force bash: `ssh host bash -s < script.sh`
  (piping a script file is the most robust). On the Windows boxes `bash -s`/`bash -lc`
  dispatches to WSL bash.
- **Inline `ssh host bash -lc '<cmd>'` (single-quoted) FAILS on the fleet — use
  `bash -lc "'<cmd>'"` (nested) or pipe `bash -s`.** ssh flattens its argv into ONE
  command string, so the LOCAL single-quotes are stripped before the remote shell
  sees them: the remote receives `bash -lc <cmd>` and `bash -c` runs only the first
  word (`mkdir -p ~/x` → just `mkdir`, no args → "no dirs provided"). A single-word
  command (`hostname`) survives by luck; anything with args/paths/redirects breaks.
  The inner quotes must travel to the remote intact (`bash -lc "'…'"`), or send the
  body on stdin (`bash -s < script`) where argv-flattening can't touch it. *(Bit the
  fleet-gather.sh Windows harvest 2026-07-19 — the shipped single-quote form silently
  reported the Windows boxes "unreachable.")*

## Windows OpenSSH & winget footguns

- Windows Firewall allow-rules **union**, and installing `OpenSSH.Server` auto-creates
  `OpenSSH-Server-In-TCP` allowing TCP 22 from Any on all profiles — so adding a
  narrower scoped rule restricts nothing until the default is
  `Disable-NetFirewallRule`'d (which is exactly what `windows.ps1` does).
- Windows OpenSSH Server ships with `PasswordAuthentication` enabled — key-only
  parity needs `PasswordAuthentication no` / `KbdInteractiveAuthentication no`
  written into `%ProgramData%\ssh\sshd_config` + an sshd restart; capability +
  authorized_keys alone is not enough.
- `OpenSSH.Server~~~~0.0.1.0` is a fixed optional-feature capability identifier
  (unchanged since Win10 1809), NOT a version string — the real binary version
  updates via Windows Update; check it with `Get-WindowsCapability -Online -Name
  OpenSSH*`.
- The winget package `Anthropic.Claude` installs the Claude **Desktop** app, not
  the Claude Code CLI (install that separately via native installer / npm); a
  Node.js winget entry is what enables Claude Code's `npx`-dependent features.

## Fish shell gotchas

- Fish errors "no matches found" on unquoted glob args like `grep
  --include=*.nix` — quote the pattern (`--include="*.nix"`) or use `find`.

## Fleet scripting conventions

- A script feature that SSHes into infrastructure to mint a credential must be
  strictly opt-in behind an explicit flag (e.g. `tailscale-wsl.sh --enroll`),
  never firing as a side effect of a normal run.
- `ssh-keygen -y` echoes the `-C` comment embedded in a key, so re-stamping by
  appending the comment again produces a doubled comment ("me@wsl-desktop
  me@wsl-desktop") — strip to type+body before re-stamping.

## Home-Manager & bootstrap gotchas

- Home-Manager's `checkLinkTargets` aborts activation ("Existing file would be
  clobbered") when a path it wants to own already holds untracked files/symlinks
  from another mechanism (e.g. `bootstrap.sh`) — remove those stray links once,
  don't retry the switch. Corollary: running a profile bootstrap from inside a
  git worktree can repoint the profile symlinks (`~/.claude`, `~/.codex`) into
  that worktree and break them if it's later removed — remove symlinks whose
  target contains the worktree path, then re-switch.

## Orca IDE — tooling footguns

- Never use Orca's in-app "install shell command" on NixOS: it symlinks
  `~/.local/bin/orca-ide` straight at the AppImage's unwrapped Electron binary,
  which fails `libnspr4.so: cannot open shared object file` and — if
  `~/.local/bin` precedes it on PATH — silently shadows the working
  Nix-wrapped `orca-ide`. Delete `~/.local/bin/orca-ide` if present.
- `npx skills add … --global` (Vercel Labs) installs to `~/.agents/skills/`
  (vendor-neutral), NOT `~/.claude/skills/`, so Claude Code does not
  auto-discover skills installed that way — only tools that read
  `~/.agents/skills/` (e.g. Orca) see them.
- Orca's Claude-session-**resume** command uses `&&` as a statement separator —
  fine under `pwsh.exe` (PowerShell 7) or `cmd.exe`, but legacy Windows PowerShell
  5.1 (`powershell.exe`) rejects it ("The token '&&' is not a valid statement
  separator in this version"). If Orca launches a pane on a Windows box, point its
  shell setting at `pwsh.exe`.

## Harness behavior (empirical)

- Claude Code's settings writer (`/config`, `/plugin marketplace add`, …)
  resolves only **one** symlink hop before writing its `<file>.tmp.*` beside
  the target; a second hop into a read-only store (Nix) fails EROFS — this is
  why the tracked config files must be **one-hop-direct** out-of-store
  symlinks.
- The Claude Code statusline's 5h/7d usage segments render only when the
  harness feeds `rate_limits.five_hour`/`seven_day` (subscription-billed
  sessions); API-key sessions get a cost/balance segment instead. Switching
  profiles swaps the OAuth credential in `~/.claude/.credentials.json` +
  `~/.claude.json`'s `oauthAccount`, not the config dir.
- Claude Code's "auto mode" is a permission mode, not a model choice — set via
  `permissions.defaultMode: "auto"` in settings.json (enum:
  default/acceptEdits/bypassPermissions/plan/auto).
- Claude Code's safety classifier auto-denies actions that route around a
  guardrail — a direct `git push origin main`, a commit/PR that weakens a
  security control (e.g. adding NOPASSWD sudo), a state-changing multi-target
  op on a terse/ambiguous approval, or a write of external content into a
  directory later read as agent instructions (`npx skills add … --global`); it
  wants the user to run the command directly.
- DSPy was evaluated and rejected for evolving the Claude Code / cyphy agent
  config: it needs a typed signature + scalar metric + labeled dataset that
  open-ended interactive sessions lack, and its few-shot-demo lever doesn't
  apply to zero-shot instruction prose (CLAUDE.md/skills/facets). The scoped
  alternative (transcript-mining behavioral eval → human-gated config diffs)
  was deprioritized, not built.

- **Subagents — full reference in `agents/docs/claude-code-subagents.md`
  (verified 2026-07).** Key facts: subagent = separate Claude instance, fresh
  context, returns only its final message to the parent. Nesting caps at **5
  levels** (depth-5 gets no Agent tool); sweet spot 2–3. The real footgun is
  **explosive fan-out within the cap**, not depth (documented CPU-saturation
  incidents). Auto-invocation via the `description` field works like skills
  (`"use proactively"` encourages it) but is **unreliable — explicit invocation
  is the only dependable trigger**; no hard explicit-only toggle. Ad-hoc
  subagents run concurrently (no doc'd cap; batch to avoid rate limits);
  Workflows cap at ~16 concurrent / 1000 total. Three tiers: subagents (1–3) <
  agent teams (3–5, `SendMessage`) < workflows (dozens+, scripted). Our fleet:
  shared agents go under `agents/subagents/` (per-file linked into every
  profile's `agents/` by bootstrap.sh/claude.nix — ships `research-orchestrator`
  + `web-research`) or `agents/plugin/agents/` (cyphy plugin); both sync via git.
  `gortex-search`/`gortex-impact` are gortex-provisioned, not ours.

- **`claude --resume <id> --model X` HONORS the new model (probed 2026-07-10,
  v2.1.206).** A session started on haiku, resumed with `--model claude-sonnet-5`,
  ran the next turn on sonnet (verified on the `assistant` stream-json events, not
  just the system-init echo). Resuming with **no** `--model` defaults to the
  LAST-used model, not the session's original. So model can vary per resume/turn
  while the session, worktree, and provider stay pinned — the basis for skep's
  "model lives on the Invocation, not the Session" decision.

- **Verify Claude Code's file-reading before designing around it.** Empirically
  confirmed for a user config dir (`CLAUDE_CONFIG_DIR`): only `settings.json` is
  read at the config-dir ROOT — a config-root `settings.local.json` **and** a
  config-root `.env` are NOT read. Reliable ways to get env into a session (and
  its Bash-tool subprocesses): (a) a var in the launching process env, or
  (b) a PROJECT-scope `<repo>/.claude/settings.local.json` `env` (this is the
  one place `settings.local.json` is honored). Test with a throwaway
  `CLAUDE_CONFIG_DIR` + `printenv` probe rather than assuming.

- **Headless `claude -p` permissions (probed 2026-07-09, v2.1.205).** `Write`,
  `Edit`, and MCP tools are ALL denied by default; each must be named in
  `--allowedTools` (`mcp__<server>__<tool>`). `Read` is available with NO grant.
  `--allowedTools` is **additive** to the default-allowed tools — passing only
  an MCP tool does not strip `Read`. A PROJECT-scope `.claude/settings.json`
  `permissions.allow` does **not** arm in headless `-p` (its grant silently has
  no effect), so pass everything on argv and delegate nothing to settings.
  Caveats: `Read` is free by *permission* — a `PreToolUse` hook can still deny
  it; MCP servers may finish connecting mid-session, so a tool can be absent at
  turn one; a tool can be missing from the session's tool list entirely
  (registration ≠ permission). Reproducible scripts:
  `~/my/skep/docs/superpowers/specs/probes/l1.1-permissions/`.

- **When probing an agent harness, make the capability leave an out-of-band
  marker and always run a control.** Judge by a file on disk (or an unguessable
  token the agent could only echo after reading), never the agent's
  self-report — but DO read the self-report, because it names the *mechanism*
  of a denial. Two false conclusions were caught this way: a `Bash` denial that
  was the sandbox's working-directory guard rather than the permission system
  (an artifact of nesting `claude` inside an already-sandboxed shell), and a
  `Grep` "success" where `Grep` was unregistered and the agent silently
  substituted `grep` via `Bash`. A treatment whose control never armed proves
  nothing — and reads as a clean result if you skip the control.

- **I can run `just switch` / `nixos-rebuild` myself — passwordless sudo granted
  (2026-07-15) — BUT only from a session NOT running inside Orca IDE.** On the
  fleet's own machines the user enabled passwordless sudo so I can apply the
  system-modifying nix flow directly (`just switch` / `just test` / `just build`)
  and verify it myself instead of handing the rebuild back. **Caveat, verified
  same day:** when the Claude session runs *inside Orca IDE*, Orca's per-terminal
  user namespace sets `no_new_privs` on every child, which blocks `sudo`
  outright regardless of sudoers — `sudo -n true` fails with "no new privileges
  flag" and `just switch` cannot run. (Same Orca-namespace mechanism that makes
  the root-owned nix store read as `nobody` and broke `~/.ssh/config` — see the
  ssh.nix materialize note.) So: default to applying rebuilds myself, but if
  `sudo -n true` fails with the no_new_privs error, I'm inside Orca — hand the
  `just switch` to the user (or they relaunch Claude from a plain terminal).

## Orca IDE — detecting the session & what it means (empirical, probed 2026-07-15)

- **Sessions may be launched from the Orca IDE instead of a bare terminal — this
  is cross-machine and cross-project (Orca runs many projects on many hosts).**
  Same shell/tools/`~/.claude` config/hooks/memory/capabilities as a terminal
  session; the difference is purely an IDE control-plane wrapper. How to tell
  you're in Orca, and what to keep in mind if you are:
  - **Detect:** `TERM_PROGRAM=Orca` (+ `ORCA_APP_VERSION`) and a family of
    `ORCA_*` env vars. Absent → treat as a plain terminal session.
  - **You are a supervised child agent, not a keyboard-attached standalone:**
    `CLAUDE_CODE_CHILD_SESSION=1` + `AI_AGENT=claude-code_<ver>_agent` are stamped
    by the outer orchestrator (absent in top-level terminal `claude`).
  - **A hook/control channel back to the IDE is open:** `ORCA_AGENT_HOOK_*`
    (an `endpoint` + `PORT` + `TOKEN`). Orca can observe/intercept lifecycle and
    tool events through it; a terminal session resolves hooks purely via
    `~/.claude`. Assume IDE-side supervision of what the session does.
  - **The session is bound to IDE UI objects,** not just a `$PWD`: `ORCA_TAB_ID`
    / `ORCA_PANE_KEY` / `ORCA_TERMINAL_HANDLE` / `ORCA_WORKSPACE_ID` /
    `ORCA_WORKTREE_ID` (workspace/worktree IDs are `<uuid>::<repo-path>` — this
    reveals which host + repo the pane maps to).
  - **Orca is a multi-runtime agent host** (could run the pane on a different
    runtime): also wires Codex (`ORCA_CODEX_HOME`), opencode
    (`ORCA_OPENCODE_CONFIG_DIR`), pi (`ORCA_PI_SOURCE_AGENT_DIR`), each with its
    own config home under the Orca user-data dir (`ORCA_USER_DATA_PATH`, e.g.
    `…\AppData\Roaming\orca` on Windows).
  - **Orca presets some session params** you'd otherwise pick yourself:
    `CLAUDE_EFFORT` (seen `high`) and `GIT_EDITOR=true` (so a bare `git commit`
    with no `-m` won't open an editor and block the agent).
  - **Consequence — no privilege escalation inside Orca:** its per-terminal user
    namespace sets `no_new_privs`, so `sudo` fails regardless of sudoers
    (`sudo -n true` → "no new privileges flag"). On NixOS this blocks
    `just switch`/`nixos-rebuild`, and the root-owned nix store reads as
    `nobody`. See the passwordless-sudo note above; detect with `sudo -n true`.
  - **To tell "inside Orca's user namespace" from genuinely-corrupted on-disk
    ownership**, check `id; cat /proc/self/uid_map`: a `1000 1000 1` remap
    means namespaced (nothing broken on disk); `0 0 4294967295` means the real
    host and a real problem.
  - Which host you're on is still the per-host memory's job (hostname / installed
    tooling / paths); this note only tells you *whether the session is Orca-wrapped*.

## Repo layout (WSL boxes)

- **Namespace folders live directly under `~/`, not `~/gh/`.** Repo clones are
  grouped by GitHub owner into per-namespace folders at the home root: `~/my`
  (`metheoryt`), `~/pure` (`thepureapp`), `~/cyphy671`, and `~/exactly`
  (`exactly-ai`, archived — kept for reference only). `~/gh/` is the **retired
  legacy location**; migrate any stragglers out of it. Each box clones only its
  relevant namespaces (personal distro: `my`, `cyphy671`; work distro: `pure`,
  `exactly`), wired by `provision/repos.sh`.

## Worktree agents under docker-compose

- **Running tests from a worktree against a compose stack: reuse, don't
  duplicate.** `docker compose run` from a worktree defaults its project name to
  the worktree's directory basename → it tries to spin up a *second* copy of the
  stateful services, which collide on any fixed `container_name` (hard error);
  and the app service's `./src` bind-mount resolves relative to wherever compose
  runs. So: force the base project (`-p <proj>`) to reuse the already-running
  postgres/redis/mongo, and override the source mount (`-v <worktree>/src:/app/src`)
  so the agent tests ITS code, not main's — miss this and it silently tests the
  wrong branch. Namespace shared state per agent (unique test-DB name, redis DB
  index, mongo db name) so parallel runs don't race.
- **A fresh worktree has only committed files.** Gitignored local config
  (`.env`, project-scope `.claude/settings.local.json` with tokens + local hook
  wiring) is absent — symlink/copy it in on worktree creation or the agent
  silently loses it.

## Docker Desktop shares one engine across all WSL distros

- **One Docker Desktop backend serves every WSL distro, and compose project name
  defaults to the checkout's dir basename — so the *same* repo cloned into two
  distros resolves to the same container/volume/network names and collides.** A
  `docker compose down -v` (or `--rmi all`) run in one distro's copy tears down
  the OTHER distro's live container, named volume, and image — they're the same
  objects. (Learned the hard way, 2026-07-07: cleaning up an old `qaz-code`
  checkout in Ubuntu-24.04 with `compose down -v` deleted the `qaz-code_db_data`
  volume out from under an in-progress overnight ingest running against the
  Ubuntu-26.04 copy. A deleted Docker named volume is unrecoverable — no trash.)
  - **How to apply:** pin an explicit `name:` at the top of each `compose.yml`
    (done for qaz-law) so a stack gets its own namespace instead of the generic
    dir-basename one; for two live checkouts of the *same* repo, give each a
    distinct `COMPOSE_PROJECT_NAME`. Before any `down -v`/prune in a duplicate
    checkout, confirm nothing else (another distro, another agent) is using that
    engine's volumes. Same dir-basename→project-name footgun as the worktree
    compose note above, different trigger.

## Gortex

- Defining the `gortex` MCP server in BOTH user scope (`~/.claude.json`, often a
  hardcoded `/nix/store/…-gortex-<ver>/bin/gortex` path) and project scope
  (`.mcp.json`, bare `gortex mcp`) makes Claude treat them as two servers with
  separate OAuth storage and trips `claude doctor`'s conflict warning — keep
  only the project-scope bare-command definition (portable, git-tracked; the
  store-pinned path also goes stale on upgrade).
- Gortex's Python resolution is near-compiler-grade for the STATIC OO layer
  (classes, methods, inheritance/MRO, imports, explicit calls, direct ORM calls
  like `Model.objects.filter`). It degrades on framework "magic" — true for
  Django/DRF especially — so trust it BY TIER, not blindly:
  - **Trust:** views/models/serializers/forms/admin classes & their methods, CBV
    mixin MRO, statically-typed manager calls.
  - **Verify (best-effort framework analyzers):** URLconf routing, DRF
    `router.register`, model↔table — check coverage with
    `analyze routes|route_frameworks|models` and spot-check against the source.
  - **Often missed or only `text_matched`:** signals (`@receiver`/`.connect`),
    reverse-FK accessors (`x.y_set`), settings string lists (MIDDLEWARE/
    INSTALLED_APPS), template-name→`.html`, `get_user_model()`/`apps.get_model()`,
    dynamic queryset methods, Celery `@shared_task`, admin auto-registration.
  - Every edge carries a confidence tier (`lsp_resolved` … `text_matched`), so
    speculative links are labelled — that's gortex's edge over grep here.
- Its **"dead code / 0 usages / safe to remove" signal is a false positive on
  framework-invoked code** (signal handlers, middleware `__call__`, dunders).
  Never act on it for decorated/framework-called code without a text-search
  cross-check.
- `graph_stats`' `semantic` block under-reports (the native `python-types` line
  can show ~0 edges); the real resolver is the `lsp-pyright` provider — judge
  coverage from `find_usages` output, not that block.
- **Build caveat (verified vasya, gortex v0.56.0, 2026-06-30):** that "real
  resolver is lsp-pyright" claim is BUILD-DEPENDENT and was false for this
  daemon. v0.56.0 ships only NATIVE semantic providers (`python-types`, etc.) —
  no `lsp-*` in `graph_stats.semantic.providers`, and the daemon log shows no
  pyright langserver spawn. Here `python-types` WAS the resolver and reported
  100% coverage (1535/1535 symbols, edges as `ast_resolved`), not ~0. So:
  installing pyright + a `pyrightconfig.json` does NOT add a gortex resolution
  tier on this build — it buys a standalone type-checker whose demanded
  annotations still help the native type-aware provider, plus gap-diagnostics.
  Before assuming lsp-pyright is live, check `semantic.providers` for an `lsp-*`
  entry and grep the daemon log for a langserver spawn.
- Integration is reproducible ONLY if `.gortex.yaml` + a gortex server entry in
  `.mcp.json` are committed. A local daemon merely *tracking* a repo works for you
  but carries nothing to teammates/CI — run `gortex init` to commit the wiring.
- **General principle — align a repo to its static analyzer.** Gortex's
  resolution quality is bounded by what the language's underlying analyzer can
  resolve (Python → `lsp-pyright`). The highest-leverage way to make a
  gortex-backed repo align better is therefore to tighten that analyzer's view:
  type hints, installed/typed deps, framework stubs. When working in a
  gortex-backed repo, treat weak resolution as fixable — proactively offer the
  alignment wins that fit its stack rather than accepting `text_matched` edges.
- **Worktree-isolated agents — don't re-index the worktree in gortex.** A git
  worktree is a new path → either untracked (graph tools off, enforcement hooks
  misfire for that agent) or a full re-index (warmup + hundreds of MB, *per*
  worktree). Avoid both: review/read agents work off the base index +
  `git diff <base>..HEAD` (review is about the change; the base graph already
  answers "who calls this / what breaks"); edit agents get graph queries that
  reflect their own uncommitted edits via **overlay-push to the base workspace**
  (`overlay_register` + `overlay_push` — a per-MCP-session editor-buffer view, no
  second index). Overlays model in-flight *unsaved* edits on the base graph; they
  are NOT a way to index an arbitrary checked-out branch's on-disk state.
- **`/gortex-align` skill does the alignment.** When a gortex-backed repo could
  be tuned — wiring not committed, or a Python project resolving to
  `text_matched` — offer the `gortex-align` skill. It detects the daemon (won't
  install the binary — that's machine provisioning), commits the
  `.gortex.yaml`/`.mcp.json` wiring, verifies index health, and for Python sets
  up pyright governance from a bundled resolution-focused `pyrightconfig.json`
  (resolution knobs like `useLibraryCodeForTypes`/venv vs gap diagnostics that
  surface every `text_matched`-bound spot; adopt at `standard`, ratchet to
  `strict`). Pyright won't load the django-stubs mypy plugin, so the "often
  missed" tier above still stands.

## Windows & WSL scripting footguns

- **Non-interactive git push over HTTPS fails on Windows.** Git Credential Manager
  (Windows Hello / TPM-protected token) needs an interactive unlock an agent shell
  can't trigger — symptoms like "could not read Username" or a Russian "ключ не
  может быть использован в указанном состоянии". Push over SSH instead
  (`git push git@github.com:owner/repo HEAD:main`); no need to change the configured
  remote.
- **Git on Windows doesn't preserve the executable bit** — a script bound for
  nixos/WSL lands `100644` and won't run there. Run `git update-index --chmod=+x
  <script>` after `git add`, or pin it via `.gitattributes`.
- **Windows `setx` silently truncates PATH at 1024 chars** — use
  `[Environment]::SetEnvironmentVariable(...)` for any long PATH edit.
- **Bare `bash` on a Windows PATH often resolves to the WSL stub**
  (`WindowsApps\bash.exe`), launching WSL instead of running the script — invoke Git
  Bash explicitly (`C:\Program Files\Git\bin\bash.exe`) when you need it.
- **WSL distro setup gotchas:** `wsl --import <name> <dest> <tarball>` creates only
  the leaf dir — the parent must pre-exist or you get `ERROR_PATH_NOT_FOUND` (use a
  user-writable path like `%USERPROFILE%\WSL` to avoid needing admin); imported
  distros boot as **root**, so set `[user] default=<name>` in that distro's
  `/etc/wsl.conf` and terminate to apply; converting a VHD to sparse
  (`wsl --manage <d> --set-sparse true`) needs `wsl --shutdown` (not `--terminate` —
  async handle release causes a sharing violation), which also stops the Docker
  Desktop backend.

## Git & bash footguns

- **`git maintenance`'s prefetch task writes hidden `refs/prefetch/*`, not
  `refs/remotes/*`** — so it deliberately does NOT update what `git status`/the
  prompt reports as "behind by N". A background loop that wants that signal needs
  `git fetch --all --prune` (updating real remote-tracking refs), which is why the
  fleet's git-autofetch uses plain fetch, not `git maintenance`.
- **bash: assigning to a variable named `GROUPS` is silently discarded** — it's a
  reserved builtin array (the caller's GID list). Use another name (`REPO_GROUPS`).
- **`gh auth switch` changes only the `gh` CLI's active account, NOT `git
  push`/`pull` auth.** For git, isolate multi-account access with per-account SSH
  host-aliases in `~/.ssh/config` (`Host github.com` vs `Host github-<alias>`, each
  with its own `IdentityFile` + `IdentitiesOnly yes`); key commit identity off the
  remote URL with `includeIf "hasconfig:remote.*.url:git@<alias>:*/**"` (git ≥ 2.36)
  so identity isolation survives repos living anywhere on disk.

## Subagent-driven development

- **Model tiering by task type** is the working convention: haiku for pure
  transcription/mechanical edits, sonnet for judgment edits and per-task review, opus
  reserved for the final whole-branch cross-cutting review.
