# g513ie → latitude migration: what actually has to move

Status: **research, incomplete.** Written 2026-07-30.

Scope: moving the remaining workloads off `g513ie` (the G15, Windows 11 + Docker
Desktop, logical name `server`) onto `latitude` (Dell Latitude 5520, Debian 13,
now carrying `profile: server`) before g513ie is decommissioned. Naming per the
convention: **`g513ie` and `latitude` only** — `server` is ambiguous here,
because the SSH alias and tailnet node literally named `server` still resolve to
g513ie while `fleet.json` gives latitude `profile: server`.

The music migration is finished and verified — see §13 of
`2026-07-29-storage-pool-hardware-baseline.md`. This document covers what remains:
Docker workloads, configs, and repos.

## 0. The blocker, first

**Docker Desktop is not running on g513ie, and it cannot be started over ssh.**

```
NAME              STATE           VERSION
* Ubuntu-26.04      Running         2
  docker-desktop    Stopped         2
```

```
failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine;
check if the path is correct and if the daemon is running
```

Docker Desktop is a desktop application: it needs an interactive user session, and
an ssh session is not one. Until it is started at the console or through RustDesk,
**no container, volume, image, or database can be enumerated** — every size and
count in the Docker section below is unknown, not merely unmeasured.

The single command that sizes the entire project, once the engine is up:

```
docker system df -v
```

That splits reclaimable image layers and build cache from actual named volumes.
Nothing downstream should be designed before its output is known.

## 1. What the 158 GB is not

```
158.09 GB  C:\Users\methe\AppData\Local\Docker\wsl\disk\docker_data.vhdx
  0.15 GB  C:\Users\methe\AppData\Local\Docker\wsl\main\ext4.vhdx
```

`docker_data.vhdx` is **not** the migration payload. It is a sparse virtual disk
that grows and never shrinks, and it holds three quite different things mixed
together:

| Content | Migrates? |
|---|---|
| image layers | **No** — repull from the registry |
| build cache | **No** — disposable by definition |
| named volumes | **Yes** — this is the entire payload |

So the real transfer size is unknown and is very likely a small fraction of 158
GB. Sizing it is what `docker system df -v` is for. Treating 158 GB as the
transfer estimate would be planning against a number that mostly represents
throwaway layers.

Also note the Docker Desktop data disk is **not file-portable** to native Linux
docker. There is no supported way to attach that VHDX to Debian's docker. The
route is per-volume export while the engine runs:

```
docker run --rm -v <volume>:/from -v /mnt/host/out:/to alpine \
  tar -C /from -cf /to/<volume>.tar .
```

which, again, requires the engine.

## 2. Databases: the one step that fails silently

**Never `tar` a live database volume.** A Postgres, MySQL, or Mongo data
directory copied while the server is running is torn across its own write path —
the copy succeeds, the archive looks fine, and the failure only appears at
restore time, possibly much later. This is the single step in the whole migration
where a mistake produces no error at the moment it is made.

Two acceptable methods, in order of preference:

1. **Logical dump against the running container** — `pg_dumpall`, `mysqldump`,
   `mongodump`. Portable across versions and architectures, verifiable by
   restoring into a scratch container before g513ie is touched.
2. **Stop, then export** — `docker compose stop`, then the `tar` above. Faster for
   large data, but only valid if the container is genuinely stopped, not paused.

A dump that has not been restored somewhere is not a backup. The verification
step belongs *before* decommissioning, not after.

## 3. Repos: nothing to migrate

Four repos under `C:\Users\methe\my`, plus a `machines` checkout:

| Repo | Size | Remote | Dirty | Unpushed | Stashes |
|---|---|---|---|---|---|
| `embedthat` | 0.40 GB | `https://github.com/metheoryt/embedthat.git` | 64 | 0 | 0 |
| `skep` | 0.00 GB | `git@github.com:metheoryt/skep.git` | 115 | 0 | 0 |
| `telegrind` | 0.01 GB | `git@github.com:metheoryt/telegrind.git` | 0 | 0 | 0 |
| `vps` | 0.02 GB | `git@github.com:metheoryt/vps.git` | 50 | 0 | 0 |
| `machines` | — | `git@github.com:metheoryt/machines.git` | 666 | 0 | 0 |

The dirty counts look alarming and are **entirely line-ending churn**:

```
machines:   0 of 666 files still differ under -w --ignore-cr-at-eol
skep:       0 of 114
embedthat:  0 of  64
vps:        0 of  48
```

Every "modified" file is byte-identical once CRLF is ignored — the signature of a
Windows checkout against a repo storing LF. With zero unpushed commits and zero
stashes across all five, **no repo carries any work that would die with the box.**

Migration action: `git clone` on latitude. Nothing to transfer, nothing to rescue.
Bytes were never the risk here; unpushed commits would have been, and there are
none.

The three `??` untracked entries (1 in `skep`, 2 in `vps`) are the only files not
accounted for by CRLF and should be looked at individually before the box goes.

## 4. Configs: the partition that matters

`C:\Users\methe` carries roughly twenty tool/agent config directories:

```
.agents .cache .cagent .claude .codex .commandcode .config .copilot .cursor
.docker .factory .gemini .gk .gortex .grok .hermes .kimi-code .local .omp
.openclaude .orca .pi .spotdl .ssh .vscode
```

The whole config task is one question asked per directory: **does this already
have a home, or does it die with the box?** Per the dotfiles convention some of
these are tracked at real `$HOME` paths and sync on their own; the rest are
machine-local state that no mechanism preserves. Untracked config surviving only
until the machine dies is precisely the failure the dotfiles repo exists to
prevent, and a decommission is when that bill comes due.

Not yet enumerated — this is the next concrete research step, and it is cheap:
for each directory, check whether the dotfiles bare repo tracks the corresponding
path on this host's branch.

Note `.claude/settings.json`, `.claude/memory/project.md` and
`.claude/kb-harvest-state.json` appear as modified in *every* repo above, which
means per-repo Claude state is being carried inside the project repos themselves
and is already version-controlled there. Distinguish that from
`C:\Users\methe\.claude`, which is user-scope and a different question.

## 5. Placement constraints

- **Service configs belong in `vps`, not `machines`.** The repo boundary is
  machine-versus-service: `machines` owns provisioning and backup, `vps` owns the
  services the box runs. `vps` is already checked out on g513ie with a clean
  history, so some of this may already be version-controlled — check before
  copying anything by hand.
- `embedthat` and `telegrind` are independent projects with their own remotes and
  their own compose files (`/mnt/c/Users/methe/my/{embedthat,telegrind}/compose.yml`).
  They get cloned, not migrated.

## 6. Gate: latitude's root is unencrypted

`/dev/nvme1n1p3` is plain ext4, 453 GB, no LUKS. Moving service databases there
puts personal data at rest unencrypted on a laptop — a laptop being materially
different from a desktop because it leaves the building.

**This is a decision to make before the transfer, not after**, because reversing
it means re-encrypting a root that already holds the data. It is the same standing
hold as §9 of the hardware baseline, but the migration is what makes it load-
bearing rather than theoretical: until now latitude held no service data.

Related and smaller: `~/.restic-pw` currently sits on that same unencrypted root
and should be removed once the 320 G work is done.

## 7. Operational notes for g513ie

Facts that cost time this session and will cost it again:

- **The default ssh shell on g513ie is PowerShell, not cmd.** POSIX redirections
  are parsed by PowerShell — `wsl -l -q 2>/dev/null` tries to write a file called
  `C:\dev\null` and fails with `OpenError: DirectoryNotFoundException`.
- **Quoting does not survive the hop.** Double-quoted PowerShell here-strings
  repeatedly failed with `The string is missing the terminator`. Base64 the script
  as UTF-16LE and run `powershell -NoProfile -EncodedCommand <b64>` — no quoting
  surface at all. The same trick works for bash inside WSL.
- **Never `find` across `/mnt/c` from inside WSL.** drvfs traversal is
  pathologically slow; an inventory script hit a 120 s timeout and produced
  nothing. Enumerate Windows paths with PowerShell, Linux paths with `find`.
- **Long tasks need `Win32_Process.Create`,** not `Start-Process` — see §11.7 of
  the hardware baseline. Windows OpenSSH destroys the session's job object on
  disconnect and takes any child with it.
- Cyrillic output breaks `tr -d '\000'` with `Illegal byte sequence`; use
  `tr -cd '\11\12\15\40-\176'` or base64 the whole response.

## 8. Sequence, once the engine is up

1. Start Docker Desktop on g513ie (console or RustDesk) — **user action, blocks
   everything below.**
2. `docker system df -v`, `docker volume ls`, `docker ps -a` → the real inventory.
3. Classify each volume: database versus plain data.
4. Databases: logical dump, then **restore into a scratch container on latitude
   and verify** before anything is deleted.
5. Plain volumes: `tar` export per volume.
6. Install native docker on latitude (Debian 13, no Docker Desktop needed).
7. Clone the repos; bring compose files across via their repos, not by copy.
8. Enumerate the config directories against the dotfiles branch; track what has no
   home before the box dies.
9. Only then decommission — and per the migration plan's standing rule, no wipe,
   no sale, no reformat of any drive until a restore verification passes.

## 9. Open questions

- What volumes exist, and how much do they actually hold? (blocked on §0)
- Which of the ~20 config directories are already tracked? (cheap, not yet done)
- What are the three untracked files in `skep` and `vps`?
- Does latitude's root get encrypted before or after the databases land? (§6)
- Does anything still depend on the `server` SSH alias resolving to g513ie? The
  alias will need to move or be retired as part of decommissioning.

---

# Part II: the real inventory (engine up, 2026-07-30 01:2x)

Docker Desktop was started at the console. Engine 29.6.2. §0's blocker is cleared
and the numbers below replace the unknowns above.

## 10. The payload is 21.3 GB, and most of that is disposable too

```
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          54        20        55.14GB   30.56GB (55%)
Containers      20        3         226.1MB   187.8MB (83%)
Local Volumes   40        4         21.3GB    21.24GB (99%)
Build Cache     72        0         9.706GB   6.826GB
```

§1's prediction holds: the 158 GB VHDX contains 55 GB of images and 9.7 GB of
build cache that do not migrate, and the volume total is **21.3 GB** — 13% of the
disk's apparent size. Of that, the single largest named volume is disposable:

| Volume | Size | Links | Disposition |
|---|---|---|---|
| `immich_model-cache` | 6.505 GB | 0 | **drop** — ML weights, redownload on demand |
| anonymous `3ad6bda1…` | 7.581 GB | 0 | identify before dropping |
| anonymous `e05572c9…` | 7.075 GB | 0 | identify before dropping |
| `telegrind_pgdata` | 57.31 MB | 1 | **Postgres — logical dump** |
| anonymous `21f11937…` | 37.86 MB | 0 | identify |
| anonymous `d8caab8c…` | 32.97 MB | 0 | identify |
| `forgejo_forgejo_data` | 2.683 MB | 1 | export |
| `embedthat_redis_data` | 1.335 MB | 1 | redis cache — likely drop |
| `embedthat-bot_redis_data` | 1.258 MB | 0 | duplicate of the above, stale project name |
| `jellyseerr_jellyseerr-data` | 309.2 kB | 0 | export |
| `jellyseerr-data` | 308.6 kB | 0 | duplicate, pre-compose naming |
| `tugtainer_tugtainer_data` | 45.12 kB | 1 | export |
| `telegrind_weights`, `forgejo_data` | 0 B | 0 | empty, drop |

Two 7 GB anonymous volumes are 14.7 GB — the largest unattributed item and the
one thing that must be identified before any `docker volume prune`. Anonymous
volumes with `Links: 0` are exactly what a prune deletes, and 99% of the volume
total is reclaimable by docker's reckoning, which is not the same as safe to
reclaim.

Note the duplicate pairs (`jellyseerr-data` / `jellyseerr_jellyseerr-data`,
`embedthat_redis_data` / `embedthat-bot_redis_data`). Compose project renames left
orphaned copies behind; the live one is the one with `Links: 1`.

## 11. 20 containers, 3 running — the stack is already mostly down

```
speedtest            running   (healthy)
immich_redis         running   (healthy)
immich_postgres      restarting  (1) — see §12
embedthat-bot-1, embedthat-worker-1, telegrind-bot-1, telegrind-postgres-1,
jellyfin, jellyseerr, sonarr, radarr, prowlarr, bazarr, whisparr, qbittorrent,
embedthat-redis-1, forgejo, beat, tugtainer, restic-server   — exited
```

Most exited `137` (SIGKILL) 24 hours ago — consistent with a host shutdown, not
individual failures. `forgejo` has been down two weeks. This is convenient: an
already-stopped stack removes §2's hot-copy hazard for everything except what is
still running.

## 12. immich's database was never on g513ie — it is already on latitude

The single most consequential finding. `immich_postgres` mounts:

```
bind | D:\ImmichMedia\postgres        -> /var/lib/postgresql/data
bind | D:\ImmichMedia\library\backups -> /backups
```

**`D:` does not exist on g513ie any more.** That drive is the Kingston NVMe
labelled `Immich`, which now lives in latitude as `/mnt/immich`. So the immich
data directory is already physically on the target machine:

| Path on latitude | Size |
|---|---|
| `/mnt/immich/ImmichMedia/postgres` | 803 MB — `PG_VERSION` = `14` |
| `/mnt/immich/ImmichMedia/library` | **244 GB** — the media library |

Nothing to transfer. The migration for immich is to run the same image against
the same directory on latitude.

This also explains the restart loop. With the Windows path gone, Docker Desktop
resolved the bind into its own VM filesystem, which is out of space:

```
FATAL:  could not write lock file "postmaster.pid": No space left on device
```

That failure is *protective* — it is why no phantom empty cluster got written
where the real one used to be. But the loop should be stopped rather than left
running.

### 12.1. The cluster was not shut down cleanly

```
postmaster.pid:  pid 1 ... ready      (written Jul 27 23:46)
pg_wal newest:   0000000100000001000000CE   Jul 27 23:51
```

A stale pid file marked `ready` and WAL written minutes later means Postgres was
running when the drive was pulled out from under it. First start will perform
**crash recovery**, which is a write to the data directory — and if it goes wrong
there is no second attempt.

Snapshot taken before anything touches it, from the still-read-only mount:

```
~/immich-db-preserve/postgres-prerecovery-20260730.tar   803 MB, 1937 entries, verified readable
```

803 MB is free insurance against a 244 GB library becoming unindexable.

### 12.2. Two constraints on first start

- **Use the same image**, `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`.
  A plain `postgres:14` lacks the `pg_vectors` / vectorchord extensions the cluster
  was created with, and the `pg_vectors` directory in the data dir confirms they
  are in use. A mismatched build will fail to load them.
- **`/mnt/immich` is currently `ro`.** That is deliberate for the migration and
  must be flipped to `rw` for Postgres — which means the read-only safety net comes
  off at the same moment crash recovery runs. Do the snapshot restore-test first.

## 13. Revised sequence

1. ~~Start Docker Desktop~~ — done.
2. Stop the `immich_postgres` restart loop on g513ie so it cannot write anywhere.
3. Identify the two 7 GB anonymous volumes. **Nothing gets pruned before this.**
4. `telegrind_pgdata`: `pg_dumpall` from the (currently exited) container — start
   it, dump, stop. It is 57 MB; a logical dump is trivially cheap here.
5. Export `forgejo_forgejo_data`, `tugtainer_tugtainer_data`,
   `jellyseerr_jellyseerr-data` by tar. All are single-digit MB.
6. Drop `immich_model-cache`, the empty volumes, and the orphaned duplicate pairs.
7. immich on latitude: native docker, same postgres image, `/mnt/immich` remounted
   `rw`, snapshot verified first.
8. Clone the repos (§3 — nothing to rescue).
9. Enumerate the config directories against the dotfiles branch (§4).
10. Decommission only after a restore verification passes.

## 14. What is still unknown

- The two 7 GB anonymous volumes (§10) — blocks the prune step.
- Whether `telegrind_pgdata` holds anything wanted, or is a dev scratch database.
- The three untracked files in `skep` / `vps` (§3).
- Which config directories are already tracked (§4).
- Whether the immich cluster recovers cleanly — unknown until step 7, which is
  why §12.1's snapshot exists.

## 15. Resolved: the docker payload is ~62 MB

The four anonymous volumes of §10 are all **Python virtualenvs**, and they
self-declare as disposable — every one carries a `CACHEDIR.TAG`, the standard
marker meaning "regenerable cache, do not archive":

```
CACHEDIR.TAG  bin  lib  lib64  pyvenv.cfg  share
```

The largest identifies itself outright:

```
prompt = embedthat-bot
uv = 0.9.3
version_info = 3.12.12

4.3G  site-packages/nvidia      <- CUDA wheels
1.7G  site-packages/torch
593M  site-packages/triton
```

A uv-managed venv reproducible from a lockfile, four-fifths of it CUDA and torch
wheels. The 14.7 GB that looked like the second-largest item in the migration is
build output from removed containers.

**Final disposition of all 21.3 GB:**

| Category | Size | Action |
|---|---|---|
| 2 large orphaned venvs | 13.8 GB | drop — regenerate with `uv sync` |
| `immich_model-cache` | 6.5 GB | drop — redownloads |
| 2 small orphaned venvs | 80 MB | drop |
| empty + orphaned duplicate volumes | ~2 MB | drop |
| **`telegrind_pgdata`** | **57.31 MB** | **logical dump** |
| `forgejo_forgejo_data` | 2.683 MB | tar |
| `embedthat_redis_data` | 1.335 MB | drop (redis cache) or tar |
| `jellyseerr_jellyseerr-data` | 309 kB | tar |
| `tugtainer_tugtainer_data` | 45 kB | tar |

**The entire docker volume migration is ~62 MB.** Plus immich, which needs no
transfer at all because its 803 MB cluster and 244 GB library are already on
latitude's NVMe (§12).

The arc is worth stating plainly, because it is the general lesson: the apparent
size went 158 GB → 21.3 GB → 62 MB. Each reduction came from asking what the bytes
*are* rather than how many there are. A `du`-shaped view of this migration would
have planned a multi-hour transfer of regenerable CUDA wheels and a database that
was already at the destination.

`CACHEDIR.TAG` deserves specific note: tooling that writes it is telling you the
directory is disposable. Checking for it is cheaper than reasoning about contents,
and here it flagged 14 GB correctly before any package listing was read.

## 16. Decisions taken 2026-07-30 (user)

### 16.1. latitude's root stays unencrypted — the hold is closed

**Decided: no encryption on latitude.** Rationale given: it is a home,
permanently plugged-in laptop, and passwords at rest on it are acceptable.

This closes both §6 of this document and the standing hold at §9 of
`2026-07-29-storage-pool-hardware-baseline.md`. It is a deliberate, informed
choice rather than an oversight, and it should not be re-raised as an open
question in future work. The threat model it accepts: physical theft of the
machine yields the service databases, the media library index, and any
credentials sitting on the root.

The consequence for planning is that **prod `.env` files and database dumps may
live on latitude's root directly**, which simplifies §13's sequence considerably.

### 16.2. forgejo is dropped

Not used. `forgejo_forgejo_data` (2.683 MB) is removed from the migration list —
no export, no restore. The container has been down two weeks anyway.

### 16.3. Everything on g513ie is stopped

Restart policies cleared on all 20 containers, then all stopped:

```
docker update --restart=no $(docker ps -aq)
docker stop $(docker ps -q)
```

`docker ps` is now empty; all 20 report `exited`. This ends the `immich_postgres`
restart loop of §12 and removes the last hot-copy hazard from §2 — every volume
on the box is now quiescent, so a `tar` export is safe for all of them.

Clearing the restart policy *before* stopping matters: with `restart: always`
still set, a stop can be undone by the daemon or by Docker Desktop restarting.

## 17. The gitignored prod config — transferred and verified

This was the genuine loss risk, and it is the category §4 pointed at: files with
no home in any repo, which die with the machine. All of it lives in `vps` (the
per-service prod environment) and `telegrind`.

Nineteen files, transferred to `~/g513ie-prod-config/` on latitude, mode 700,
deliberately **outside any repo checkout** so no future `git add` can reach them:

| Source | Files |
|---|---|
| `vps/homeserver/*/.env` | `beat`, `embedthat`, `immich`, `navidrome`, `restic-server`, `servarr`, `tugtainer`, `watchtower` |
| `vps/homeserver/telegrind/.env.prod` | 1 |
| `vps/backup/homeserver/pass.txt` | the restic repository password |
| `vps/homeserver/.{embedthat,telegrind}-last-deployed` | deploy state markers |
| `telegrind/` | `.env`, `.env.prod`, `compose.override.yml`, `google-account.json` |
| `.claude/settings.local.json` | in `vps`, `skep`, and `vps/homeserver/tugtainer` |

152 KB total. Content verified with `rsync -ac --dry-run -i` against the source —
zero differing files.

Three findings worth keeping:

- **`embedthat` has no secrets of its own.** Its 13742 ignored files are all
  `node_modules`-shaped. The prod `.env` for it lives at
  `vps/homeserver/embedthat/.env`, which is the pattern for every service: the
  application repo carries code, `vps` carries that service's environment.
- **`backup/homeserver/pass.txt` is the restic password**, identical to the one
  used in §13.2 of the hardware baseline apart from line endings (13 bytes CRLF
  versus 12 LF). So the credential was already preserved in `vps` all along, and
  the ad-hoc `~/.restic-pw` created for that investigation was redundant — it has
  been removed.
- **The "three untracked files" open question from §3 is resolved.** They were
  `.claude/settings.local.json` in `skep`, `vps`, and `vps/homeserver/tugtainer` —
  machine-local agent settings, now transferred with the rest.

A filter caveat that nearly cost two files: the first sweep piped
`ls-files --others --ignored` through `head -40`, which silently truncated
`vps`'s list and hid `homeserver/tugtainer/.env` and `homeserver/watchtower/.env`.
They only appeared when the sweep was re-run filtering by *name pattern* instead
of by position. **When enumerating things you must not miss, never bound the
output by count.**

Deliberately not transferred: `homeserver/embedthat/src/` and
`homeserver/telegrind/src/` — deployed copies of source that regenerate from the
repos.

## 18. Remaining work

1. `telegrind_pgdata` (57 MB) — start the container, `pg_dumpall`, stop, restore
   into a scratch container on latitude to verify. The only real database export
   left, now that forgejo is dropped and immich needs no transfer.
2. Export `jellyseerr_jellyseerr-data` (309 kB) and `tugtainer_tugtainer_data`
   (45 kB) by tar. All containers are stopped, so this is safe.
3. immich on latitude: native docker, image
   `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`, `/mnt/immich`
   remounted `rw`, §12.1's snapshot on hand before crash recovery runs.
4. Clone the repos and drop `~/g513ie-prod-config/` contents into their gitignored
   slots.
5. Enumerate the ~20 config directories under `C:\Users\methe` against the
   dotfiles branch (§4) — still not done, and the same "no other home" logic that
   made §17 urgent applies to them.
6. Decommission only after a restore verification passes.
