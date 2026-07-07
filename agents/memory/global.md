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

## Preferences & feedback

- **Git-sync protocol — keep work synced across machines, agents do it
  themselves.** Applies to every branch in every repo:
  - **Before acting on code:** a background timer fetches every repo every ~10
    min (NixOS: `services.gitAutoFetch`; Windows: the `git-autofetch` Scheduled
    Task), so `git status` / the prompt already show "behind by N" without you
    fetching. Check that, and if behind, pull+rebase before working (`git pull
    --rebase`). Start from an up-to-date base — never commit on a stale branch.
    The timer is fetch-only (refs); it never pulls, so the actual pull is yours.
  - **After making changes:** commit and push the work yourself, without waiting
    to be told. Don't leave work uncommitted between turns.
  - **Cooldown ~10 min:** throttle these sync operations — don't pull or
    commit+push more than about once every 10 minutes. Batch changes within a
    cooldown window into a single commit rather than thrashing git on every
    micro-edit. If &lt;10 min since the last sync and nothing is mid-break, keep
    working and let the next window catch it up.
  - Scope commits to coherent units; don't sweep unrelated in-progress work into
    one commit. If the tree mixes concerns, surface it rather than lumping.

- **Never destroy the last copy of a secret.** Don't delete a backup/stash of a
  credential on the reasoning that it's "reconstructable" from other files —
  those other files can change or vanish too. Keep at least one intact copy
  until the secret is verified in its new home. (Learned the hard way: deleted
  a `settings.json.backup` holding a Sentry token, then the sibling
  `settings.local.json` copy also disappeared → token lost, user had to
  regenerate.)

- **Verify Claude Code's file-reading before designing around it.** Empirically
  confirmed for a user config dir (`CLAUDE_CONFIG_DIR`): only `settings.json` is
  read at the config-dir ROOT — a config-root `settings.local.json` **and** a
  config-root `.env` are NOT read. Reliable ways to get env into a session (and
  its Bash-tool subprocesses): (a) a var in the launching process env, or
  (b) a PROJECT-scope `<repo>/.claude/settings.local.json` `env` (this is the
  one place `settings.local.json` is honored). Test with a throwaway
  `CLAUDE_CONFIG_DIR` + `printenv` probe rather than assuming.

- **Reflect between work chunks, then file learnings by scope.** At natural
  breakpoints (a task finished, before switching context), pause and look back
  over the session: pull out the durable learnings, and for each decide scope
  and write it there — cross-project → `memory/global.md` (facts/prefs) or
  `memory/practices.md` (coding practice); repo-specific → that repo's project
  memory (`.claude/memory/project.md`, or its `CLAUDE.md`/`AGENTS.md`). A
  proactive ritual, not only opportunistic capture when something happens to
  stand out. Skip anything derivable from code/git history or that only matters
  to the current conversation. Keep the step quiet — do the reflection and
  writes, then report in a couple of notes, not a page-long summary.

## Repo layout (WSL boxes)

- **Namespace folders live directly under `~/`, not `~/gh/`.** Repo clones are
  grouped by GitHub owner into per-namespace folders at the home root: `~/my`
  (`metheoryt`), `~/pure` (`thepureapp`), `~/cyphy671`, and `~/exactly`
  (`exactly-ai`, archived — kept for reference only). `~/gh/` is the **retired
  legacy location**; migrate any stragglers out of it. Each box clones only its
  relevant namespaces (personal distro: `my`, `cyphy671`; work distro: `pure`,
  `exactly`), wired by `provision/repos.sh`.

## Shipping & deployment defaults

- **Default on push: ship to production, not just to git — overridable per
  repo.** When work lands on a repo's main branch, "ship it" defaults to
  getting the change actually running in prod if that's reachable from the
  current session, not merely landing the commit.
  - **Why:** confirmed default, 2026-07-04 (embedthat-bot audio-pager
    delete-and-resend work) — the user's "ship it" meant deploy, not just
    push. A repo's own `CLAUDE.md` / project memory can override this (e.g.
    team repos with staging gates or an explicit manual-deploy process).
  - **How to apply:**
    - After pushing, check for an existing deploy path in the repo (a CI
      workflow, `docker-compose` targeting a prod host, a known running
      container) and use it if reachable this session.
    - If no ship-on-push automation exists yet, **offer** (don't silently
      set one up) to wire a GitHub Actions workflow that ships on every
      push/merge to main. This fits mostly personal projects — hold off on
      team repos with review/staging gates unless asked.
    - If prod runs a container image watched by an auto-updater, prefer
      shipping via the registry: build + push the image (via CI when
      feasible, not a manual local `docker push`) so the watcher pulls the
      new tag and restarts the container. The concrete registry + watcher
      belong in that repo's own project memory.

## Communication — professional tone (outward-facing)

- **Applies to everything a human other than me reads** — PR titles/bodies,
  commit messages, Jira/Confluence comments, Slack, email, review comments.
  NOT in-session chat replies to me. This generalizes the pure-dev
  review-voice card + the PR "why, not what" rule into one tone for all such
  output; the plugin's `review-voice.md` stays the detailed, review-specific
  version.
- **Lean.** As few sentences as carry the point; cut preamble, restatement,
  and ceremony. Say *why*, not *what* — the diff / thread / artifact already
  shows the what.
- **No hype, no padding.** Don't inflate praise; no marketing gloss,
  superlatives, or filler adjectives. Plain over clever; obvious beats terse.
- **Honest and humble.** When I might be missing context, say so — it invites
  correction. Don't overstate confidence or paper over unknowns.
- **Opinion, not orders — but direct when it's clear.** For judgment calls,
  convey a view and let the reader decide. When something is plainly right or
  broken, say it directly. Directness tracks stakes: soft/optional on
  low-stakes, unambiguous on important. Courteous throughout.

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
