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
