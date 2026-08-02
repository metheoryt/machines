<!-- Produced 2026-08-03 by a 24-agent review workflow on branch repo-review-cleanup.
     Coverage was enforced mechanically: 240 tracked paths in, 240 ledger rows out, 0 gaps.
     One agent (the `backups` suspicion) failed its schema-retry cap and was re-run separately;
     see the Backups section for which text came from which pass. -->

# machines — whole-repo review

## Verdict in five lines

`machines` is a working cross-platform provisioner for four boxes, wrapped in a large and unmaintained archive of its own history: 240 tracked files, 113 of them Markdown, 90 of those dated plans and specs of which **not one carries a status marker**. The code is in better shape than that ratio suggests — 135 files earned a clean `keep`, all 28 suites the gate reaches are green, and `provision/lib/tiers.sh` carries ~508 lines of measured-failure rationale that is the repo's single most valuable asset. What it has drifted into is a repo that **describes itself four times over and checks itself once, badly**: `just test` reaches 28 of 38 suites, `provision --apply` exits 0 for four of latitude's seven roles, and every one of the four boxes carries load-bearing state that no file in either repo declares. The most important thing to do about it is not in the ledger: this review found live faults — a backup hub down since 2026-08-02, a fleet member frozen 28 commits behind on one empty file, a cron branch that silently never runs — that outrank all 86 `rewrite` verdicts combined. **Fix the live faults, make the gate honest, then treat the documentation sweep as the slow background job it is.**

---

## Coverage

**240 tracked paths, 240 ledger rows, zero gaps.** I reconciled this by subtree rather than taking it on trust: 14 root-config (9 root files + 3 `.claude/` + `.gemini/` + `.superpowers/`), 26 `agents/` non-plugin, 31 `agents/plugin/`, 4 top-level `docs/`, 1 handoff, 45 plans, 44 specs, 58 `provision/`, 11 `hosts/`, 3 `install-media/`, 3 `scripts/`. Each count matches `git ls-files` exactly. **No tracked path went unreviewed.**

| Verdict | Count |
|---|---|
| keep | 135 |
| rewrite | 86 (one is a `rewrite->` retarget to another file) |
| needs-decision | 11 |
| delete | 6 |
| merge-> | 2 |

**The real gap is a modality, not a path.** The `backups` worker returned nothing. One of the three named suspicions got no first-class pass, and backups are half this repo's stated purpose. The section below is synthesised from four other workers' incidental findings; it is not the pass that was asked for.

**Untracked and ignored surfaces were never inventoried by any worker.** I checked: `git status --porcelain -uall` returns **0** — there are no untracked non-ignored files, which is a clean result worth stating rather than assuming. Four ignored paths exist and none was rowed: `.claude/settings.local.json` (5 lines), `.machines/` (live convergence state, stale-dated Aug 1), `agents/plugin/skills/orca-repair/__pycache__/*.pyc` (24 KB of build junk), and `provision/secrets/authkey` — an 88-byte reusable Headscale pre-auth key, correctly ignored, sitting on the primary dev box a week after the enrollments it was minted for completed.

**A parallel worktree was missed by every worker.** `git worktree list` shows `/Users/me/orca/workspaces/machines/machines-cleanup` on `metheoryt/machines-cleanup`, three commits ahead, touching exactly `provision/lib/tiers.sh` (+32/−3) and `provision/README.md` (+10/−2) — two `rewrite` rows. One of its commits refutes a drift finding (see below).

**Boxes examined:** latitude (ssh, read-only), air (local), hub (ssh, read-only), desktop-native (Git Bash via PowerShell), desktop-wsl (ssh). All four fleet members plus the WSL child were reached. `server`/g513ie was deliberately not examined — the C: review is the user's. One prescribed check was never run despite the worker being on the box: `git config core.symlinks` and `file CLAUDE.md` on desktop, which decides whether the repo's agent-instruction contract functions at all on the Windows checkout. That is a one-command gap, not an unreachable one.

---

## The three suspicions — confirmed or ruled out

### Git-sync timers — **RULED OUT as duplication. One narrow overlap CONFIRMED, two defects found underneath.**

The three ~10-minute jobs are three genuinely different jobs that share a cadence.

| | git-autofetch | fleet-selfpull | dotfiles-sync |
|---|---|---|---|
| **Scan roots** | `$HOME`, `find -maxdepth 4` — every repo incl. work checkouts | `$HOME my pure cyphy671 exactly`, depth 2, excludes `*thepureapp/*` and any repo with no upstream | exactly one: `$HOME/.dotfiles` bare, work-tree `$HOME` |
| **Writes** | fetch only, never touches a work tree | `merge --ff-only`, gated on branch==main + clean tree | the only one that commits and pushes |
| **Exit contract** | 1 only if **all** fetches fail (a masked `timeout` once made every fetch fail while launchd reported healthy) | non-zero on a real fetch error (always-0 let latitude sit 23 commits behind under a green unit) | **always 0**, even on conflict or failed push (both recur every tick; non-zero paints the timer permanently red) |
| **Unique safety gate** | shallow-clone skip (a `--depth 1` clone ballooned 60M→350M irreversibly) | not-main / dirty / diverged skip taxonomy | lock + 30-min stale sweep (no flock on macOS), enrollment guard, commit debounce, `merge-tree --write-tree` conflict preflight, vanished-tree guard |
| **State** | none | none | `$XDG_STATE_HOME/dotfiles-sync/{branch,lock,pending.hash,pending.since,conflict}` |
| **Cadence** | OnBoot 2min / 10min, jitter 30s | OnBoot 2min / 10min, jitter 2min | OnBoot 3min / 10min, jitter 2min |
| **tiers.sh lines** | 177 | 78 | 58 |

**Can they collapse, and what is lost?** No — and the exit-status row is why. One systemd unit cannot simultaneously go red only on total failure, go red on any fetch error, and stay green on conflict; each of those three contracts is documented against a specific past incident. Collapsing loses one capability per job. What *can* collapse is the **scheduler-install cascade**: `tier_autofetch:862-902`, `tier_selfpull:1193-1240` and `tier_dotfiles_sync:1343-1380` triplicate the same darwin/systemd-user/cron/warn arms, and only the launchd arm was ever factored out into `_launchd_periodic`. A `_schedule_periodic` helper removes roughly 100 of the 313 lines without touching a single job semantic. That is a factoring problem, not a formalism one.

`scripts/converge.sh` is **not a fourth timer** and does not belong in the comparison. It has no schedule anywhere: on POSIX it is fired detached from `agents/git-hooks/post-merge`; on Windows it is a trigger-less Scheduled Task fired by `schtasks /run`. The chain is a pipeline — selfpull moves HEAD → post-merge fires → converge applies — and the coupling is explicit in code (`tier_selfpull`'s `KillMode=process` exists so the detached converge is not SIGKILLed).

**The genuine overlap:** autofetch and selfpull fetch the same repos (`~/machines`, `~/my/vps`) on the same uncoordinated 10-minute cadence with the *same* systemd `OnBootSec=2min`. `provision/fleet-selfpull.sh:51-61` is a sleep-and-retry that exists solely to absorb the resulting `cannot lock ref` race — the only place in the repo where one scheduled job's implementation is shaped by another's existence. Stagger the boot offsets; keep the retry as defence in depth.

**Two defects surfaced while verifying.** (1) `tier_dotfiles_sync` appears in **no profile tier list** — on air and hub it is installed only by a one-time role run and convergence never refreshes it. Confirmed live on air by plist timestamps: git-autofetch and fleet-selfpull are both dated 2026-08-01 10:28; dotfiles-sync is dated 2026-07-28 18:38. Three reprovisions have refreshed two of three plists and never touched the third. (2) The cron fallback in `tiers.sh:1232` and `:1372` emits an unescaped `%`, which crontab(5) treats as end-of-command — confirmed live on desktop-wsl, whose journal logs `CMD (sleep $((RANDOM )`. On any box without a systemd user manager, fleet-selfpull and dotfiles-sync are scheduled and never execute.

### The `beat` service — **RULED OUT. Wrong repo and wrong function.**

`beat` does not exist in `machines`. `git ls-files | grep -i beat` returns nothing; all 14 textual hits are English prose or cross-references from migration paperwork. It lives at `~/my/vps/homeserver/beat/` and it is **not a heartbeat** — it is a busybox-crond launcher container whose single task (`tasks/reboot-archer.py`, `# cron: 0 6 * * *`) reboots the household TP-LINK Archer C20i over HTTP once a day. It is deliberately stopped by user decision 2026-08-01 and absent from every reachable box: not in latitude's 22 containers, not in hub's units, not in air's launchctl. There is nothing to clean up here and no redundancy with the statusboard, the three timers, or Tailscale keepalive. The premise was wrong on both counts; the classic machines/vps boundary error is exactly what happened, because the migration docs *in this repo* name the service.

If the intended target was "a homegrown periodic mechanism an off-the-shelf tool could replace," the live candidate is the timer triad above — and the answer there is also no.

### Backups — **PARTIAL, and the most alarming section in this document.**

No first-class pass ran. What four other workers found incidentally:

- **The `backup-hub` role's own service is down.** `restic-server` on latitude exited 255 at 2026-08-02T10:53:17Z with `failed to bind host port 100.64.0.8:8001/tcp: cannot assign requested address` — a boot race where docker starts before tailscaled assigns the CGNAT address. **RestartCount is 0** after 10.5 hours, disproving the `restart: unless-stopped` comment in the vps compose file that claims to cover exactly this. Every other container on the box started at 10:53:20 and is up. Timing matters: desktop-wsl's last *successful* backup was 06:00 that same morning, before the hub died — the 2026-08-03 06:00 run is the first that would fail, and nothing alerts.
- **hub carries `backup-client` and nothing backs it up, on either side of the boundary.** No restic/resticprofile/borg/rclone binary, no timer, no cron, no `~/.config/restic*`; and `~/my/vps/backup/` holds profiles for `homeserver` (a retired name), `latitude` and `wsl` only. What is unprotected: `/var/lib/headscale/db.sqlite` — the only copy of the fleet's tailnet control plane — plus `derp_server_private.key`, `noise_private.key`, the AWG peer configs, and an undeclared `proxy-config` volume. Losing that VPS loses the tailnet's identity.
- **air has no backup at all** and no profile in vps `backup/`. It is the primary dev box. No worker flagged this; it falls out of the profile listing.
- **desktop-wsl backs up successfully under a role its `fleet.json` entry does not declare**, and its snapshots land under `/g614jv` because `{{ .Hostname }}` on WSL expands to the Windows hostname — the exact templating gotcha `CLAUDE.md` documents, live in a backup path.
- **latitude's backup-client works and is entirely undeclared in `machines`**: a hand-placed 21 MB `/usr/local/bin/resticprofile` plus four systemd units generated from the vps profile. Local repo `/mnt/spare320/restic/latitude`, 3 snapshots, last clean at 04:30.
- **`backup-hub` has no executor anywhere**, and `provision.sh`'s fallback arm never sets `rc`, so `just provision --machine latitude --apply` reports success while doing nothing for the role that names the box.
- `mirror-refresh` (daily 03:30) and `archive-mirror` (monthly) are healthy and their units are byte-identical to the repo copies — but `/mnt/xs`, the archive target, is **95% full with 36 GB free**, recorded nowhere.

A backups pass spanning both repos — every client/target pair, last successful snapshot, reconciled against the `backup-hub`/`backup-client` role declarations — is still owed.

---

## Live-vs-declared drift

### latitude (Debian 13.6, 100.64.0.8) — declared tiers honoured; the substrate is undeclared

Almost every declared tier verifies: battery Custom-mode cap live (`start=80 end=85 charge_types=[Custom]`), RAPL reader, sudo NOPASSWD, apt/statusboard packages, shell_init, ssh_accounts, ssh_trust, dotfiles on branch `latitude`, all three user timers healthy, both backup units byte-identical to the repo, zero failed units in either scope.

**Undeclared, and the list is long.** The entire Docker substrate (5 apt packages, 21 containers, 7 compose projects) is declared in **neither** `machines` nor `vps`. Tailscale, plus an `/etc/systemd/system/tailscale-autoconnect.service` whose Description says "Auto-enroll this **WSL distro**" — hand-copied from `tailscale-wsl.sh` onto bare metal. restic + resticprofile + four units. `rsync` and `exfatprogs`, which this repo's own enabled timers hard-depend on (`rsync -aHAX`; `/mnt/xs` is exfat) and which appear in no tier. An autologin kiosk on tty1 sitting in front of `me ALL=(ALL) NOPASSWD: ALL`. A stale `statusboard.service` installed-but-disabled.

**The flagship.** `AGENTS.md:283-287` asserts as established fact that latitude never sleeps — four logind `ignore` settings plus three masked sleep targets. The box is configured exactly that way, via `/etc/systemd/logind.conf.d/99-server.conf`. **Nothing in the repo writes it**, and that path appears nowhere in the tree. A reinstall that follows the repo produces a services host that suspends on a lid close, with no error.

**Declared but absent:** `backup-hub`, `ssh-server` and `base` have no executor; `--apply` exits 0 for all of them. `~/.ssh/config`'s fleet span is hand-written (tier_fleet_ssh is darwin-only) and two of its parts are stale — its "MagicDNS cannot work here" rationale has expired (dhcpcd is inactive, `/etc/resolv.conf` says "generated by tailscale", all `*.gg.ez` names resolve), and it uses the nickname `desktop-ubuntu26`. Its `Host g513ie server` block is unmanaged but **load-bearing** — do not prune it, it is latitude's only route to `server` for the pending C: review.

### air (macOS, 100.64.0.7) — eleven of thirteen tiers clean; two things it cannot work without are unprovisioned

Verified clean: every brew formula, git config, gortex at the pinned `0.61.4`, the `~/.claude` link shape exactly as `bootstrap.sh` specifies, `core.hooksPath` set, all three launch agents healthy.

**`just` is installed by hand and no tier on any platform installs it.** The repo's entire 16-recipe command surface, including THE gate, is unprovisioned. **Tailscale likewise** — `tier_brew_cask`'s loop is `docker-desktop` only — so a Mac finished by `bash provision/macos.sh` ends with an `~/.ssh/config` full of `*.gg.ez` names it cannot resolve.

**Correction to the air report:** it lists `node` among undeclared hand-installed leaves and says "not required by anything here." That is refuted by the repo's own unmerged history — `cc826f9` on `metheoryt/machines-cleanup` adds `nodejs`/`node` to both dev tiers, with a commit body recording that a plugin's SessionStart hook failed on every session on air with `node: command not found`. The gap is closed on a branch nobody merged.

**Declared but absent:** `~/.ssh/authorized_keys` still trusts `methe@server`, which `provision/fleet-authorized-keys` no longer declares — latent only because sshd is not listening. `base` and `ssh-server` have no executor, and sshd being off means the box every other member's generated config names as `air.gg.ez` is unreachable. The fleet-ssh span still carries a `Host server` block — confirmation of a documented prediction, not a new defect. Leftovers: a 39 MB `chezmoi` binary from a mechanism retired 2026-07-28; an undocumented tailnet node `ipheoryt12` at 100.64.0.5.

### hub (Debian 12.15, 100.64.0.1) — least drifted on the declared axis, worst exposure off it

All eight hub-profile tiers materialised faithfully; the six unit files are byte-identical to the `tiers.sh` heredocs including `KillMode=process` and the pinned `Environment=FLEET_ROOTS=/home/debian/machines`; zero failed units.

**`PasswordAuthentication yes`** on the fleet's only internet-facing box, from a 27-byte cloud-init drop-in written 2025-02-17 and never revisited because the `ssh-server` role that would revisit it does not exist. Root is locked, but the `debian` account has a usable password *and* passwordless sudo, and nothing filters packets (`iptables -P INPUT ACCEPT`, no ufw, no nft filter table). An **`mtproto-proxy` container** on `0.0.0.0:8443` with an empty label set, belonging to no compose project in either repo — started by a bare `docker run` and reproducible from nothing.

**hub's `~/vps` is 4 commits behind and nothing will ever pull it.** Structural: hub lacks the `repos` role and `tier_selfpull` is deliberately pinned to `%h/machines`. The repo defining headscale/caddy/awg/rustdesk on that box drifts indefinitely. Also: a `me@desktop-wsl-ubuntu-26-04` key **outside** the managed trust span, which `tier_ssh_trust` structurally cannot revoke (already tracked as roadmap P6); six `authorized_keys` backup files; a stray 52 MB non-executable `~/caddy` alongside the apt one.

### desktop + desktop-wsl (100.64.0.4 / .6) — the Windows side is excellent; the WSL child is frozen

Windows-native is in the best shape of the fleet: clone clean on main at origin HEAD, converge `status=ok`, all three declared Scheduled Tasks returning `0x0`, and `windows.ps1` step 6 fully converged — sshd Automatic/Running, firewall scoped to `100.64.0.0/10` + `192.168.8.0/24`, default Any-rule disabled, password auth off, `administrators_authorized_keys` byte-identical to HEAD's 4-key trust file.

**desktop-wsl has not advanced in ~35 hours and is 28 commits behind**, because one untracked zero-byte `.zed/tasks.json` trips `selfpull_one`'s dirty gate. The journal holds **185 consecutive `SKIP dirty` lines and zero OK lines**, while the timer, the service and `.machines/last-converge` all report success. `.gitignore` covers `.idea/`, `.vscode/` and `*.sublime-*` and has **no Zed entry** (verified). The security consequence: `methe@server`'s key is still trusted on that box because the revoking commit is one of the 28 unpulled — the revocation mechanism works (the Windows side proves it) but reads the clone's copy of the key file, and the clone is frozen. The box also still runs pre-`65aac22` provisioning code, including the `set -u` UTF-8 bug the suite caught.

**A phantom Scheduled Task:** `git-autofetch` fires every 10 minutes at `scripts\git-autofetch.ps1`, returns `0xFFFD0000`, and reads `State: Ready`. That path has existed at no revision since `f3d63b2`; nothing in the repo registers the task; there is no Windows git-autofetch code left to repair it from, and the runbook's instructions for fixing it point into the deleted `modules/` tree. This is the mirror-refresh lesson repeating on another box.

**Also:** git-autofetch is genuinely double-scheduled on desktop-wsl (systemd timer *and* an active cron line, both firing ~1 min apart, because WSL gained `systemd=true` after the first provisioning run and `tier_autofetch` never removes the fallback). `fd_wsl_hosts` **boots stopped WSL distros** as a side effect of ordinary read-only fleet tooling. `hosts/desktop/windows/install.ps1` — the documented public bootstrap one-liner — throws unconditionally at line 67 handing off to a `restore.ps1` that exists at no revision. gortex on Windows is at 0.61.0 against a 0.61.4 pin with no installer on that path.

---

## What to act on, ranked

**Read this list as ordered by live consequence, not by ledger verdict.** The top items come from the drift reports and the completeness critic, and several touch files the ledger marked `keep` or scoped a `rewrite` too narrowly. Where the two disagree, this list is the reconciliation.

### Tier 1 — live faults

**1. Restore the restic REST hub on latitude, and fix the bind race properly.**
*Changes:* in the vps repo, either bind `0.0.0.0:8001` and let the tailnet ACL/firewall scope it, or add an ordering dependency on `tailscaled` (a systemd drop-in or an entrypoint retry loop). Then restart the container.
*Why:* `backup-hub` is the role that names latitude; it has been down since 2026-08-02 10:53 and `restart: unless-stopped` demonstrably does not cover the boot race.
*Cost:* one compose edit plus a restart.
*Breaks:* binding `0.0.0.0` widens exposure on a LAN-attached box — prefer the ordering fix. Verify by rebooting and checking the container comes up, not by restarting it by hand.

**2. Add `.zed/` to `.gitignore`, and clear the untracked file on desktop-wsl.**
*Changes:* one `.gitignore` line; `rm -rf ~/machines/.zed` on the box (or commit it — it is a zero-byte file).
*Why:* unfreezes 28 commits including the `methe@server` revocation and the `set -u` fix. **This supersedes the `.gitignore` ledger row's scope**, which certified the surviving stanzas as "accurate and verified live" while the missing line was freezing a fleet member.
*Cost:* minutes.
*Breaks:* nothing. Pair it with the next item, because `SKIP dirty` will do this again.

**3. Make `SKIP dirty` visible in fleet-selfpull.**
*Changes:* count consecutive skips per repo and escalate — a non-zero exit, or a warning line the journal makes greppable, after N ticks.
*Why:* 185 silent skips under a green timer is the same failure class `fleet-selfpull.sh`'s own header was written to prevent ("the same silent failure that let latitude sit 23 commits behind"). The 2026-07 fix separated fetch failures from skips and left skips silent and unbounded.
*Cost:* ~10 lines plus a test.
*Breaks:* a deliberately-dirty repo now generates noise. That is the point; make the threshold generous.

**4. Escape the `%` at `tiers.sh:1232` and `:1372`.**
*Changes:* `%%` → `\%%` in the two `printf` cron lines. Verified present in both.
*Why:* cron truncates at the unescaped `%`, so on any box without a systemd user manager `fleet-selfpull` and `dotfiles-sync` are scheduled and never run.
*Cost:* two characters.
*Breaks:* nothing; `tier_autofetch`'s cron line has no `%` and already works, which is why only these two are inert.

**5. Decide the Windows `git-autofetch` task: remove it, or restore the script.**
*Changes:* either `schtasks /delete /tn git-autofetch` on desktop and strike the runbook step, or restore `git-autofetch.ps1` from tag `nixos-final` into `provision/` and register it from there.
*Why:* it fails every 10 minutes with `0xFFFD0000` while reporting `Ready`, and the only repair instructions point into a deleted tree.
*Cost:* small either way.
*Breaks:* removing it loses nothing operationally — the `fleet-selfpull` task already fetches. Removal is the honest answer.

### Tier 2 — cheap, safe, mechanical

**6. `provision.sh`'s fallback arm sets `rc=1` under `--apply`.**
*Changes:* two lines at `provision.sh:83-88`, plus an explicit opt-out (e.g. a `"planned"` list) so a known stub is a deliberate declaration rather than a silent one.
*Why:* `just provision --machine latitude --apply` reports success while doing nothing for four of seven roles. `provision.sh:43-47` already fixed this exact class one level up for an unknown *machine*, with a comment naming the failure; the guard was never applied to roles.
*Cost:* trivial. *Breaks:* every `--apply` on latitude/hub/air now exits non-zero until the opt-out list is populated — do both in the same commit.

**7. Widen the `just test` glob from 28 to all 38 suites.**
*Changes:* replace the four hand-listed directories at `justfile:55-56` with a recursive find; rename `agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh` to `*.test.sh`; add the assertion to `provision/tests/justfile.test.sh` so this cannot silently regress again.
*Why:* the recipe's own comment says a hand-listed set makes "coverage silently stop growing" — which is exactly what happened. **Two workers independently ran all ten orphaned suites by hand and all ten pass**, so this is low-risk. Disregard the one group note claiming the hook test writes into the real `~/pure/backend-api` — that test redirects `$HOME` into a `mktemp -d` at its lines 16-21.
*Cost:* one recipe edit plus one rename. *Breaks:* nothing measured. `test_distill.py` stays out (see the judgement calls).

**8. Make `dotfiles_sync` reachable from the driver on air and hub.**
*Changes:* add the `dotfiles` tier to `macos.sh`'s workstation list and `linux.sh`'s hub list (it reaches `tier_dotfiles_sync` transitively, matching how workstation/server already do it).
*Why:* convergence runs the driver, never the role dispatcher, so on those two boxes the timer is installed once and never maintained — the air plist has not been touched in three reprovisions.
*Cost:* two lines. *Breaks:* **coupled edit** — `provision/tests/tiers.test.sh:35-38,57-60` pin both lists by exact string and go red otherwise. Also note `tier_dotfiles:1258` hardcodes the platform as `wsl`; harmless today, worth fixing while you are there.

**9. Fix `agents/.gitignore:9`.**
*Changes:* move the trailing comment onto its own line above the pattern.
*Why:* gitignore does not strip inline comments, so the pattern is the whole line. Verified: `git check-ignore -v agents/settings.local.json` returns **NOT IGNORED**, and the root `.gitignore:39` rule covers a different path. It is the one line in that file with an inline comment, and it is the one the comment itself calls secret-bearing.
*Cost:* one line. *Breaks:* nothing.

**10. Force `tier_ssh_trust` on air to drop `methe@server`.**
*Changes:* re-run the tier (or the whole macos driver) on air; desktop-wsl gets it from item 2.
*Why:* the revocation is correct in the repo and has not propagated. Latent while sshd is off; live the moment `ssh-server` is implemented — and `server` is still powered on at 100.64.0.3.
*Cost:* one run. *Breaks:* nothing; the span rewrite is wholesale and idempotent.

**11. Clear the junk, and decide the authkey.**
*Changes:* delete `statix.toml` (a Nix linter, zero `.nix` files, and neither invocation path it names exists) and the stray `.pyc`. Shred `provision/secrets/authkey` if the key is spent — Headscale pre-auth keys are revocable on hub and re-mintable per `provision/README.md:352`.
*Cost:* minutes. *Breaks:* nothing.

**12. Resolve `metheoryt/machines-cleanup` before editing `provision/lib/tiers.sh` or `provision/README.md`.**
*Why:* it is 3 commits ahead and already editing exactly those two files. Merging it also closes the `node` gap the air drift report reports as open.
*Cost:* a merge or a decision to abandon. *Breaks:* editing those two rows first guarantees a conflict.

### Tier 3 — real work with a clear payoff

**13. Close the four measured coverage gaps — but as three separate decisions.** Add `just` to `tier_brew_dev` and `tier_apt_dev` (one line each; the gate's own runner being unprovisioned is the most embarrassing gap in the repo). Add `rsync` to `tier_apt_min` and `exfatprogs` to the server profile, and consider a precondition check in `install-timers.sh` instead — that script is a deliberate hand-run, so the accurate claim is "an operator who follows the repo installs timers that fail on first fire," not "a reinstall boots broken." **Tailscale is not a package line** — there is no darwin and no bare-metal-Debian installer, enrollment is a flow, and `tailscale-mac.sh:13-16` records a real decision (no `--authkey` flag; argv is world-readable via `ps`). Put it on the roadmap next to P3.

**14. Implement the `ssh-server` role.** Two written specs already exist: `docs/2026-08-01-nixos-harvest.md` §1 gives the firewall shape (port 22 on `tailscale0` only, one verbatim `192.168.8.0/24` carve-out, password *and* keyboard-interactive both off, keys from `provision/fleet-authorized-keys`) and `docs/superpowers/specs/2026-07-17-fleet-ssh-tailnet-retire-awg-design.md` §A adds the rationale the harvest omits. **hub needs its own arm** — it must stay reachable off-tailnet, and it is the box currently running `PasswordAuthentication yes` with a password-bearing sudo account. Cost: real, but it is the role with the most spec and the least code. Breaks: get hub's arm wrong and you lock yourself out of the VPS — stage it with a second session open.

**15. Give hub a backup, and run the backups pass.** hub holds the only copy of the tailnet's identity and has no backup on either side of the boundary. Add a `hub` profile in `~/my/vps/backup/` and a client here. Then do the full pass: every client/target pair, last successful snapshot, reconciled against the role declarations — including air, which has neither.

**16. Fix the four contradicting documents in one pass, not one at a time.** `docs/fleet-roadmap.md:89-100` and `docs/2026-07-drive-migration-log.md:20,207-219` both state a pre-2026-08-01 restic world that the roadmap's own lines 118-128 overturn. A session grepping "restic" across `docs/` gets two stale hits and one current one; fixing one leaves the trap. Also repoint P2's header (it says "see the Forgejo item" when the real gate is C:), and reconcile AGENTS.md's "27 suites" (line 82) vs "28 suites" (line 132) — the true number is 38 tracked, 28 reached.

**17. Address the ~140 KB session-start load.** `AGENTS.md` (296) + `README.md` (195) + `.claude/memory/project.md` (1664) ≈ 2150 lines describing the same repo, two of them injected into *every* session — `CLAUDE.md` via memory discovery and `project.md` `cat`ed verbatim by `project-memory-check.sh:34`. `project.md` was deliberately pruned to 456 lines on 2026-07-24 and is 3.6× that nine days later, still tracking "Drop pylspFixOverlay from flake.nix" against a file that does not exist. This is the mechanism behind roadmap P5's measured cost — the answers are present but buried. Set an explicit division of labour: README = newcomer orientation, AGENTS.md = agent operating rules, project.md = durable decisions only, hard-capped.

**18. Status-banner the 90 plans and specs — group (b) first.** Two populations hide inside the 86 rewrites. *Implemented-and-accurate* needs a one-line `DONE` header. *Implemented-then-deleted-or-reversed* is actively misleading — chezmoi (built, then explicitly repudiated at `roles/dotfiles.sh:1-7`), phase5a, the `hosts` role (built in three commits, then retired in `52b66d8`), gortex-align, orca-serve. An agent reading those builds a false model and hunts for machinery removed on purpose. A four-word vocabulary covers everything: `DONE` / `DONE-THEN-SUPERSEDED-BY-<path>` / `ABANDONED` / `OPEN`. The repo already has the model banner at `specs/2026-07-08-fleet-provisioner-phase3-dotfiles-chezmoi-design.md`. **Reconcile the apparent convention conflict once, in writing**: `plans/2026-07-20-fleet-hostname-normalization.md:17` and its spec at :115 say plans/specs are "dated history; not rewritten" — that rule is scoped to *rename sweeps* and forbids rewriting bodies, not adding headers; roadmap P5:367 is newer and asks for exactly a status line. Say so, or the next agent stalls on the same contradiction. **Cheaper alternative worth considering first:** a generated `docs/superpowers/README.md` index (path, date, one-line status) closes P5's cost for less than 90 hand-edited headers. Also note checkboxes are noise — one finished plan sits at 53/53, another at 8/79, and two completed ones at 0/66 and 0/38.

**19. Factor `_schedule_periodic`.** ~100 of the 313 timer lines, mechanical and testable, with `provision/tests/git-autofetch.test.sh` already demonstrating how to test an extracted heredoc.

**20. Close the PowerShell coverage hole.** `windows.ps1` is 25 KB and is desktop's entire provisioning path with zero tests; so are `dotfiles-sync.ps1`, `fleet-selfpull.ps1`, `provision.ps1`, `roles/*.ps1` and `Fleet.psm1`. The repo already knows the pattern — `provision/tests/fleet-ssh-config-ps.test.sh` runs a module's `-SelfTest` when pwsh is present and asserts platform-independent invariants unconditionally. It was never applied to the sync pair, which is why `fleet-selfpull.ps1` still carries the bare `git pull --ff-only` its POSIX twin removed months ago, and why `Fleet.psm1` still lacks the unknown-machine guard `fleet.sh:52` has.

### Tier 4 — the judgement calls

**The delete precedent — one question, not six rows.** `git log --diff-filter=D` over `plans/` and `specs/` returns exactly one commit, and it is a same-day rename. **No plan or spec has ever been deleted from this repo.** Four of the ledger's six deletes sit under that tree, and two of those contradict their own author's group note in the same submission. *My recommendation:* banner the four (`handoffs/2026-07-17-…`, `specs/…pre-commit-hooks-design`, `specs/…gortex-align-type-agnostic-design`, `specs/…orca-serve-wsl-design`) rather than delete them — the reasoning in each is why the corresponding code is gone, and gortex-align's spec is better *moved* to `~/.claude/skills/gortex-align/` (a dotfiles commit) than destroyed. Delete `statix.toml` outright. Delete `.superpowers/sdd/progress.md` — but for the **corrected reason** (superseded by the plan-scoped-workspace layout, not merely "finished") **and pair it with adding `.superpowers/sdd/` to `.gitignore`**, which the owning skill's own script header prescribes and which this repo lacks. If you want to break the never-delete precedent, do it knowingly and say so once at the top of the ledger.

The eleven `needs-decision` rows, each with my recommendation:

| # | Path | The question | My recommendation |
|---|---|---|---|
| 1 | `.gemini/settings.json` | Do you still drive Gemini here? No tier or bootstrap step installs the CLI on any box. | **Delete** unless you use it — it is a fourth agent config nothing provisions. Also note it hardcodes `GORTEX_INDEX_WORKERS: 8` where `.mcp.json` makes it overridable. |
| 2 | `agents/plugin/commands/.gitkeep` | Keep an extension point that has never held a file? | **Keep.** `agents/README.md:51` documents `commands/` as part of the plugin's structural contract; dropping it is a two-file change for zero gain. |
| 3 | `agents/plugin/skills/kb-refresh/tests/test_distill.py` | Add pytest to the toolchain, or rewrite importlib-style? | **Rewrite importlib-style**, following `orca-repair.test.sh`'s heredoc pattern, and rename to `*.test.sh`-callable form. `distill.py` is the skill's most intricate logic (watermarking, resume offsets, state merge) and is the only genuinely unexercised code in the plugin. Adding pytest to the fleet toolchain for one file is the worse trade. |
| 4 | `plans/2026-07-05-machines-fleet-layout-B-backup.md` | Delete the one factually-dead plan? | **Banner it `ABANDONED`.** `machines/backup/` never existed and `AGENTS.md:52` settled the boundary the other way; the file records why. Covered by the precedent decision above. |
| 5 | `plans/2026-07-28-home-config-generator-collapse.md` | Is the collapse still wanted? Its blocker expired rather than was met, and the fleet then moved the *opposite* way — the harvest records `me.nix`'s config being rehomed **into** `tiers.sh`, i.e. into more rendering. | **Banner it `ABANDONED — superseded by the tiers.sh consolidation`.** Its step 6 is done by accident; steps 2 and 5 are dead. |
| 6 | `specs/2026-07-05-windows-restore-script-design.md` | Do you still want a Windows restore flow? Never built; its companion `backup.ps1`/`restore.ps1` were deleted 2026-07-31. | **Decide together with `install.ps1` and the runbook (below)** — all three are one question. |
| 7 | `specs/2026-07-07-fleet-mesh-vpn-ssh-design.md` | Its world is retired, but §4's "pin, don't blind-TOFU" host-key rationale (preserve `ssh_host_ed25519_key` across reinstalls) is written nowhere else and still applies to the unimplemented `ssh-server` role. | **Keep, bannered.** Or lift §4 into the harvest and then banner. |
| 8 | `provision/tests/roles.test.sh` | It pins the `nixos` arms in `roles/*.sh`. Unlike the two protected fail-safe leftovers, those arms would actively provision a platform with no host. | **Keep the test; remove the arms and the assertions in one commit.** `fleet_platform` can never return `nixos`, so they are unreachable — but they are not fail-safe, and `roles.test.sh:42` dies with an explicit message if you touch them without updating it. |
| 9 | `provision/provision.ps1` | Wire it in, or retire the PowerShell role branch? Nothing invokes it — `windows.ps1` never mentions it, `justfile:80` runs `provision.sh`, and under Git Bash every `role_*` falls to "no posix executor (skipped)". So desktop's roles are provisioned by `windows.ps1` steps 4-7, not by the role system. | **Wire it in.** `windows.ps1` should call `provision.ps1 -Apply`, and `$RoleExecutors` should auto-discover the way `provision.sh` does with `declare -F`, or a future role silently no-ops on Windows. Retiring instead is defensible but makes `windows.ps1` the permanent Windows story and orphans three working executors. |
| 10 | `hosts/desktop/windows/install.ps1` | The public bootstrap one-liner throws unconditionally at line 67. | **Delete it, together with the runbook's Phase 1/4 automation** — unless you want the Windows restore flow (row 6), in which case rebuild all three as one piece. Note the commit that kept it misidentified it as "Win11 install media, unrelated"; the recorded intent-to-keep was formed about a different file. |
| 11 | `hosts/desktop/windows/windows-reinstall-runbook.md` | Already logged as open at `docs/fleet-roadmap.md:487`, and now overdue: two of its automation steps run deleted scripts, its `autounattend.xml` link points at the wrong directory, three steps route through the deleted NixOS tree, and the reinstall it documents already happened. | **Rewrite down to what is still true** (Ventoy + `autounattend.xml` + `winget import` + `windows.ps1`), or delete and keep only `winget-packages.json`, which stands on its own. Do not leave it as-is; it is the only reinstall instruction for the fleet's one remaining Windows box. |

Two filing calls worth making at the same time: `specs/2026-07-29-hus726060ale611-smart-evidence.txt` (raw SMART capture) and `specs/2026-07-30-6tb-return-claim-ru.md` (an **open** consumer dispute) are evidence, not specs — move them to `docs/evidence/` so the next reviewer does not apply a shipped/abandoned rubric to them. And the roadmap has **no storage section**, so `plans/2026-07-28-latitude-wipe-harvest.md` §11 is the sole tracker for two open, dated obligations (the shelved ST320LT020's restic-repos/secrets/GoPro decision; the consolidation blocked on the 6TB replacement).

---

## The framework question

**Don't build one — the thing declarativeness was going to buy you is a script, not a schema, and this review just produced it by hand.**

The premise deserves precision. What `f3d63b2` deleted was a per-platform *engine*, not the declarative *interface*. The interface is still here and already works: `fleet.json`, `provision/gortex.version` and `provision/fleet-authorized-keys` are read by the provisioner and whitelisted in `converge.sh`'s `_touches_driver` as reprovision triggers, and `gortex.version`'s own header states the principle verbatim — *"It is data, so it is a data file."* On top of that, `MACHINES_TIERS_DRY_RUN=1` prints each profile's resolved tier list and `provision/tests/tiers.test.sh:35-38,57-60` assert both lists by exact string equality inside the gate. That is a declared plan plus a gate-enforced drift check, already present, minus the framework. So "should this become declarative" is partly a question the repo has already answered yes to, three times.

The reason to stop there is not that declarative is bad. It is the **N=1 problem**, and the strongest version of it comes from the stance arguing *for*: this fleet is one Debian services host, one Mac, one Windows box, one Debian VPS, one WSL child. Every abstraction a declarative layer introduces generalises from a single instance validated by nothing — and the previous attempt's own post-mortem is the receipt. `docs/2026-08-01-nixos-harvest.md` §6 records `nvidia.nix` and `hardware/asus-rog.nix` "orphaned since g16 was retired… no host imported them," `desktop/gnome.nix` — "nothing to port," `laptop.nix` — "would now be actively harmful." That is a large fraction of 22 modules maintained for a fleet of one each. `macos.sh:72-84` has already learned the lesson in miniature: it has exactly one profile arm and its comment says why — *"a macOS server profile would be inventing a machine that does not exist."*

The second reason is the number the *for* stance produced honestly: bucketing every drift item, a declaration-plus-diff would have caught roughly **17 inventory items and zero of the six code defects**. It catches air's hand-installed `just`, latitude's Docker substrate and sleep masking, hub's mtproto container, desktop's phantom task. It catches none of: the restic bind race, desktop-wsl's 185 silent skips, the cron `%`, `install.ps1`'s unconditional throw, `fleet-selfpull.ps1`'s regressed pull, `Fleet.psm1`'s missing guard. Those are test-and-code problems, and the repo's test surface has two holes that map onto them exactly — 28 of 38 suites, and essentially no PowerShell coverage.

The third reason is that a declarative layer would make the *worse* half worse. This repo's demonstrated failure mode is description drifting from reality — 2.2 MB of docs, 90 dated files, none marked done, roadmap P5 measuring four re-derivations in one session, twice wrong first. A declaration file is a fourth description of the fleet. The only thing that would make it different in kind is a command that checks it, in the gate. Without that it is more prose. And a richer declaration increases the fraction of each box's state contingent on a pull landing — on the same week a pull has not landed on desktop-wsl for 35 hours under a green timer.

The strongest point from the *against* stance survives too, and it is the one to act on: **`fleet.json` already declares more than the executors implement.** 22 role-assignments across four machines; three role names have executors; the dispatcher's fallback prints a skip and never sets `rc`. That gap is not closed by a richer declaration language — it is widened by one. Close it with items 6 and 14 above.

And the reusable rule, from the *incremental* stance, so this does not get re-derived a third time: **the test is not "is it configuration?" but "does it decide what to do by reading the machine first?"** Probe-then-act stays imperative, permanently — `tier_battery_limit` (177 lines whose config surface is two integers, and whose whole reason for existing is that the declarative version wrote a threshold without the charge mode and displayed a ceiling it was not enforcing), `tier_rapl_read`, `tier_sudo_nopasswd`, `tier_brew_cask`, the three sync-job bodies, `linux.sh`'s PRIV/SUDO probe, `roles/dotfiles.sh`'s collision handling, `converge.sh`'s gating. Inventory-shaped things can move: the ~40 package literals across five tiers are data wearing a `for`, and lifting them into one flat file (matching the `gortex.version` / `disks.*.conf` precedent, not a new serialization format) would make item 13 a one-line edit and make "is X declared?" answerable by reading rather than by grepping five loops in a 1434-line file. If you do that, the de facto rule is: **a new declarative data file must be added to `_touches_driver` in the same commit**, or a change to it never reaches a box.

What to build instead of a framework: **the live-vs-declared sweep, as a script, in `provision/tests/`.** Four agents just performed it by hand across four boxes and it found more real drift in a day than the previous declarative layer found in thirteen months — because it compares against the box instead of against a file. It is scriptable (`brew leaves` / `apt-mark showmanual` / `systemctl list-timers` / `docker ps` diffed against the tier lists), it gets *cheaper* the more the repo declares, and it belongs in `provision/tests/` specifically because the gate's glob never reaches `agents/plugin/**/tests/`. That is the declarative benefit without the framework, and it is a week of work rather than a quarter.

---

## What this review did not establish

- **Backups never got a first-class pass.** The dedicated worker returned nothing. Everything in that section is second-hand from four other workers, and no reconciliation of client/target pairs against the role declarations exists. This is the largest single hole.
- **The desktop `core.symlinks` question is still open** even though a worker was on the box. If symlinks are off, `CLAUDE.md` materialises as a text file containing the string `AGENTS.md`, the ledger's `keep` verdict on it becomes a real portability finding, and agents on that checkout load nothing. One command.
- **`metheoryt/machines-cleanup` was discovered only in this final pass.** Its three commits were not reviewed; its `tiers.sh` diff (+32/−3) is unexamined against the ledger's `rewrite` scope, and its `node` commit already refutes one drift claim. There may be more in it.
- **The ledger and the drift reports were produced independently and this document is the first place they meet.** I folded the defects I could see; there may be others where a `keep` row and a live finding disagree and neither worker knew.
- **`hosts/` unit ExecStart paths were not verified against latitude's actual checkout path.** All four systemd units hardcode `/home/me/machines/hosts/latitude/debian/...`; nobody confirmed the match.
- **Whether the statusboard `--install` has actually been run on latitude** was inferred from the live tty1 kiosk, not from the repo's own perspective — nothing in the repo starts either board, by design, and no file records that latitude is where the install was done.
- **The `agents/settings.json` dead marketplace path** (`/home/me/pure/claude-plugins`, a Linux path on a Mac fleet) was found but its failure mode is untested — whether it degrades silently or errors at launch is unknown.
- **`.gitattributes` coverage was verified as complete and deliberate** across three files, but only for currently-tracked shebang scripts; nobody checked how the extensionless git hooks behave on the Windows checkout.
- **hub's nftables ruleset was observed as absent-of-filtering but not audited**, and its `mtproto-proxy` container's configuration (in the undeclared `proxy-config` volume) was not inspected.
- **N=4, one box per platform, one point in time.** The drift sweep is broad and shallow, and "undeclared" occasionally means "declared in the sibling `vps` repo," which is correct by the boundary rather than a gap — the resticprofile units are the clean example.
- **Ten of the eleven `needs-decision` rows carry my recommendation but nobody's decision**, and the delete precedent is a policy the user has not been asked about until now.
