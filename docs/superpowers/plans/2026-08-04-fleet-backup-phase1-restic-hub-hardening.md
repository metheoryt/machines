# Fleet Backup Phase 1 — Restic Hub Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status: OPEN** — Phase 1 of
`docs/superpowers/specs/2026-08-04-fleet-backup-consolidation-design.md`.

**Goal:** Restore the fleet's only machine-crossing backup path in its target
shape — authenticated, append-only, per-client-credentialed, bound on a wildcard
address so it cannot lose the boot race again — and prove it with a restore and a
reboot.

**Architecture:** `rest-server` on latitude stops being an unauthenticated open
door bound to a tailnet address that does not exist at boot. It gains htpasswd
auth, `--private-repos`, `--append-only`, and a `0.0.0.0` bind. Auth is what makes
the wildcard bind safe, and the wildcard bind is what kills the boot race — the
two halves are one change and neither is correct alone. `--append-only` moves
retention off the client and onto a declared prune job on latitude, which is why
each repo's encryption password is escrowed twice: on the client's dotfiles branch
for the client's own restore, and on latitude's for the prune of the repo latitude
hosts.

**Tech Stack:** Docker Compose (`restic/rest-server:latest`), restic 0.19.1,
resticprofile 0.33.1, systemd (system scope on latitude, `--user` on desktop-wsl),
the private `dotfiles` bare repo for credential escrow.

---

## Global Constraints

- **`metheoryt/machines` is a public repo.** This plan document is in it. It
  contains **no credential values** — only paths, and the commands that generate
  secrets. `vps` and `dotfiles` are private; secrets live there. Verified:
  `gh api repos/metheoryt/machines --jq .private` → `false`.
- **Three repos are touched.** `machines` (this plan only), `vps`
  (`homeserver/restic-server/compose.yml`, `backup/wsl/*`,
  `backup/latitude/profiles.yaml`), and `dotfiles` on two different machine
  branches (`latitude`, `desktop-wsl`).
- **htpasswd username is `g614jv`.** Not a style choice — see Task 2's rationale.
  It makes the `--private-repos` path move a no-op.
- **Data path:** `RESTIC_DATA_PATH=/mnt/spare320/restic-rest` on latitude; the
  `g614jv` repo is `/mnt/spare320/restic-rest/g614jv` (5.0 G, 2 snapshots).
- **Drive:** `/mnt/spare320` is UUID `3a78fd88-deb0-4c1a-a576-14abd0631d57`, ext4,
  mounted `nofail` per `/etc/fstab`. Never reference `/dev/sdb1` — letters
  reshuffle across reboots on this box.
- **Retention for `g614jv`, moved verbatim from the client to latitude:**
  `keep-daily: 14`, `keep-weekly: 8`, `keep-monthly: 12`, `keep-yearly: 5`.
- **Dotfiles rules apply to every escrow step:** `~/.gitignore` is allow-only, so
  a new file needs a `!` line plus an explicit `dotfiles add` (the sync timer runs
  `add -u` and never stages an untracked path). Host-local allow-lines are
  **anchored with a leading slash**. Run `check-ignore -v` before staging. Never
  name an escrow file such that the trailing deny block catches it silently
  (`*.pem`, `*.key`, `*.gpg`, `id_*`) — hence `.txt`.
- **Verify a scheduled job by firing its schedule, not by running the script**
  (`systemctl start <unit>` then `systemctl show -p Result`).
- **A non-interactive ssh PATH on Debian excludes `/usr/sbin` and `/sbin`**, and on
  desktop-wsl it excludes `~/.local/bin` where `restic` and `resticprofile` live.
  Export PATH explicitly in every remote command.
- **No secret is ever printed, echoed, or interpolated into a command line.** Every
  credential in this plan is generated straight into a mode-600 file and moved
  between boxes by piping that file into a reader on the far side. That is what
  makes Tasks 2-4 safe for a non-interactive executor to run: nothing lands in a
  transcript, a scrollback, or `ps`. Verifications assert byte counts, modes and
  redacted shapes — never values. If a step ever seems to need the value on a
  terminal, the step is wrong.
- **Task 9 Step 4 reboots latitude and needs its own explicit approval**, separate
  from approval to execute this plan. It takes immich, servarr, the backup timers
  and the REST hub down. Tasks 1-8 and Task 9 Steps 1-3 are safe under ordinary
  review checkpoints; stop at Step 4 and ask.
- **`just test` in `machines` must stay green** (41 suites, 0 failures at
  `49497bd`). This phase adds no `machines` code, so it should not move; confirm
  anyway before the final commit.

### Measured starting state (2026-08-04, before any change)

| Fact | Value |
|---|---|
| `restic-server` container | `Up`, `RestartCount: 0`, `PortBindings: 100.64.0.8:8001`, **`NetworkSettings.Ports: map[]`** |
| Listening on 8001 | nothing |
| `g614jv` repo last write | 2026-08-01 16:49 — three days stale |
| desktop-wsl client last run | `Result=exit-code`, status 1, 2026-08-03 06:14, **no diagnostic output anywhere** |
| Server options | `--no-auth --prometheus` — no auth, no append-only, no private repos |
| `/mnt/spare320/restic-rest/.htpasswd` | exists, **0 bytes**, `root:root`, mode 0640 |
| Container log line 1 | `**WARNING** No user exists, please 'docker exec -it $CONTAINER_ID create_user'` |
| latitude `~/my/vps` | 11 commits behind `origin/main` |
| air `~/my/vps` | 1 commit ahead, **unpushed** (`6bf5fa3`) |
| desktop-wsl `~/my/vps` | up to date |

### Two upstream behaviours this plan depends on — both verified, not assumed

1. **`--private-repos` maps username to a top-level directory, one repo per
   user.** Upstream README: *"user 'foo' using the repository URLs
   `rest:https://foo:pass@host:8000/foo` or `rest:https://foo:pass@host:8000/foo/`
   would be granted access, but the same user using repository URLs
   `rest:https://foo:pass@host:8000/` or `rest:https://foo:pass@host:8000/foobar/`
   would be denied access."*
   **Consequence, and a correction to the spec:** the spec says the repo must move
   from `/data/g614jv` to `/data/<user>/g614jv`. That is wrong. With username
   `g614jv`, the existing directory is *already* exactly where `--private-repos`
   expects it. **No directory move. No re-init.** The riskiest step in the spec —
   moving the only history that repository has — is deleted outright.
2. **`--append-only` forbids every DELETE except locks.** `repo/repo.go:737`:
   `if h.opt.AppendOnly && objectType != "locks" { httpDefaultError(w, http.StatusForbidden) }`,
   and `deleteConfig` is unconditionally 403 under append-only (`repo.go:337`).
   Separately, `saveBlob` refuses to overwrite an existing object *regardless* of
   append-only (`repo.go:564`). **Consequences:** stale locks stay clearable (so
   `force-inactive-lock` still works); `forget` cannot run client-side at all; and
   `restic key add` — a new object — *would* be permitted, but `key remove` would
   not, which is why Task 3 rotates the key on latitude's filesystem instead of
   over HTTP.

### Why this phase has no unit test in `machines`

Every deliverable is either a config file in `vps` or a live host operation, so
there is nothing for `just test` to assert. Rather than fake a unit test, each
task below carries a **behavioural** red-green pair run against the live system:
a command whose output before the change is the fault, and after the change is
the fix. Task 9 makes those assertions durable as a committed script, which is
the artifact that would have caught the 29-hour outage. Phase 2 is where the gate
gains a real suite.

### One residual risk, guarded rather than closed

`/mnt/spare320` is mounted `nofail`, and `initialize: true` is set in
`backup/base.yaml`. If the drive is ever absent at boot, docker bind-mounts an
empty directory, the client finds no repo, and — under append-only, since
`saveConfig` creates a *new* config — silently initialises a **fresh empty repo**,
starting history from zero. Task 6 sets `initialize: false` on the client to close
it at the source; Task 9's selfcheck asserts the repo's `config` object exists so
the failure is loud either way.

---

### Task 1: Get every box onto the same `vps` commit

Nothing else can be trusted until this is done. latitude runs the restic units out
of its `~/my/vps` work tree, and it is 11 commits behind — so a compose edit made
on air is inert on the box that runs it. air also holds `6bf5fa3` unpushed, which
is the commit that corrected the false boot-race comment; keep it (its recorded
outage history is the reason the rest of this plan exists) and build on top.

**Files:**
- Modify: none — this is repo state, not content.

**Interfaces:**
- Consumes: nothing.
- Produces: all three boxes at the same `origin/main`. Every later task assumes it.

- [ ] **Step 1: Confirm the divergence (this is the failing state)**

```bash
cd ~/my/vps && git fetch -q origin
git rev-list --left-right --count origin/main...HEAD   # air:  0  1
ssh latitude 'cd ~/my/vps && git fetch -q origin && git rev-list --left-right --count origin/main...HEAD'   # 11  0
```

Expected: air `0 1`, latitude `11 0`.

- [ ] **Step 2: Review what the 11 commits contain before pulling them onto the box that runs root-scope restic units**

```bash
ssh latitude 'cd ~/my/vps && git log --oneline HEAD..origin/main && echo --- && git diff --stat HEAD..origin/main -- homeserver/restic-server backup/'
```

Expected: 11 commits; only `backup/wsl/profiles.yaml` changes under the backup
paths (55 lines). Nothing touches `homeserver/restic-server/` or
`backup/latitude/`, so latitude's own units are unaffected by the pull. **If that
is not what you see, stop and re-scope** — this step exists because pulling
unreviewed commits onto the services host is not something to discover mid-change.

- [ ] **Step 3: Push air's commit, then pull latitude**

```bash
cd ~/my/vps && git push origin main
ssh latitude 'cd ~/my/vps && git pull --ff-only origin main'
```

- [ ] **Step 4: Verify all three boxes agree**

```bash
cd ~/my/vps && git rev-parse HEAD
ssh latitude 'cd ~/my/vps && git rev-parse HEAD'
ssh desktop-wsl.gg.ez 'cd ~/my/vps && git fetch -q origin && git pull --ff-only origin main >/dev/null 2>&1; git rev-parse HEAD'
```

Expected: three identical hashes.

- [ ] **Step 5: No commit** — this task only moved refs. Continue to Task 2.

---

### Task 2: Create the htpasswd user (no behaviour change)

Safe to do first and in isolation: the container is running but publishes no port,
so there is no working client to disturb, and `--no-auth` means the file is written
and ignored until Task 5 removes that flag. Doing it now means Task 5 cannot land
"auth enabled, zero users, every client rejected" — a failure that presents
identically to a credential bug and burns a debugging cycle.

**Username is `g614jv`, deliberately.** Three reasons, in order of weight.
(1) `--private-repos` maps a username to a top-level directory, so username
`g614jv` means the existing `/data/g614jv` needs no move — the spec's riskiest step
disappears. (2) The client's `repository` template is `{{ .Hostname }}`, which on a
WSL distro expands to the **Windows** host name `g614jv`, so the URL path does not
change either. (3) It is the more honest name: both of desktop's WSL distros
resolve to that same value and therefore share this one repo, so naming it after
one distro (`desktop-wsl`) would describe an isolation that does not exist. The
existing comment at `backup/wsl/profiles.yaml:25-34` already documents this.

**Files:**
- Modify (on latitude, not in any repo): `/mnt/spare320/restic-rest/.htpasswd`

**Interfaces:**
- Consumes: Task 1's synchronised checkouts.
- Produces: htpasswd user `g614jv` with a **transport** password. Task 4 escrows
  it; Task 5 starts enforcing it; Task 6's URL embeds it. This is a *different*
  secret from the repo encryption password in Task 3 — the whole point of the
  per-client design is that the two stop being one 13-byte string.

- [ ] **Step 1: Confirm the file is empty (the failing state)**

```bash
ssh latitude 'sudo -n sh -c "wc -c < /mnt/spare320/restic-rest/.htpasswd"'
```

Expected: `0`. This is why auth cannot simply be switched on.

- [ ] **Step 2: Generate the transport password straight into a file — never onto a terminal**

```bash
ssh latitude 'umask 077; mkdir -p ~/.config/restic
openssl rand -hex 32 > ~/.config/restic/g614jv.transport.txt
chmod 600 ~/.config/restic/g614jv.transport.txt
wc -c < ~/.config/restic/g614jv.transport.txt'
```

Expected: `65` (64 hex characters plus the newline).

**Hex, not base64, and this is not cosmetic.** Task 6 puts this password inside a
URL's userinfo (`rest:http://g614jv:<pw>@host:8001/g614jv`) — base64's alphabet
includes `/`, `+` and `=`, and a `/` there truncates the URL. Hex is URL-safe with
no escaping, which removes a whole class of "works on one box" failure. 32 bytes
of entropy is plenty for a credential whose rotation cost is one `htpasswd` call.

Note the value is never printed, so it never enters a transcript, a scrollback, or
`ps`. Every step that needs it reads the file.

- [ ] **Step 3: Register the user by piping the file into `htpasswd -i` — no argv, no prompt**

```bash
ssh latitude 'docker exec -i restic-server htpasswd -B -i /data/.htpasswd g614jv < ~/.config/restic/g614jv.transport.txt'
```

Three forms exist and only this one is both safe and scriptable. `create_user
<user> <pass>` puts the password in argv, visible in `ps` on the host — the same
hazard recorded at `provision/tailscale-mac.sh:13-16` about `--authkey`.
`create_user <user>` prompts, which is safe but cannot be scripted or handed to a
non-interactive executor. `create_user` is a two-line wrapper over `htpasswd -B`
anyway, and the image ships real apache2-utils, whose `-i` reads the password from
stdin without prompting (verified: `htpasswd [-cimB25dpsDv]`, `-i  Read password
from stdin without verification (for script usage)`). `/data/.htpasswd` is the
same path `$PASSWORD_FILE` names, so the server reads exactly this file.

- [ ] **Step 4: Verify one bcrypt line landed, and that the server is reading that exact path**

```bash
ssh latitude 'sudo -n cut -d: -f1 /mnt/spare320/restic-rest/.htpasswd; sudo -n sh -c "wc -l < /mnt/spare320/restic-rest/.htpasswd"; sudo -n sh -c "grep -c \"^g614jv:[\$]2y[\$]\" /mnt/spare320/restic-rest/.htpasswd"'
ssh latitude 'docker inspect restic/rest-server:latest --format "{{range .Config.Env}}{{println .}}{{end}}" | grep PASSWORD_FILE'
```

Expected: `g614jv`, `1`, and `PASSWORD_FILE=/data/.htpasswd` — which is
`/mnt/spare320/restic-rest/.htpasswd` through the bind mount. Do not print the
hash.

- [ ] **Step 5: Confirm nothing changed for clients yet**

```bash
ssh latitude 'docker logs restic-server 2>&1 | grep -E "Authentication|Append only|Private repos"'
```

Expected: still `Authentication disabled`, `Append only mode disabled`,
`Private repositories disabled` — the running process has not been restarted, so
the new file is inert. Correct at this point.

- [ ] **Step 6: No commit** — nothing in any repo changed. Continue to Task 3.

---

### Task 3: Give `g614jv` its own encryption key, on latitude's filesystem

Today both repos are opened by the same 13-byte password, so "per-client
credentials" starts here. Do it on latitude against the filesystem path, not over
HTTP: `restic key add` would be permitted under append-only (a new object) but
`key remove` would not, so a rotation begun over HTTP could not be finished.
latitude also *needs* this password permanently — it is the box that prunes this
repo (Task 7) — so the filesystem is where it belongs.

`key add` leaves both passwords working, so there is no window in which the client
cannot authenticate. The old key is removed only in Task 8, after the new one is
proven.

**Files:**
- Modify (on latitude, not in any repo): the `keys/` object set inside
  `/mnt/spare320/restic-rest/g614jv`

**Interfaces:**
- Consumes: Task 1.
- Produces: a **repo encryption** password for `g614jv`, escrowed by Task 4,
  consumed by the client in Task 6 and by the prune job in Task 7.

- [ ] **Step 1: Confirm the repo currently opens with the shared password, and has exactly one key (the failing state)**

```bash
ssh -t latitude 'export PATH=/usr/sbin:/sbin:$PATH; sudo -n restic -r /mnt/spare320/restic-rest/g614jv --password-file /home/me/g513ie-prod-config/vps/backup/homeserver/pass.txt key list'
```

Expected: one row, marked current. That single row *is* the fault — the same
password opens latitude's own repo.

- [ ] **Step 2: Confirm the two snapshots are there before touching keys**

```bash
ssh -t latitude 'export PATH=/usr/sbin:/sbin:$PATH; sudo -n restic -r /mnt/spare320/restic-rest/g614jv --password-file /home/me/g513ie-prod-config/vps/backup/homeserver/pass.txt snapshots'
```

Expected: 2 snapshots (2026-08-01, 2026-08-02), host `g614jv`. Record their IDs —
Task 6 and Task 8 assert against them. **This is the only history this repository
has; if this command fails, stop.**

- [ ] **Step 3: Generate the new encryption password and write it where latitude will keep it**

Interactively on latitude:

```bash
mkdir -p ~/.config/restic
umask 077
openssl rand -base64 32 | tr -d '\n' > ~/.config/restic/g614jv.pass.txt
chmod 600 ~/.config/restic/g614jv.pass.txt
```

No trailing newline: restic treats the whole file content as the password, and a
stray newline is a class of "the password is wrong on one box only" bug.

- [ ] **Step 4: Add the new key**

```bash
ssh -t latitude 'export PATH=/usr/sbin:/sbin:$PATH; sudo -n restic -r /mnt/spare320/restic-rest/g614jv --password-file /home/me/g513ie-prod-config/vps/backup/homeserver/pass.txt key add --new-password-file /home/me/.config/restic/g614jv.pass.txt'
```

- [ ] **Step 5: Verify both keys work and neither password has been invalidated**

```bash
ssh -t latitude 'export PATH=/usr/sbin:/sbin:$PATH
 R=/mnt/spare320/restic-rest/g614jv
 sudo -n restic -r $R --password-file /home/me/.config/restic/g614jv.pass.txt key list
 sudo -n restic -r $R --password-file /home/me/.config/restic/g614jv.pass.txt snapshots | tail -3
 sudo -n restic -r $R --password-file /home/me/g513ie-prod-config/vps/backup/homeserver/pass.txt snapshots | tail -3'
```

Expected: **two** keys listed; the same 2 snapshots visible under *both*
passwords. That symmetry is what makes Task 6 safe to attempt and Task 8 safe to
defer.

- [ ] **Step 6: No commit** — repo-internal state only. Continue to Task 4.

---

### Task 4: Escrow both credentials in the private dotfiles repo, on two branches

A repo password that exists only on the machine it protects makes a total client
loss unrestorable — and today the only off-box copy exists *by accident*, with
nothing recording that it is the escrow. This task makes it explicit, and it
escrows the `g614jv` encryption password **twice**, which the spec calls out as a
requirement rather than redundancy: on `desktop-wsl`'s branch for the client's own
restore, and on `latitude`'s branch for the prune of the repo latitude hosts
(Task 7). A password held only on the client is unreadable from latitude, and
append-only makes latitude the only box that *can* prune.

A repo password is host-specific, so every file here goes on **that machine's
branch, never `main`** — `$HOME/CLAUDE.md`'s rule that a path is shared or
host-local but never both.

**Files:**
- Create (dotfiles, `latitude` branch): `~/.config/restic/g614jv.pass.txt`
  (already written in Task 3 Step 3 — this tracks it)
- Create (dotfiles, `desktop-wsl` branch): `~/.config/restic/repo.txt`
- Modify (dotfiles, `desktop-wsl` branch): `~/.config/restic/pass.txt` — currently
  the shared password, becomes `g614jv`'s own; currently **untracked**, becomes
  tracked
- Modify: `~/.gitignore` on both branches

**Interfaces:**
- Consumes: Task 2's transport password, Task 3's encryption password.
- Produces: `/home/me/.config/restic/pass.txt` and
  `/home/me/.config/restic/repo.txt` on desktop-wsl (Task 6 points the profile at
  both); `/home/me/.config/restic/g614jv.pass.txt` on latitude (Task 7 points the
  prune job at it).

- [ ] **Step 1: Confirm the client's password file is untracked today (the failing state)**

```bash
ssh desktop-wsl.gg.ez 'git --git-dir=$HOME/.dotfiles --work-tree=$HOME rev-parse --abbrev-ref HEAD; git --git-dir=$HOME/.dotfiles --work-tree=$HOME ls-files | grep -c "config/restic" || echo 0'
```

Expected: branch `desktop-wsl`, count `0`. The client's only copy of the password
is on the client — which is the failure mode being closed.

- [ ] **Step 2: Pipe both secrets from latitude to desktop-wsl without printing either**

```bash
# the ENCRYPTION password (Task 3 Step 3) -> the client's password file.
# No trailing newline: restic takes the whole file content as the password, and a
# stray newline is a "wrong password on one box only" bug.
ssh latitude 'cat ~/.config/restic/g614jv.pass.txt' \
  | ssh desktop-wsl.gg.ez 'umask 077; mkdir -p ~/.config/restic; cat > ~/.config/restic/pass.txt; chmod 600 ~/.config/restic/pass.txt'

# the TRANSPORT password (Task 2 Step 2) -> assembled into the repository URL on
# the receiving side, so the secret is read from stdin and never appears in a
# command line on either box.
ssh latitude 'cat ~/.config/restic/g614jv.transport.txt' \
  | ssh desktop-wsl.gg.ez 'umask 077; IFS= read -r TP
      printf "rest:http://g614jv:%s@100.64.0.8:8001/g614jv\n" "$TP" > ~/.config/restic/repo.txt
      chmod 600 ~/.config/restic/repo.txt'
```

Two secrets in two files, on purpose. `repo.txt` exists so the transport
credential never enters `vps` (a tracked config file) and never appears in argv —
restic's REST backend accepts credentials only inside the URL, and
`RESTIC_REPOSITORY_FILE` is the one way to supply that URL from outside both.
`repo.txt` **keeps** its trailing newline (restic strips it when reading a
repository file); `pass.txt` must **not** have one.

Verify the shapes without revealing the values:

```bash
ssh desktop-wsl.gg.ez 'wc -c < ~/.config/restic/pass.txt; sed -E "s|//g614jv:[^@]+@|//g614jv:REDACTED@|" ~/.config/restic/repo.txt; stat -c %a ~/.config/restic/pass.txt ~/.config/restic/repo.txt'
```

Expected: the encryption password's byte count with no trailing newline,
`rest:http://g614jv:REDACTED@100.64.0.8:8001/g614jv`, and `600` twice.

- [ ] **Step 2b: Shred latitude's copy of the transport password**

```bash
ssh latitude 'shred -u ~/.config/restic/g614jv.transport.txt 2>/dev/null || rm -f ~/.config/restic/g614jv.transport.txt
ls ~/.config/restic/'
```

Expected: only `g614jv.pass.txt` remains. latitude needs the bcrypt *hash* in
`.htpasswd`, never the plaintext — keeping it would leave a second secret on a box
that has no reason to hold it and no escrow declared for it. The escrowed copy is
the one inside desktop-wsl's `repo.txt`, tracked in Step 4.

- [ ] **Step 3: Verify the deny block does not silently swallow either file, then allow them**

```bash
ssh desktop-wsl.gg.ez 'git --git-dir=$HOME/.dotfiles --work-tree=$HOME check-ignore -v .config/restic/pass.txt .config/restic/repo.txt'
```

Expected: both matched by the allow-only `*` rule — **not** by a `.key`/`.pem`/
`id_*` deny line. If a deny line matches, rename the file rather than weakening
the block.

Then add two anchored allow-lines to `~/.gitignore` on desktop-wsl, under the
explicit-allow block:

```gitignore
!/.config/restic/pass.txt
!/.config/restic/repo.txt
```

Leading slashes are mandatory: an unanchored `!` pattern also un-ignores a stray
match inside any project checkout under `$HOME`.

- [ ] **Step 4: Stage the allow-list change together with the files, and commit**

```bash
ssh desktop-wsl.gg.ez 'git --git-dir=$HOME/.dotfiles --work-tree=$HOME add ~/.gitignore .config/restic/pass.txt .config/restic/repo.txt
git --git-dir=$HOME/.dotfiles --work-tree=$HOME commit -m "escrow(restic): g614jv repo password + REST URL, host-local

Per-client credentials for the hardened restic hub. pass.txt is the repo
ENCRYPTION password (was the fleet-shared one); repo.txt carries the
TRANSPORT credential inside the repository URL so it stays out of the vps
repo and out of argv.

Also escrowed on latitude branch: latitude prunes this repo, which
--append-only makes impossible from the client, and forget --prune needs
the encryption password."
git --git-dir=$HOME/.dotfiles --work-tree=$HOME push'
```

The two-step (`!`-line + explicit `add`) is required because the sync timer runs
`add -u`, which never stages an untracked path.

- [ ] **Step 5: Do the same for latitude's copy of the encryption password**

```bash
ssh latitude 'git --git-dir=$HOME/.dotfiles --work-tree=$HOME rev-parse --abbrev-ref HEAD
git --git-dir=$HOME/.dotfiles --work-tree=$HOME check-ignore -v .config/restic/g614jv.pass.txt'
```

Expected: branch `latitude`; matched by `*`, not by a deny line. Add
`!/.config/restic/g614jv.pass.txt` to latitude's `~/.gitignore`, then:

```bash
ssh latitude 'git --git-dir=$HOME/.dotfiles --work-tree=$HOME add ~/.gitignore .config/restic/g614jv.pass.txt
git --git-dir=$HOME/.dotfiles --work-tree=$HOME commit -m "escrow(restic): g614jv encryption password, for the prune this host owns

--append-only refuses deletes over HTTP, so forget --prune for the g614jv
repo runs here against the filesystem. That needs the CLIENT repo password,
which per-client escrow on desktop-wsl'"'"'s branch makes unreadable from
here -- hence the second copy. Deliberate, not duplication."
git --git-dir=$HOME/.dotfiles --work-tree=$HOME push'
```

- [ ] **Step 6: Verify both escrows are tracked and pushed**

```bash
ssh desktop-wsl.gg.ez 'git --git-dir=$HOME/.dotfiles --work-tree=$HOME ls-files .config/restic/; git --git-dir=$HOME/.dotfiles --work-tree=$HOME status --short'
ssh latitude 'git --git-dir=$HOME/.dotfiles --work-tree=$HOME ls-files .config/restic/; git --git-dir=$HOME/.dotfiles --work-tree=$HOME status --short'
```

Expected: `pass.txt` + `repo.txt` on desktop-wsl, `g614jv.pass.txt` on latitude,
both work trees clean.

---

### Task 5: Harden the server — wildcard bind and auth in one change

The bind and the auth are one commit because **neither is correct alone.** The
existing comment argues against `0.0.0.0` and it is right *about its own premise*:
with `--no-auth`, a wildcard bind exposes read/write/delete on every repo to every
device on the wifi, and latitude has no host firewall (`iptables -P INPUT ACCEPT`
with only a `ts-input` jump; no ufw, nftables or firewalld). Auth inverts that
argument. Rewrite the comment rather than deleting it.

The wildcard bind is also the *durable* fix for the boot race, not a workaround: a
wildcard bind needs no address to pre-exist, so there is nothing to lose a race
against. It additionally removes the hard-coded tailnet IP from a services repo,
which is the complaint that started this whole redesign.

**Files:**
- Modify: `~/my/vps/homeserver/restic-server/compose.yml:5-45` (ports + comment),
  `:48-62` (OPTIONS + comment)

**Interfaces:**
- Consumes: Task 2's htpasswd user (without it this locks every client out).
- Produces: an authenticated, append-only, private-repos server on `0.0.0.0:8001`.
  Task 6's client URL and Task 7's prune ownership both depend on it.

- [ ] **Step 1: Capture the failing state — unreachable, and unauthenticated by design**

```bash
ssh latitude 'docker inspect restic-server --format "Ports={{.NetworkSettings.Ports}} Bindings={{.HostConfig.PortBindings}}"
export PATH=/usr/sbin:/sbin:$PATH; ss -lntp | grep 8001 || echo "NOT LISTENING"
curl -s -o /dev/null -w "unauth=%{http_code}\n" --max-time 5 http://100.64.0.8:8001/g614jv/config || echo "curl: connection failed"'
```

Expected: `Ports=map[]` with `Bindings` populated, `NOT LISTENING`, and curl
failing to connect. Those three lines together are the outage.

- [ ] **Step 2: Replace the ports block**

In `homeserver/restic-server/compose.yml`, replace lines 5-45 with:

```yaml
    ports:
      # WILDCARD BIND, and the auth below is what makes it correct. These two
      # changes are one change - do not split them.
      #
      # This used to be "100.64.0.8:8001:8000", bound to latitude's tailnet
      # address, with --no-auth set. The reasoning was sound about its own
      # premise: with no authentication, publishing on 0.0.0.0 exposes read,
      # write and DELETE on every repo to every device on the wifi, guests
      # included, and this host has no firewall (iptables -P INPUT ACCEPT, only
      # a ts-input jump; no ufw, nftables or firewalld). Binding the tailnet
      # address made reachability equal fleet membership, which is the property
      # --no-auth was assuming.
      #
      # htpasswd + --private-repos + --append-only replace that property with a
      # credential check, which is strictly stronger: it also constrains fleet
      # members, and it survives a device joining the LAN. So the address no
      # longer has to carry the security argument.
      #
      # AND THAT FIXES THE BOOT RACE, which the tailnet bind caused and no
      # restart policy could cover. A tailnet-address bind cannot happen before
      # tailscaled is up:
      #   failed to set up container networking: driver failed programming
      #   external connectivity ... cannot assign requested address
      # That happens during container network SETUP, so the container never
      # reaches a running state and never exits - and a restart policy only
      # retries containers that EXIT. Measured twice: ExitCode=255 with
      # RestartCount=0 ten hours later (2026-08-02, 29 h of lost backups), and
      # again Up with PortBindings intact but NetworkSettings.Ports empty
      # (2026-08-04, 3 days). A wildcard bind has no address to wait for, so
      # there is no race left to lose.
      #
      # It failed silently in both directions and that has NOT been fixed here:
      # nothing scrapes the --prometheus metrics below (and with auth on they now
      # need credentials), no unit has OnFailure=, and the only client reports
      # through a systemd --user timer on a WSL distro. selfcheck.sh next to this
      # file is the stopgap; the fleet backup report (phase 2 of the design spec)
      # is the real answer.
      #
      # Recovery after any change here is `up -d --force-recreate`, NOT `up -d`
      # or `start`: a plain start reuses the existing container, which comes back
      # with HostConfig.PortBindings intact but NetworkSettings.Ports empty -
      # running, logging "start server on [::]:8000", reachable by nobody.
      #
      # If a firewall is ever wanted here it must be a DOCKER-USER rule. Docker's
      # published ports bypass ufw and the INPUT chain via DNAT, so `ufw allow`
      # or `ufw deny` would do nothing either way.
      - "8001:8000"
```

- [ ] **Step 3: Replace the environment block**

Replace lines 48-62 with:

```yaml
    environment:
      # --private-repos scopes each client to /data/<htpasswd-user>/. The users
      # are created with `docker exec -it restic-server create_user <name>` (the
      # one-argument form prompts; the two-argument form puts the password in
      # argv). PASSWORD_FILE defaults to /data/.htpasswd, i.e. inside the volume
      # below - so the file survives a recreate and is NOT in any repo.
      #
      # The client's htpasswd user is `g614jv`, which is what makes this a
      # zero-risk change to a repo that already had history: --private-repos maps
      # a username to a TOP-LEVEL directory, one repo per user, so /data/g614jv
      # was already exactly where it needs to be. No move, no re-init. The name
      # also matches what the client's `{{ .Hostname }}` template expands to on a
      # WSL distro (the Windows host name), and it is the honest name: both of
      # desktop's distros resolve to it and share this one repo.
      #
      # --append-only refuses every DELETE except locks (repo/repo.go:737) and
      # refuses to delete the config at all (:337), so a compromised or confused
      # CLIENT cannot destroy history. It does not protect against this host:
      # latitude holds the data and, per the design spec, an escrowed copy of
      # each repo's password. That boundary is kept deliberately; the offsite
      # copy on hub (phase 3) is what limits its blast radius.
      #
      # The cost is that `forget --prune` cannot run client-side. It is not
      # dropped - it moved to a declared root-scope job on this host, in
      # backup/latitude/profiles.yaml, reading the repo from the filesystem and
      # bypassing the server. The client's retention is explicitly disabled to
      # match; leaving it on would fail every run.
      - OPTIONS=--private-repos --append-only --prometheus
```

- [ ] **Step 4: Apply with `--force-recreate` and verify all four properties**

```bash
ssh latitude 'cd ~/my/vps/homeserver/restic-server && docker compose up -d --force-recreate'
ssh latitude 'export PATH=/usr/sbin:/sbin:$PATH
docker inspect restic-server --format "Ports={{.NetworkSettings.Ports}}"
ss -lntp | grep 8001
docker logs restic-server 2>&1 | grep -E "Authentication|Append only|Private repos"'
```

Expected: `Ports=map[8000/tcp:[{0.0.0.0 8001}...]]`, a listener on `0.0.0.0:8001`,
and the log now reading `Append only mode enabled` / `Private repositories
enabled` with no `Authentication disabled` line.

- [ ] **Step 5: Prove auth, prove private-repos, prove append-only**

Run interactively on latitude so the password stays out of transcripts (`-u` with
a prompt):

```bash
# 1. unauthenticated is now refused
curl -s -o /dev/null -w "unauth=%{http_code}\n" http://100.64.0.8:8001/g614jv/config
# 2. authenticated works, over BOTH the tailnet address and the LAN address
#    (proving the wildcard bind, which is the boot-race fix)
curl -s -o /dev/null -w "tailnet=%{http_code}\n" -u g614jv http://100.64.0.8:8001/g614jv/config
curl -s -o /dev/null -w "lan=%{http_code}\n"     -u g614jv "http://$(hostname -I | awk '{print $1}'):8001/g614jv/config"
# 3. another user's path is refused even with valid credentials
curl -s -o /dev/null -w "otherpath=%{http_code}\n" -u g614jv http://100.64.0.8:8001/latitude/config
# 4. DELETE is refused -- this is append-only, and it is the protection being bought
curl -s -o /dev/null -w "delete=%{http_code}\n" -u g614jv -X DELETE http://100.64.0.8:8001/g614jv/config
```

Expected: `unauth=401`, `tailnet=200`, `lan=200`, `otherpath=401`, `delete=403`.
**If `delete` returns anything but 403, stop** — the rest of this plan moves
retention off the client on the assumption that the server refuses deletes.

- [ ] **Step 6: Commit (in `vps`)**

```bash
cd ~/my/vps
git add homeserver/restic-server/compose.yml
git commit -m "feat(restic-server)!: authenticated, append-only, private repos, wildcard bind

Four changes that are one change. htpasswd auth replaces the property the
tailnet-address bind was standing in for, which frees the bind to be
0.0.0.0 -- and a wildcard bind has no address to wait for, so the boot race
that cost 29 h (2026-08-02) and then 3 days (2026-08-04) has nothing left
to lose. It also gets latitude's tailnet IP out of a services repo.

--private-repos with htpasswd user g614jv needs NO directory move: it maps
a username to a top-level dir, one repo per user, so /data/g614jv already
sat where it belongs. The spec's server-side mv is unnecessary; that repo's
two snapshots were never at risk.

--append-only refuses every DELETE but locks, so forget --prune moves to a
declared root-scope job on latitude. Verified live: unauth 401, authed 200
on both the tailnet and LAN addresses, other-user path 401, DELETE 403.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

### Task 6: Point the client at the credentialed URL, disable its retention, stop backing up its own key

Three coupled client changes. The URL moves out of the tracked config so the
transport credential is not committed. Retention must be off or **every run
fails** — the profile currently inherits `after-backup: true` with `prune: true`,
and both are DELETEs the server now refuses. And the backup source is `/home/me`
with no exclusion for `~/.config/restic`, so today the password is stored inside
the repository it unlocks.

**Files:**
- Modify: `~/my/vps/backup/wsl/profiles.yaml:35-51` (repository → env),
  `:73-78` (retention)
- Modify: `~/my/vps/backup/wsl/.resticignore` (add the credential directory)

**Interfaces:**
- Consumes: Task 4's `/home/me/.config/restic/{pass,repo}.txt`, Task 5's server.
- Produces: a client that backs up and never deletes. Task 7 assumes its retention
  is off; Task 8's restore is run against what it writes.

- [ ] **Step 1: Confirm the two failing states**

```bash
ssh desktop-wsl.gg.ez 'export PATH=$HOME/.local/bin:$PATH; cd ~/my/vps/backup/wsl
# (a) retention is on and inherited -- these are the deletes that will fail
resticprofile -c profiles.yaml -n wsl show 2>/dev/null | grep -A6 -iE "^\s*retention"
# (b) the repo password is inside the backup set
grep -c "config/restic" .resticignore || echo "0 -- key is backed up into its own repo"'
```

Expected: retention showing `after-backup: true` and `prune: true`; `0` for the
exclusion.

- [ ] **Step 2: Replace the repository block (lines 35-51)**

```yaml
  # The repository URL now lives OUTSIDE this repo, in
  # /home/me/.config/restic/repo.txt, read via RESTIC_REPOSITORY_FILE. It has to:
  # the server requires htpasswd auth, restic's REST backend accepts credentials
  # only inside the URL, and this file is tracked. A URL here would commit a
  # transport password to a git repo; a URL on the command line would put it in
  # `ps`. Verified working with resticprofile 0.33.1 -- with no `repository` key
  # set, resticprofile passes no -r and restic resolves the repo from the env var.
  #
  # What that file contains, so nobody has to guess:
  #   rest:http://g614jv:<transport-password>@100.64.0.8:8001/g614jv
  #
  # Raw tailnet IP, not MagicDNS, to match the rest of the fleet's addressing - a
  # name here would add a dependency on --accept-dns being set on whichever box
  # runs the backup. (The SERVER now binds 0.0.0.0, so this address is a routing
  # choice, no longer a security one.)
  #
  # The path segment `g614jv` is also the htpasswd USERNAME, which is what
  # --private-repos requires: it maps a username to a top-level directory, so
  # user g614jv may access /g614jv and nothing else. It is what the old
  # `{{ .Hostname }}` template expanded to anyway -- a WSL distro inherits its
  # WINDOWS host name, not the distro nickname or the tailnet node name. Both of
  # desktop's distros therefore resolve to this one repo and SHARE it. That is
  # safe (restic keys snapshots by host + paths, so sharing dedupes rather than
  # clobbers) but it is not isolation - do not rely on it to separate two
  # distros. $WSL_DISTRO_NAME would name them properly and is deliberately not
  # used: it is set for interactive shells and absent from the systemd unit this
  # is scheduled as, so it would work by hand and produce a different repo path
  # on every scheduled run.
  #
  # Both files are OPERATIONAL copies and are escrowed in the private dotfiles
  # repo on this machine's own branch (desktop-wsl), which is the authoritative
  # off-box copy. The repo password is ALSO escrowed on latitude's branch,
  # because latitude prunes this repo and --append-only makes that impossible
  # from here. If this box is rebuilt, restore both from dotfiles.
  password-file: "/home/me/.config/restic/pass.txt"
  env:
    RESTIC_PASSWORD_FILE: "/home/me/.config/restic/pass.txt"
    RESTIC_REPOSITORY_FILE: "/home/me/.config/restic/repo.txt"
  # The repo exists and must never be silently recreated. base.yaml sets
  # initialize: true globally; if /mnt/spare320 is ever absent on latitude at
  # boot (it is mounted `nofail`) docker bind-mounts an empty directory, and an
  # initialising client would start a FRESH repo and report success. Explicit
  # false turns that silent data loss into a loud failure.
  initialize: false
  pack-size: 4
```

**Fallback if Step 5 shows restic cannot see the repo:** put the URL in
`repository:` templated from the environment
(`repository: "{{ .Env.WSL_RESTIC_URL }}"`) and set `WSL_RESTIC_URL` in the unit's
environment file instead. Do **not** fall back to writing the URL literally into
this tracked file.

- [ ] **Step 3: Replace the retention block (lines 73-78)**

```yaml
  retention:
    # OFF, and it must stay off. The server runs --append-only, which refuses
    # every DELETE except locks (repo/repo.go:737), so `forget` and `prune` both
    # get 403 - and with after-backup: true inherited from base.yaml that 403
    # fails the whole backup run, not just the retention step.
    #
    # Retention did not disappear, it MOVED: latitude prunes this repo from the
    # filesystem, bypassing the server, in backup/latitude/profiles.yaml. The
    # keep-* numbers below are the ones this profile used to declare and are now
    # declared there verbatim - keep-daily 14, keep-weekly 8, keep-monthly 12,
    # keep-yearly 5. If you change them, change them there.
    before-backup: false
    after-backup: false
    prune: false
```

- [ ] **Step 4: Add the credential directory to `.resticignore`**

Append:

```
# --- credentials ---
# The repo password and the repository URL (with its transport credential) live
# here. Backing them up into the repository they unlock is circular and puts a
# plaintext credential inside every snapshot. They are escrowed in the private
# dotfiles repo instead, on this machine's branch.
.config/restic/
```

- [ ] **Step 5: Verify the client can see BOTH pre-existing snapshots — exit criterion 2**

```bash
ssh desktop-wsl.gg.ez 'export PATH=$HOME/.local/bin:$PATH; cd ~/my/vps/backup/wsl && resticprofile -c profiles.yaml -n wsl snapshots'
```

Expected: the same 2 snapshot IDs recorded in Task 3 Step 2. This single command
proves four things at once: the new encryption password works, the transport
credential works, `--private-repos` resolves to the right directory, and the
history was preserved.

- [ ] **Step 6: Run a real backup and confirm retention no longer fails it**

```bash
ssh desktop-wsl.gg.ez 'export PATH=$HOME/.local/bin:$PATH; cd ~/my/vps/backup/wsl && resticprofile -c profiles.yaml -n wsl backup 2>&1 | tail -20'
ssh desktop-wsl.gg.ez 'export PATH=$HOME/.local/bin:$PATH; cd ~/my/vps/backup/wsl && resticprofile -c profiles.yaml -n wsl snapshots | tail -5'
```

Expected: the backup completes with a new snapshot ID, no `403`, no
`Fatal`. Snapshot count goes 2 → 3. This is the first successful backup since
2026-08-02.

- [ ] **Step 7: Fire the schedule rather than trusting the hand-run**

```bash
ssh desktop-wsl.gg.ez 'systemctl --user start resticprofile-backup@profile-wsl.service
sleep 5; systemctl --user show -p Result -p ExecMainStatus resticprofile-backup@profile-wsl.service
loginctl show-user me | grep Linger'
```

Expected: `Result=success`, `ExecMainStatus=0`, `Linger=yes`. The repo's own rule
is to verify a scheduled job by firing its schedule — a hand-run that passes while
the timer fails is exactly the failure `mirror-refresh.sh` shipped with. `Linger`
matters because `schedule-permission: user_logged_on` stops firing silently
without it.

- [ ] **Step 8: Commit (in `vps`)**

```bash
cd ~/my/vps
git add backup/wsl/profiles.yaml backup/wsl/.resticignore
git commit -m "fix(backup)!: credentialed URL out of tree, retention off, stop backing up the key

Three coupled client changes for the hardened hub.

The repository URL moves to /home/me/.config/restic/repo.txt via
RESTIC_REPOSITORY_FILE. The server now requires auth, restic's REST backend
takes credentials only in the URL, and this file is tracked -- so the URL
cannot live here. Verified with resticprofile 0.33.1: no repository key
set, no -r passed, restic resolves from the env var.

Retention is off because --append-only 403s every delete, and with
after-backup: true inherited that failed the entire run, not just the
retention step. The keep-* numbers move verbatim to latitude's profiles,
which prunes from the filesystem.

.resticignore excludes .config/restic: the password was being stored inside
the repository it unlocks. And initialize: false, so an absent /mnt/spare320
on latitude can no longer make a client silently start a fresh repo.

Verified: both pre-existing snapshots visible under the new credentials,
one new snapshot written, user timer Result=success.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git push origin main
ssh latitude 'cd ~/my/vps && git pull --ff-only origin main'
ssh desktop-wsl.gg.ez 'cd ~/my/vps && git pull --ff-only origin main'
```

---

### Task 7: Declare the prune that append-only requires, on latitude

`--append-only` is only affordable because retention has a home. This is that
home. It runs as a root-scope resticprofile job on latitude against the filesystem
path, bypassing the server entirely — which is the only way `forget --prune` can
work now — using the encryption password escrowed on latitude's branch in Task 4.

The mechanism is already proven on this box: `resticprofile-backup@profile-latitude`
and `resticprofile-check@profile-latitude` are both installed root-scope units
driven from this same file. Phase 4 of the design spec relocates this into
`machines` as generated output; until then it lives beside the profile that
already installs latitude's units.

**Files:**
- Modify: `~/my/vps/backup/latitude/profiles.yaml` (append a second profile)

**Interfaces:**
- Consumes: `/home/me/.config/restic/g614jv.pass.txt` (Task 4), Task 6's
  retention-disabled client.
- Produces: `resticprofile-forget@profile-g614jv-maintenance.timer` on
  latitude. Phase 2's report reads its result.

**Two things verified on desktop-wsl before this task was written, both of which
would have cost the implementer a cycle.** (1) A schedule on a `retention` section
is **deprecated** — resticprofile 0.33.1 prints *"Using a schedule on a
\"retention\" section is deprecated. Please move the schedule parameters to a
\"forget\" section instead."* So this uses a `forget:` section, which registers as
`schedule forget@<profile>` and installs
`resticprofile-forget@profile-<name>.{timer,service}`. (2) **`resticprofile
schedule --dry-run` is not dry** — it installed real units and reported *"scheduled
job probe/retention created"*. Use `show` to inspect a config; assume `schedule`
always writes.

- [ ] **Step 1: Confirm nothing prunes this repo today (the failing state)**

```bash
ssh latitude 'systemctl list-timers --all --no-pager | grep -iE "g614jv|maintenance" || echo "NO PRUNE JOB -- history grows forever"'
```

Expected: `NO PRUNE JOB`. With the client's retention now off (Task 6), this repo
has no retention at all until this task lands.

- [ ] **Step 2: Append the maintenance profile**

Add to `backup/latitude/profiles.yaml`:

```yaml
# The prune --append-only made latitude's job.
#
# The g614jv repo is written by desktop-wsl over REST, and the server runs
# --append-only, so the client cannot forget or prune: every DELETE but a lock
# gets 403 (repo/repo.go:737). Retention therefore runs HERE, against the
# filesystem, bypassing the server. This is the maintenance step the compose
# file used to reject --append-only over ("retention would have to become a
# server-side chore on latitude" with no home) -- it has a home now.
#
# It needs the CLIENT's encryption password, which is why that password is
# escrowed twice: on desktop-wsl's dotfiles branch for its own restore, and on
# this host's branch for this job. /home/me/.config/restic/g614jv.pass.txt is
# tracked on the `latitude` branch, mode 600; this unit runs as root and can
# read it.
#
# NOTE the trust boundary this makes explicit: --append-only protects against a
# compromised or confused CLIENT, not against this host. latitude holds the data
# and the key. The offsite copy on hub (phase 3 of the design spec) is what
# limits that blast radius.
#
# Phase 4 of the design spec generates this from fleet.json's backup block and
# moves it into `machines`, which owns the backup system. It lives here now
# because this file is what already installs latitude's root-scope restic units.
g614jv-maintenance:
  inherit: base-job
  # Filesystem path, NOT rest:. That is the whole point.
  repository: "/mnt/spare320/restic-rest/g614jv"
  password-file: "/home/me/.config/restic/g614jv.pass.txt"
  env:
    RESTIC_PASSWORD_FILE: "/home/me/.config/restic/g614jv.pass.txt"

  # A `forget` SECTION, not a scheduled `retention` one: resticprofile 0.33.1
  # deprecates a schedule on `retention` and tells you to move it here. This
  # registers as `schedule forget@g614jv-maintenance` and installs
  # resticprofile-forget@profile-g614jv-maintenance.{timer,service}.
  forget:
    # Verbatim from what backup/wsl/profiles.yaml used to declare, so moving the
    # job did not silently change the policy. If these change, change the
    # comment in the client profile too.
    keep-daily: 14
    keep-weekly: 8
    keep-monthly: 12
    keep-yearly: 5
    prune: true
    # 07:30: the client backs up at 06:00 and its slowest observed run was 14
    # minutes, so this starts well clear of it rather than contending for the
    # repo lock.
    schedule: "07:30"
    # System scope, matching the `latitude` profile above: the repo directory is
    # root-owned (drwx------) because the container writes it as root.
    schedule-permission: system
    schedule-lock-wait: 10m

  retention:
    # base-job carries keep-daily 7 / keep-weekly 8 / keep-monthly 12 /
    # keep-yearly 10 with after-backup: true. This profile never runs a backup,
    # so that is inert -- but if anyone ever invokes `backup` on it, the
    # inherited policy would forget with the WRONG numbers. Turn it off
    # explicitly rather than relying on nobody doing that.
    before-backup: false
    after-backup: false
    prune: false
```

- [ ] **Step 3: Install the schedule**

```bash
ssh -t latitude 'export PATH=/usr/sbin:/sbin:$PATH; cd ~/my/vps/backup/latitude && sudo -n resticprofile -c profiles.yaml -n g614jv-maintenance schedule'
ssh latitude 'systemctl list-timers --all --no-pager | grep -i g614jv'
```

Expected: `resticprofile-forget@profile-g614jv-maintenance.timer` listed with a
next-fire time, and **no deprecation warning** in the output — a warning about a
`retention` schedule means the `forget:` section did not take.

- [ ] **Step 4: Fire the schedule and verify the result, not the script**

```bash
ssh latitude 'systemctl start resticprofile-forget@profile-g614jv-maintenance.service
sleep 10; systemctl show -p Result -p ExecMainStatus resticprofile-forget@profile-g614jv-maintenance.service
journalctl -u resticprofile-forget@profile-g614jv-maintenance.service -n 15 --no-pager | tail -12'
```

Expected: `Result=success`, `ExecMainStatus=0`. With 3 snapshots all inside
`keep-daily: 14`, it should report nothing removed — a successful no-op, which is
the correct first result and proves the credential and path work.

- [ ] **Step 5: Confirm it removed nothing**

```bash
ssh desktop-wsl.gg.ez 'export PATH=$HOME/.local/bin:$PATH; cd ~/my/vps/backup/wsl && resticprofile -c profiles.yaml -n wsl snapshots | tail -6'
```

Expected: still 3 snapshots. A prune job that deletes on its first run against a
3-snapshot repo would mean the retention numbers were transcribed wrong.

- [ ] **Step 6: Commit (in `vps`)**

```bash
cd ~/my/vps
git add backup/latitude/profiles.yaml
git commit -m "feat(backup): declare the g614jv prune that --append-only made latitude's job

--append-only 403s every client-side delete, so retention for the repo
latitude HOSTS runs here, against the filesystem, bypassing the server.
This is the maintenance step the compose file rejected --append-only over
for having no home.

keep-* copied verbatim from backup/wsl/profiles.yaml so moving the job did
not change the policy. Reads the client's encryption password from the copy
escrowed on this host's dotfiles branch -- the second escrow exists exactly
for this.

Verified by firing the unit, not the script: Result=success, and nothing
removed from a 3-snapshot repo.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

### Task 8: Retire the shared key, then prove a restore

Two closures. The old fleet-shared password still opens `g614jv`, so
"per-client credentials" is not true until it is removed. And **no restore has
ever been performed from this repository** — the largest untested assumption in
the whole backup system, and the cheapest one to close.

**Files:**
- Modify (on latitude, not in any repo): the `keys/` object set inside
  `/mnt/spare320/restic-rest/g614jv`

**Interfaces:**
- Consumes: Task 3's second key, Task 6's working client.
- Produces: a repo openable only by its own password. Task 9's selfcheck asserts
  the end state.

- [ ] **Step 1: Confirm the shared password still opens the repo (the failing state)**

```bash
ssh -t latitude 'export PATH=/usr/sbin:/sbin:$PATH; sudo -n restic -r /mnt/spare320/restic-rest/g614jv --password-file /home/me/g513ie-prod-config/vps/backup/homeserver/pass.txt key list'
```

Expected: two keys, and the command succeeding at all is the fault — that file is
also latitude's own repo password.

- [ ] **Step 2: Remove the old key, addressing it by ID**

```bash
ssh -t latitude 'export PATH=/usr/sbin:/sbin:$PATH
R=/mnt/spare320/restic-rest/g614jv
sudo -n restic -r $R --password-file /home/me/.config/restic/g614jv.pass.txt key list
# then, with OLD_ID being the row that is NOT current:
sudo -n restic -r $R --password-file /home/me/.config/restic/g614jv.pass.txt key remove <OLD_ID>'
```

Authenticate with the **new** password so a typo cannot remove the key you are
holding. Never pass `--password-file` pointing at the key being removed.

- [ ] **Step 3: Verify the shared password no longer opens it, and the new one does**

```bash
ssh -t latitude 'export PATH=/usr/sbin:/sbin:$PATH
R=/mnt/spare320/restic-rest/g614jv
sudo -n restic -r $R --password-file /home/me/g513ie-prod-config/vps/backup/homeserver/pass.txt snapshots 2>&1 | tail -2
sudo -n restic -r $R --password-file /home/me/.config/restic/g614jv.pass.txt snapshots | tail -4'
```

Expected: the first fails (`wrong password or no key found`), the second lists 3
snapshots. Per-client credentials now hold.

- [ ] **Step 4: Restore one file and diff it — exit criterion 3, and a first**

From desktop-wsl, so the restore exercises the real client path (auth, REST,
`--private-repos`) rather than the filesystem shortcut:

```bash
ssh desktop-wsl.gg.ez 'export PATH=$HOME/.local/bin:$PATH; cd ~/my/vps/backup/wsl
T=$(mktemp -d)
SNAP=$(resticprofile -c profiles.yaml -n wsl --  snapshots --json 2>/dev/null | tail -1 | python3 -c "import sys,json;print(json.load(sys.stdin)[-1][\"short_id\"])" 2>/dev/null || echo latest)
resticprofile -c profiles.yaml -n wsl -- restore "$SNAP" --target "$T" --include /home/me/.bashrc 2>&1 | tail -5
diff -u /home/me/.bashrc "$T/home/me/.bashrc" && echo "RESTORE VERIFIED: byte-identical"
rm -rf "$T"'
```

Expected: `RESTORE VERIFIED: byte-identical`. If `restic` needs the plain form,
run it directly with `RESTIC_REPOSITORY_FILE` and `RESTIC_PASSWORD_FILE` exported
— the assertion is the diff, not the invocation style.

- [ ] **Step 5: Verify an authenticated client-side delete is still refused — against an object that does not exist**

Run it from desktop-wsl, which already holds the credentialed URL — so nothing has
to be re-typed or interpolated:

```bash
ssh desktop-wsl.gg.ez 'URL=$(cat ~/.config/restic/repo.txt); URL=${URL#rest:}
ZERO=0000000000000000000000000000000000000000000000000000000000000000
curl -s -o /dev/null -w "delete-nonexistent-snapshot=%{http_code}\n" -X DELETE "$URL/snapshots/$ZERO"
curl -s -o /dev/null -w "read-config-still-works=%{http_code}\n" "$URL/config"'
```

Expected: `delete-nonexistent-snapshot=403` and `read-config-still-works=200` —
deletes refused, reads unaffected.

**Do not test this with `forget --keep-last 1 --prune`.** That is the obvious
command and it is the wrong one: if append-only is working it returns 403, but if
it is *not* working — the exact case the test exists to detect — it deletes 2 of 3
snapshots, including both pre-existing ones. The failure mode of the test is the
disaster the test is for.

The object ID above is 64 zeros: it matches rest-server's `BlobPathRE` so the
request is well-formed, and it names nothing. Append-only's check runs *before* the
path is resolved (`repo.go:737`, ahead of `getObjectPath`), so a 403 comes back
whether or not the object exists — and without append-only the same request would
404 instead. Nothing can be destroyed on either branch.

- [ ] **Step 6: No commit** — repo-internal key state and a verification. Record
  the restore result in the plan's completion note.

---

### Task 9: Commit a selfcheck, then reboot latitude and re-verify — exit criterion 4

The failure being fixed is a boot race, and this repo's own rule is to verify a
scheduled job by firing its schedule, not by running the script. A
`docker compose up` that works proves nothing about the next boot. So: make the
assertions durable first, then reboot, then re-run them as one command.

This script is also the stopgap for the fault that made the outage last three
days — nothing scrapes the metrics, no unit has `OnFailure=`, and the client's
failure produced no output anywhere. Phase 2's `just backup-report` supersedes it
fleet-wide.

**Files:**
- Create: `~/my/vps/homeserver/restic-server/selfcheck.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: a repeatable post-boot verification. Phase 2 replaces it.

- [ ] **Step 1: Write the selfcheck**

```bash
#!/usr/bin/env bash
# Post-boot verification for the restic REST hub.
#
# Exists because this service failed silently twice: 29 h in 2026-08-02 and 3
# days in 2026-08-04, both from a bind race, both discovered by a manual audit
# rather than an alert. Nothing scrapes --prometheus, no unit has OnFailure=,
# and the only client's failure wrote no diagnostic anywhere.
#
# Run it after any reboot or any change to compose.yml. Phase 2 of
# machines/docs/superpowers/specs/2026-08-04-fleet-backup-consolidation-design.md
# replaces it with a fleet-wide report; until then this is the instrument.
#
# A non-interactive ssh PATH on Debian excludes /usr/sbin and /sbin, and this
# needs ss and findmnt.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

DRIVE_UUID="3a78fd88-deb0-4c1a-a576-14abd0631d57"
DATA="/mnt/spare320/restic-rest"
REPO="g614jv"
PORT=8001
rc=0

check() {  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok    %s (%s)\n' "$1" "$3"
  else
    printf 'FAIL  %s: expected %s, got %s\n' "$1" "$2" "$3"
    rc=1
  fi
}

# 1. The drive, by UUID. Every letter reshuffles across a reboot on this box, and
#    /mnt/spare320 is mounted `nofail` -- so an absent drive boots fine and
#    docker bind-mounts an EMPTY directory over it.
got_uuid="$(findmnt -no UUID /mnt/spare320 2>/dev/null)"
check "drive mounted by UUID" "$DRIVE_UUID" "${got_uuid:-absent}"

# 2. The repo's config object. This is the guard against the empty-bind-mount
#    case: with the drive absent, a client would find no repo and -- since
#    append-only still permits creating a NEW config -- could start a fresh one
#    and report success. Client-side `initialize: false` closes it; this makes it
#    loud regardless.
[ -e "$DATA/$REPO/config" ] && s=present || s=MISSING
check "repo config present" "present" "$s"

# 3. A published port. The trap: a reused container comes back with
#    HostConfig.PortBindings intact and NetworkSettings.Ports EMPTY -- running,
#    logging "start server on [::]:8000", reachable by nobody. Recovery is
#    `up -d --force-recreate`, never `up -d` or `start`.
ports="$(docker inspect restic-server --format '{{.NetworkSettings.Ports}}' 2>/dev/null)"
[ -n "$ports" ] && [ "$ports" != "map[]" ] && s=published || s="EMPTY(${ports:-no-container})"
check "port published" "published" "$s"

# 4. Something actually listening, on the wildcard address.
ss -lntp 2>/dev/null | grep -qE "(0\.0\.0\.0|\*):$PORT|\[::\]:$PORT" && s=listening || s=NOT_LISTENING
check "listening on 0.0.0.0:$PORT" "listening" "$s"

# 5. Auth enforced. A 200 here would mean --no-auth crept back, and with a
#    wildcard bind that is every device on the LAN with delete rights.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/$REPO/config" 2>/dev/null)"
check "unauthenticated refused" "401" "$code"

# 6. Append-only and private-repos actually enabled, read from what the process
#    reported at startup. This script holds no credentials, so it CANNOT test
#    append-only behaviourally: an unauthenticated DELETE returns 401, which
#    proves auth and would keep passing green with --append-only removed. The
#    startup log is the honest credential-free assertion. The behavioural proof
#    is an authenticated DELETE of a nonexistent snapshot object returning 403
#    (403 comes before path resolution, repo.go:737) -- run at Task 8 Step 5 of
#    the plan, not here.
logs="$(docker logs restic-server 2>&1)"
printf '%s' "$logs" | grep -q 'Append only mode enabled' && s=enabled || s=DISABLED
check "append-only enabled" "enabled" "$s"
printf '%s' "$logs" | grep -q 'Private repositories enabled' && s=enabled || s=DISABLED
check "private repos enabled" "enabled" "$s"
printf '%s' "$logs" | grep -q 'Authentication disabled' && s=DISABLED || s=enabled
check "authentication enabled" "enabled" "$s"

# 7. Freshness, which is the only assertion a lying exit status cannot fake. Read
#    from snapshot-file mtimes, so it needs no password and no cooperation from
#    the client: the box that failed cannot hide the failure.
newest="$(find "$DATA/$REPO/snapshots" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
if [ -z "$newest" ]; then
  printf 'FAIL  newest snapshot: none found\n'; rc=1
else
  age_h=$(( ( $(date +%s) - ${newest%.*} ) / 3600 ))
  if [ "$age_h" -le 26 ]; then
    printf 'ok    newest snapshot age (%sh, client is daily at 06:00)\n' "$age_h"
  else
    printf 'FAIL  newest snapshot age: %sh > 26h\n' "$age_h"; rc=1
  fi
fi

exit "$rc"
```

- [ ] **Step 2: Make it executable and run it — it must pass before the reboot**

```bash
cd ~/my/vps && chmod +x homeserver/restic-server/selfcheck.sh
git add homeserver/restic-server/selfcheck.sh && git commit -m "feat(restic-server): post-boot selfcheck for the fault that hid twice

Asserts every property that was individually false at some point in
the last three days: drive by UUID, repo config present, port published (not
merely bound), something listening, auth enforced, DELETE refused, newest
snapshot under 26 h.

Freshness is read from snapshot mtimes, so it needs no password and no
cooperation from the client -- the box that failed cannot hide the failure.
That is the one assertion a green-but-lying exit status cannot fake, and it
is what both outages needed.

Stopgap. Phase 2 of the backup design spec replaces it fleet-wide.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git push origin main
ssh latitude 'cd ~/my/vps && git pull --ff-only origin main && bash homeserver/restic-server/selfcheck.sh; echo "exit=$?"'
```

Expected: every line `ok`, `exit=0`. Do not write the check count into prose
anywhere — the script prints what it ran.

- [ ] **Step 3: Prove the selfcheck can fail — do not trust a check you have only seen pass**

```bash
ssh latitude 'cd ~/my/vps/homeserver/restic-server && docker compose stop && bash selfcheck.sh; echo "exit=$?"; docker compose up -d --force-recreate && sleep 5 && bash selfcheck.sh; echo "exit=$?"'
```

Expected: with the container stopped, `FAIL` on the port/listening/auth checks and
`exit=1`; after `--force-recreate`, all `ok` and `exit=0`. A check only ever
observed passing is not evidence.

- [ ] **Step 4: STOP — get explicit approval, then reboot latitude**

**Do not run this on the approval that authorized the plan.** It is the one
hard-to-reverse action here: latitude never sleeps by design and runs immich,
servarr, the backup timers and the REST hub, so a reboot takes all of them down and
any surprise on the way back up is discovered live. Ask, then run:

```bash
ssh latitude 'sudo -n systemctl reboot' || true
```

Do it deliberately and not at the end of a long session. Wait for it to come back:

```bash
until ssh -o ConnectTimeout=5 latitude 'uptime -p' 2>/dev/null; do sleep 10; done
```

- [ ] **Step 5: Re-verify after the reboot — this is the actual exit criterion**

```bash
ssh latitude 'uptime -p; cd ~/my/vps && bash homeserver/restic-server/selfcheck.sh; echo "exit=$?"'
ssh latitude 'docker inspect restic-server --format "Started={{.State.StartedAt}} RestartCount={{.RestartCount}} Ports={{.NetworkSettings.Ports}}"'
```

Expected: all `ok`, `exit=0`, and `Ports` **non-empty on a fresh boot with
`RestartCount=0`** — meaning the bind succeeded outright rather than being
retried. That is the difference between this fix and the old comment's claim.

- [ ] **Step 6: Confirm the client still works against the rebooted server**

```bash
ssh desktop-wsl.gg.ez 'export PATH=$HOME/.local/bin:$PATH; cd ~/my/vps/backup/wsl && resticprofile -c profiles.yaml -n wsl snapshots | tail -4'
ssh latitude 'systemctl list-timers --all --no-pager | grep -iE "g614jv|latitude" '
```

Expected: 3 snapshots listed, and both latitude timers (its own backup/check plus
the new g614jv prune) scheduled.

- [ ] **Step 7: Confirm the `machines` gate is still green, and commit the plan's completion**

```bash
cd ~/machines && just test 2>&1 | tail -5
```

Expected: 41 suites, 0 failures — this phase added no `machines` code, so any
movement here is unrelated and worth investigating before closing out.

Then flip this plan's status banner from `OPEN` to `DONE` with the measured exit
criteria recorded, and commit in `machines`.

---

## Out of scope, deliberately — do not fold these in

- **The manifest, the report, generation, `fleet-notify`.** Phases 2-5. This phase
  is config plus live operations; the instrument comes next.
- **hub ↔ latitude cross-backup, the three docker volumes, headscale's DB, air as
  a client, the archive target off the Ventoy stick.** Phase 3.
- **`check-before: true` never executing.** Declared, inherited, resolved by
  `show`, never run on either profile; a placement hypothesis was tested and
  disproved. Open question 1 in the spec. This phase routes around it and does not
  investigate it.
- **latitude's own repo password still living under the stale
  `g513ie-prod-config/` dotfiles prefix**, named after a box that left the fleet.
  Renaming it is a dotfiles change with its own blast radius; note it, leave it.
- **`--prometheus` now needs credentials** to scrape, since auth applies to
  `/metrics` unless `--prometheus-no-auth` is set. Nothing scrapes it today.
  Whoever wires a scraper decides between a credential and that flag.
- **Item 16 of the repo review** (the four documents describing a stale restic
  world). It lands with Phase 2, when there is a current world to describe.

## Self-review notes

- **Spec coverage.** Phase 1's named deliverables map as: htpasswd → Task 2;
  `--private-repos` → Task 5 (and Task 2's username choice, which removes the
  spec's `mv`); `--append-only` → Task 5; `0.0.0.0` → Task 5; per-client
  credentials → Tasks 3, 4, 8; `.resticignore` excludes `~/.config/restic` →
  Task 6; the declared prune timer → Task 7. Exit criteria 1-4 → Task 5 Step 4,
  Task 6 Step 5, Task 8 Step 4, Task 9 Step 5.
- **Two spec corrections, both measured rather than argued.** The server-side
  directory `mv` is unnecessary (`--private-repos` maps a username to a top-level
  directory; username `g614jv` leaves the path unchanged), and the escrow gained a
  second file per client because the *transport* credential also has to live
  somewhere outside a tracked repo.
- **Two things this plan adds that the spec did not have.** Task 1 exists because
  latitude runs the restic units out of a work tree that was 11 commits behind, so
  a compose edit would have been inert on the only box that runs it. And Task 6's
  `initialize: false` closes a silent-reinit path the spec did not name: `nofail`
  plus `initialize: true` plus append-only's permission to create a *new* config
  means an absent drive could produce a fresh empty repo reporting success.
