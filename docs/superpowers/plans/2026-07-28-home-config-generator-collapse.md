# `$HOME` config generator collapse — deferred plan

Status: **blocked by dependency, not by effort.** Created 2026-07-28 alongside
`2026-07-28-agent-config-to-dotfiles.md`, which enacts the same criterion on the
agent-config subsystem.

This document deliberately stops short of task-level TDD steps. The work cannot
be planned in that detail yet, and writing plausible-looking steps for it would
be fabrication — see §4.

## 1. The criterion, restated

Dotfiles' work-tree **is** `$HOME`, so a tracked path must be a path that
legitimately exists in a home directory. Applied to the agent config, that moved
memory, instructions, and three skills out of `machines`. Applied to the rest of
the repo, it lands on something larger: **a whole class of code in `machines`
exists only to *render* files that, by this criterion, dotfiles should simply
track.**

A renderer is not itself `$HOME` content — `modules/home/me.nix` has no rightful
home-directory path. But its *output* does. Once dotfiles tracks the output, the
renderer has no remaining job except the parts that cannot be tracked.

## 2. The inventory

Churn measured over commits since 2026-05-01.

| Renderer | churn | `$HOME` paths it produces |
|---|---|---|
| `modules/home/me.nix` | 41 | `~/.gitconfig` (via `programs.git`), `~/.config/fish/**`, `starship.toml`, `~/.config/ghostty/config` (+ a mutable `theme.conf` include), GNOME dconf (not a file — see §3) |
| `modules/home/claude.nix` | 20 | none directly — it invokes `agents/bootstrap.sh` as the single deployer |
| `modules/home/ssh.nix` | 13 | `~/.ssh/config`, materialized as a real me-owned file by an activation script |
| `modules/home/zed-bin.nix` | 11 | `~/.config/zed/settings.json` (**already dotfiles-tracked on `main`**) |
| `modules/home/codex.nix` | 9 | `~/.codex/**` (overlaps `bootstrap.sh`'s Codex block) |
| `modules/home/rustdesk-config.nix` | low | `~/.config/rustdesk/*.toml` — see §3 |
| `provision/lib/tiers.sh` `tier_shell_init` | — | `~/.bashrc`, `~/.zshrc`, `~/.config/fish/config.fish` |
| `provision/lib/tiers.sh` `tier_git_base` | — | `~/.gitconfig`, `~/.config/git/**` |
| `provision/lib/tiers.sh` `tier_ssh_accounts` | — | `~/.ssh/config` (a marker-delimited managed block) **and `~/.ssh/id_<user>` keys** |
| `provision/lib/tiers.sh` `tier_fleet_ssh` | — | **`~/.ssh/id_fleet`** |

## 3. What each renderer collapses to — and what is irreducible

**Irreducible: key generation.** `tier_ssh_accounts` mints `~/.ssh/id_<user>`
per GitHub account and `tier_fleet_ssh` mints `~/.ssh/id_fleet`. Private keys are
banned from dotfiles at the `.gitignore` deny block, which is last so it wins
under last-match-wins, and that ban is not negotiable: a leaked key means
re-keying the fleet, where a leaked token means rotating a token. These tiers
therefore survive the collapse, reduced to "generate the key if absent, register
it, print the next step".

**Irreducible: software installation.** `tier_apt_*`, `tier_brew_*`,
`tier_gortex`, `tier_agent_clis` install binaries. Untouched by this — they
produce no `$HOME` config.

**Collapses to nothing:** the config-rendering half of `tier_git_base`,
`tier_shell_init`, and the marker-block half of `tier_ssh_accounts`; and
`me.nix`'s git / fish / starship / ghostty blocks. Once the file is tracked at
its real path, rendering it is at best redundant and at worst a fight — a
renderer that rewrites a tracked file on every activation makes the 10-minute
sync timer commit churn forever.

**Does not fit the criterion cleanly, decide explicitly:**

- **GNOME dconf** (`me.nix`) is not a file. dconf is a binary database; there is
  no `$HOME` path to track. It stays in `machines` — or dies with the last
  desktop NixOS box, which is the same box being wiped.
- **`~/.config/rustdesk/*.toml`** is rewritten by RustDesk at runtime. Tracking
  it means the sync timer commits the app's own churn every 10 minutes. Either
  leave it to `rustdesk-config.nix`, or track it and accept the churn.
  `~/.config/ghostty/theme.conf` has the same shape — `me.nix` deliberately made
  it a *mutable include* so the theme could change at runtime. That design
  choice is exactly what dotfiles wants; the include, not the generated
  `config`, is the tracked file.
- **`~/.ssh/config`** is already settled and needs no decision here: it is
  **host-local**, tracked on `air`'s branch only, absent from `main` — it carries
  absolute `/Users/me` paths, air's two-account `includeIf` wiring, and this
  box's tailnet aliases. Under D5 a home-manager-owned path is simply host-local.
- **`~/.config/zed/settings.json`** is already dotfiles-tracked on `main`, so
  `zed-bin.nix`'s config half is already redundant. This is the collapse's
  existence proof.

## 4. Why this is blocked

**`modules/home/*.nix` loses its only consumer when latitude is wiped.**
Latitude is the fleet's last NixOS box; `2026-07-28-latitude-wipe-harvest.md` §4
records that it is being reinstalled as a plain-Linux headless server. At that
moment every `$HOME` path those five modules render becomes ownerless — nothing
generates it and nothing tracks it.

That makes the *destination* decision urgent (it is the reason this document
exists pre-wipe) and the *implementation* premature: which renderers still have a
consumer, and whether `modules/home/` survives at all, is not knowable until the
wipe's own blockers are resolved. Writing task-level steps against a module tree
that may be deleted wholesale would be planning fiction.

Three gates, all in the harvest document:

- **B1** — the unidentified `nvme0n1p3` LUKS partition. Blocks the wipe itself.
- **B3** — LUKS or not on an always-on headless server. Install-time, irreversible.
- **Nix surface disposition** (§4 of the harvest doc) — latitude is the only Nix
  executor, so `just quick`'s dry-build gate and `scripts/converge.sh`'s
  `touches_nix` path lose their only runner. Whether `modules/home/` is deleted
  or preserved-but-unused is that same decision, and it must be made before the
  wipe because afterwards there is no way to validate the tree in order to
  delete it confidently.

## 5. Sequence, once unblocked

1. **Resolve the harvest document's B1 / B3 / Nix-surface gates.** Nothing here
   starts first.
2. **Capture every rendered artifact from latitude while it still renders them**
   — `~/.gitconfig`, `~/.ssh/config`, the fish tree, `starship.toml`, the ghostty
   `config` — to a destination that is neither the 1TB SSD nor any disk about to
   be installed (harvest §6 step 3). After the wipe these files are not
   reproducible, because the renderer is gone.
3. **Decide shared vs host-local per path**, applying D5. Expect most of them to
   be host-local: anything carrying an absolute path, a hostname, an account, or
   a key filename is host-local no matter how generic it looks. `~/.ssh/config`
   and `~/.gitconfig` are already settled that way on `air`.
4. **Track the artifacts** on the appropriate branch, following the same
   five-beat ordering as the agent-config plan (converge first, reconcile
   divergent copies, promote last) — a checkout collision on an untracked path
   stops a box's sync entirely.
5. **Strip the config-rendering half of each tier**, leaving install + key
   generation. Update `provision/tests/tiers.test.sh` in the same commit;
   `tier_dotfiles` / `tier_dotfiles_sync` are pinned by that test and must keep
   passing.
6. **Delete or hollow `modules/home/*.nix`** according to the §4 decision. Any
   Nix evaluation gate must run on a NixOS member — which, post-wipe, may be
   none, and that is precisely the decision from step 1.

## 6. Standing note

`provision/dotfiles-sync.sh` and `agents/bootstrap.sh` stay in `machines`
permanently, criterion notwithstanding. They are the mechanisms that put content
into `$HOME` and must exist before the dotfiles repo does — a bootstrapping
constraint, not a classification one.
