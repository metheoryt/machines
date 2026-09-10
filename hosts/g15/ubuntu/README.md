# g15 — Ubuntu 26.04 (`g513ie`)

Per-machine ops for the personal-projects host, reinstalled from Windows 11 on
2026-09-07. Design: `docs/superpowers/specs/2026-09-07-g15-linux-migration-design.md`.

**Why this directory is `ubuntu/` and the manifest says `debian`.** `platform`
in `fleet.json` is a *class* token meaning "posix, not darwin, not WSL" — every
posix role executor allowlists `nixos|wsl|debian|darwin` and its fallback arm
prints "no posix executor" and returns **0**, so `ubuntu` there would have
skipped `dotfiles` and `repos` while `--apply` reported success. The directory
name follows the real OS, like `hosts/latitude/debian` and
`hosts/desktop/windows` do.

## `compose.override.yml` + `install-compose-override.sh`

qaz-code's DB bind-mounts `/data/qaz-code/pgdata` instead of a named docker
volume, because the 186 GB PGDATA was rsync'd in physically and a named volume
could not have received it without root inside docker's storage dir. The image
is pinned **by digest**: a pgvector minor bump or a different glibc collation
would let the DB start and then misbehave on the text and vector indexes.

The live file is host-local and excluded in qaz-code's machine-local
`.git/info/exclude`, so it had no home in git until now. The script copies it in
and re-adds that exclude line — see its header for why the exclude is
load-bearing rather than cosmetic.

Facts worth having before touching the database:

- **The 184 GB lives in the DEFAULT `postgres` database**, not a named one. `\l`
  showing only the three system DBs is not a failed restore. `act_version`
  104 GB, `act_version_chunk` 80 GB, extension `vector 0.8.4`.
- **The compose project is `qaz-law` while the directory is `qaz-code`.**
- **PGDATA at `999:0` mode 700 is correct.** uid 999 is `postgres` in the
  container and `dnsmasq` on Ubuntu, so `ls -l` on the host reads alarmingly.
  Check numerically (`stat -c %u`), never by name. postgres validates the mode
  at startup, so it cannot be handed to `me` without also running the container
  as uid 1000, which then needs the socket dir moved.
- **This database is NOT in restic, and since 2026-09-10 that is a decision,
  not a gap.** Owner's call: it is rebuildable, so it needs no backup. The
  input it is built from — `~/my/qaz-code/laws`, 7.6 GB of scraped corpus — IS
  in `backup/g15/profiles.yaml`, so the expensive half is protected and the
  186 GB derived index is not stored. `backup/g15/profiles.yaml` carries the
  full argument and the measurements.
  - **The 186 GB staging copy at
    `latitude:/mnt/immich-mirror/g15-staging/pgdata` was DELETED 2026-09-10**,
    after re-confirming the live DB up on g15 (126 GB, container running).
    This file said it was "the ONLY second copy" and "must not be deleted"
    until 2026-09-11 — true when written, false now.
  - The method stays recorded because it is what a rebuild-from-scratch would
    otherwise have to re-derive: proven on this exact data (phase 1 staged it
    with the DB shut down; postgres 18.4 came up with a clean recovery), the
    container's STOPSIGNAL is `SIGINT`, i.e. postgres fast shutdown — a clean
    one, and `me` is in the `docker` group, so stop/start needs no privilege.
    Reading PGDATA does, because of the mode above.

## Orca desktop install — the traps, not a script

Orca runs as a **native GUI app** here, not the headless `serve` runtime it was
under WSL: a headless `serve` holds Electron's one-instance-per-userData lock
and the desktop app then cannot open at all. `provision/orca-serve.sh` gates its
autostart on WSL since `63472aa` and stays in the repo for `desktop-wsl`.

Deliberately prose and not an installer: `orca-serve.sh` already owns the
extract mechanism, and a re-extracting script in `hosts/` can clobber a live
install — which already happened here once.

- **An AppImage does not "install" on Ubuntu 26.04.** The release ships fuse3
  only, no `libfuse2`, and AppImageKit type-2 needs the second — `chmod +x` and
  run dies on `libfuse.so.2`. **`--appimage-extract` is the install**, and it
  needs neither FUSE nor root. The trap only bites a hand-downloaded AppImage;
  `orca-serve.sh` has always extracted.
- **Setuid on `chrome-sandbox` does nothing for Orca**, and leaves a setuid-root
  binary in `$HOME`. `AppRun` decides the sandbox by probing `unshare -Ur true`;
  Ubuntu ships `kernel.apparmor_restrict_unprivileged_userns = 1`, so the probe
  fails and AppRun appends `--no-sandbox` unconditionally. It never looks at
  `chrome-sandbox`. The real route to a sandbox is an AppArmor profile granting
  userns to the launcher path — not setuid, and not `--no-sandbox` for a tool
  that runs agent code.
- **`cat > path` follows a symlink and truncates its TARGET.** `~/.local/bin/orca-ide`
  is a symlink into the install, so writing "to the symlink" replaced Orca's own
  1592-byte CLI shim with a four-line wrapper. Restored from a second extraction
  of the same AppImage. `orca-serve.sh:170` already carried `rm -f` before its
  `>` with a comment saying exactly this — the lesson was in the repo and not
  applied.
- **The CLI wrapper is `orca-cli` here, not `orca`.** `~/.local/bin` sits ahead
  of `/usr/bin` in a login PATH, and `/usr/bin/orca` is GNOME's screen reader.
  `orca_cli_name` steps aside automatically on a desktop box;
  `provision/orca-serve.test.sh` pins it.
- **`orca-serve.sh`'s "none of [libxkbcommon0] installed" warnings over ssh are
  a sudo artifact**, not missing packages: `me` has no NOPASSWD sudo here, so
  every `$SUDO apt-get install` fails non-interactively and warns. On a desktop
  box the libs come with GNOME anyway.

## Restoring from staging

Phase 1 pushed as root into `/mnt/immich-mirror/g15-staging` on latitude, so
every restore leg is a **pull** needing `--rsync-path="sudo rsync"` on the
sending side — local sudo does nothing for it. Without the flag rsync exits 23
on the first unreadable directory, part-way through, and reads as a destination
permissions problem rather than a source one. The direction is forced anyway:
latitude has no `~/.ssh/id_fleet`, so it cannot originate fleet ssh.
