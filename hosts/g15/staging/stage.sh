#!/usr/bin/env bash
# hosts/g15/staging/stage.sh — move g15's payload onto latitude before the
# Windows -> Debian 13 wipe. Phase 1 of
# docs/superpowers/specs/2026-09-07-g15-debian-migration-design.md
#
# RUNS ON g15-wsl, AS ROOT. Not on latitude, not on Windows.
#
#   ./stage.sh cmd          <payload> [kind]  print the rsync command, run nothing
#   ./stage.sh manifest-cmd <payload> src|dst print the manifest pipeline, run nothing
#   ./stage.sh plan         <payload> [delete] rsync -n: what would move (or remove)
#   ./stage.sh stage        <payload>         the copy (logs to $LOGDIR; detach it)
#   ./stage.sh restage      <payload>         a SECOND pass, with --delete
#   ./stage.sh verify       <payload>         manifest both sides and diff
#   ./stage.sh status                         sizes on both sides + log tails
#
#   payload: pgdata | home  -> latitude (ext4)
#            music          -> desktop  (NTFS, port 2222)
#   kind:    go | dry | delete | delete-dry
#   exit:    0 ok · 1 not root · 2 usage · 3 postgres running · 4 manifest
#            mismatch · 5 restage into a missing or empty destination
#
# WHY `restage` IS A SEPARATE WORD. Task 8 re-runs `home` days after Task 6 and
# then demands an EXACT manifest match — the spec's point of no return. Without
# --delete, a file deleted under /home/me in between lingers at the destination
# and that gate fails on a copy which is otherwise correct. But --delete must
# not be the default: on a first pass it is a no-op, and on a mistyped
# STAGE_DIR it removes whatever is at that path instead.
#
# WHY ROOT, ALWAYS, EVEN TO LOOK. pgdata's directories are mode 700 owned by
# uid 999, so `find` cannot descend as `me` — the manifest, not just the copy,
# needs root. And `me` has no NOPASSWD sudo here, so root comes from Windows:
#   printf '%s\n' 'cd /home/me/machines/hosts/g15/staging' './stage.sh …' \
#     | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
#
# WHY THE LAN ADDRESS AND NOT latitude.gg.ez. This distro runs in NAT
# networking mode, so tailscale cannot punch through to another NATed peer and
# the tailnet path is DERP-relayed via hub in Kazakhstan — 3.3 MB/s, re-measured
# 2026-09-07 with both laptops on a 1201 Mbps WiFi 6 link, so the radio was
# never the problem. NAT permits OUTBOUND, which is why pushing to latitude's
# LAN address gets 78 MB/s. 293 GB is 63 minutes one way and 20 hours the other.
#
# WHY rsync AND NOT THE CHUNKED TAR THE SPEC NAMES — a deliberate deviation.
# scratchpad/xfer2.sh was chunked because that transfer went through Windows
# sshd -> wsl.exe, where a raw tar stream was the only simple fast path. This
# route is the distro pushing outbound over plain ssh; rsync 3.4.1 is on both
# ends; and there are ZERO hardlinks in either ext4 tree (checked 2026-09-07:
# `find -type f -links +1` is empty for pgdata and for /home/me), which was the
# other thing tar bought. rsync then resumes per file with no marker
# bookkeeping AND lands an extracted tree — which is what the spec's own
# manifest check needs, since chunked tar would have to be extracted on arrival
# before it could be verified at all. The spec's requirement was resumability;
# this satisfies it with less to get wrong.
#
# --partial-dir, NOT --append-verify — the settled answer in this repo, see
# hosts/latitude/debian/archive-mirror.sh's header. A drop mid-file leaves a
# truncated file at the destination; --partial-dir parks it under
# .rsync-partial/ so it is never mistaken for a complete one, and rsync uses it
# as the delta basis next run. --append-verify assumes the destination is a
# strict prefix of the source, which a torn write does not guarantee.
#
# --rsync-path='sudo rsync' because `me` on latitude HAS NOPASSWD sudo (checked
# 2026-09-07) and pgdata's metadata is NOT uniform: 999:999 mode 600 files under
# directories that are 0:0 755, 999:0 700, 999:999 700 and 999:999 755. A
# blanket chown+chmod on restore would get it wrong, so ownership and modes are
# preserved numerically at copy time instead.
#
# NO pv, NO zstd — neither is installed and installing needs the password-gated
# sudo. --info=stats2 is the progress report.
set -uo pipefail

KEY="${STAGE_KEY:-/home/me/.ssh/id_fleet}"
LAT="${STAGE_LAT:-me@192.168.8.155}"
# Music goes to desktop, not latitude — his machine, his call. Port 2222 because
# .wslconfig puts desktop-wsl in mirrored networking, so the distro shares the
# Windows adapters and the Windows OpenSSH server already owns 22 (ssh.socket
# had been losing that bind race since 2026-08-29). Inbound 2222 needs a
# Windows firewall rule; it is in place, scoped to 192.168.8.0/24.
DESK="${STAGE_DESK:-me@192.168.8.145}"
DESK_PORT="${STAGE_DESK_PORT:-2222}"
STAGE="${STAGE_DIR:-/mnt/immich-mirror/g15-staging}"
DESKDIR="${STAGE_DESKDIR:-/mnt/c/Users/methe/g15-staging}"
LOGDIR="${STAGE_LOGDIR:-/var/log/g15-staging}"
PGPID="${STAGE_PGPID:-/data/qaz-law/pgdata/18/docker/postmaster.pid}"

# -i + IdentitiesOnly: ssh to a bare IP does NOT pick up the fleet identity,
# because the generated config keys on `Host *.gg.ez`. Without these it fails in
# 0.2 s having moved nothing, which reads exactly like no bandwidth — three
# false measurements on 2026-09-07 came from precisely this.
# ServerAlive*: a 40-minute transfer over wifi needs the connection probed, or a
# silent stall is indistinguishable from progress.
SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
SSH_OPTS="$SSH_OPTS -o ServerAliveInterval=30 -o ServerAliveCountMax=6"

usage() {
    # A heredoc, not `sed -n '5,16p' "$0"`: a line-range into this file's own
    # header drifts silently the first time a comment is added above, and no
    # test catches it — the suite can only assert the exit code.
    cat >&2 <<'USAGE'
stage.sh — move g15's payload onto latitude. Runs ON g15-wsl, AS ROOT.

  ./stage.sh cmd          <payload> [kind]  print the rsync command, run nothing
  ./stage.sh manifest-cmd <payload> src|dst print the manifest pipeline, run nothing
  ./stage.sh plan         <payload> [delete] rsync -n: what would move (or remove)
  ./stage.sh stage        <payload>         the copy (logs to $LOGDIR; detach it)
  ./stage.sh restage      <payload>         a SECOND pass, with --delete
  ./stage.sh verify       <payload>         manifest both sides and diff
  ./stage.sh status                         sizes on both sides + log tails

  payload: pgdata | home  -> latitude (ext4)
           music          -> desktop  (NTFS, port 2222)
  kind:    go | dry | delete | delete-dry
  exit:    0 ok · 1 not root · 2 usage · 3 postgres running · 4 manifest
           mismatch · 5 restage into a missing or empty destination
USAGE
    exit 2
}
# "$1", NOT "$*": the second argument is the exit code, and $* would print it
# as part of the message — measured, the root refusal ended in a stray " 1".
die()  { printf '%s: %s\n' "${0##*/}" "$1" >&2; exit "${2:-1}"; }
say()  { printf '[%s] %s\n' "$(date +%F_%H:%M:%S)" "$*"; }

require_root() {
    [ "$(id -u)" = 0 ] && return 0
    # $MODE/$P rather than "$@": the caller passes nothing, and the point of the
    # message is to hand back a runnable line.
    die "must run as root (pgdata's dirs are mode 700 owned by uid 999, so even
find cannot descend as $(id -un); and sudo needs a password on this distro).
Route:
  printf '%s\\n' 'cd $(cd "$(dirname "$0")" && pwd)' './${0##*/} $MODE $P' \\
    | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'" 1
}

payload_src() {
    case "$1" in
        pgdata) printf '%s\n' /data/qaz-law/pgdata ;;
        home)   printf '%s\n' /home/me ;;
        music)  printf '%s\n' /mnt/c/Users/methe/Music ;;
        *)      return 1 ;;
    esac
}

payload_dst() {
    case "$1" in
        pgdata) printf '%s\n' "$STAGE/pgdata" ;;
        home)   printf '%s\n' "$STAGE/home-me" ;;
        # Under the user's own directory: a mkdir at C:\ root is refused
        # without admin (measured 2026-09-07).
        music)  printf '%s\n' "$DESKDIR/Music" ;;
        *)      return 1 ;;
    esac
}

# WHY THE DESTINATION IS SPLIT. Two facts, both measured 2026-09-07 on desktop,
# and neither of them about free space:
#   - drvfs INVENTS ownership and modes. After chown 999:999 + chmod 600, stat
#     reads `me:me 777`. pgdata's files are 999:999 mode 600 under directories
#     in four different combinations, and /home/me carries .ssh — on NTFS both
#     arrive with fictional metadata and a restore would have to guess.
#   - drvfs costs 6.6 ms per file: 19.8 s for 3000 files against 0.03 s on ext4.
#     /home/me is 226003 files, so NTFS would add ~25 minutes of pure per-file
#     overhead. Music is 14878 files averaging 6 MB and loses nothing.
# desktop-wsl's own ext4 is not a third option: 99 GB total, 60 GB free.
#
# The cost is throughput: g15 and desktop are both on wifi, so their traffic
# crosses the access point twice — 40 MB/s measured, against 78 MB/s to
# latitude, which sits on cable (enp0s31f6). Music therefore takes ~37 minutes
# rather than ~19. Inherent to the path, not a setting.
payload_host() {
    case "$1" in
        pgdata|home) printf '%s\n' "$LAT" ;;
        music)       printf '%s\n' "$DESK" ;;
        *)           return 1 ;;
    esac
}

payload_port() {
    case "$1" in
        pgdata|home) printf '%s\n' 22 ;;
        music)       printf '%s\n' "$DESK_PORT" ;;
        *)           return 1 ;;
    esac
}

# `me` on latitude HAS NOPASSWD sudo; `me` on desktop-wsl does NOT — measured,
# it answers "sudo: A terminal is required to authenticate". A sudo there would
# hang a 37-minute transfer waiting for a password nobody can type, and Music
# needs no privilege anyway: drvfs would discard the metadata regardless.
payload_remote_sudo() {
    case "$1" in
        pgdata|home) printf '%s\n' yes ;;
        music)       printf '%s\n' no ;;
        *)           return 1 ;;
    esac
}

# The destination manifest must descend pgdata's mode-700 directories, so it
# needs root there; on desktop everything is drvfs and readable as `me`, and
# sudo would block on a password prompt.
remote_sh() {   # $1 payload
    case "$(payload_remote_sudo "$1")" in
        yes) printf '%s\n' 'sudo bash -s' ;;
        no)  printf '%s\n' 'bash -s' ;;
        *)   return 1 ;;
    esac
}

ssh_opts_for() {   # $1 payload
    local port
    port="$(payload_port "$1")" || return 1
    printf '%s' "$SSH_OPTS"
    [ "$port" = 22 ] || printf ' -p %s' "$port"
}

payload_flags() {
    # -x on every payload so the copy and the manifest's pruning agree about
    # where the tree ends.
    case "$1" in
        pgdata)
            printf '%s\n' -a -x --numeric-ids ;;
        home)
            # rsync cannot copy a socket; without the exclude it prints
            # "skipping non-regular file" and exits 23, which then has to be
            # distinguished from a real error on every run.
            printf '%s\n' -a -x --numeric-ids '--exclude=*.sock' ;;
        music)
            # drvfs invents ownership and permissions for every NTFS file, so -a
            # would copy fiction and then fail to set it. Same shape
            # archive-mirror.sh uses for exfat, for the same reason. mtimes ARE
            # real, hence -t and --modify-window=1 for the granularity.
            printf '%s\n' -rlt -x --no-perms --no-owner --no-group --modify-window=1 ;;
        *)  return 1 ;;
    esac
}

CMD=()
build_cmd() {   # $1 payload  $2 go|dry|delete|delete-dry
    local src dst host opts
    src="$(payload_src "$1")" || return 1
    dst="$(payload_dst "$1")" || return 1
    host="$(payload_host "$1")" || return 1
    opts="$(ssh_opts_for "$1")" || return 1
    local -a f=()
    mapfile -t f < <(payload_flags "$1")
    f+=(--partial --partial-dir=.rsync-partial '--exclude=.rsync-partial/'
        --human-readable --info=stats2)
    # --delete is opt-in by its own word and never a default. On the FIRST
    # pass into a fresh directory it is a no-op; on a mistyped STAGE_DIR it is
    # not. See the restage arm for the guard that goes with it.
    case "$2" in
        dry)        f+=(-n) ;;
        delete)     f+=(--delete) ;;
        delete-dry) f+=(--delete -n) ;;
    esac
    local -a rp=()
    [ "$(payload_remote_sudo "$1")" = yes ] && rp=(--rsync-path='sudo rsync')
    CMD=(rsync "${f[@]}" -e "ssh $opts" "${rp[@]+"${rp[@]}"}"
         "$src/" "$host:$dst/")
    return 0
}

# The manifest: PATH, type, size, symlink target — one line per entry, with a
# size for REGULAR FILES ONLY. A directory's reported size is a property of the
# filesystem rather than of its contents, so comparing it produces false diffs,
# and across drvfs -> ext4 it would make every single directory differ. Sockets
# are dropped on both sides because rsync never copies one. .rsync-partial is
# pruned: a parked torn file is not content.
#
# PATH IS THE FIRST FIELD, and that is not cosmetic. With the size first, `sort`
# orders by size as a STRING (5000 before 6), so the manifest is not in path
# order and one file whose size differs moves its line to a different position
# entirely — the diff then reports a large spurious block instead of pointing at
# the one path that is wrong. Caught while writing this plan, on exactly that
# tree of test entries.
#
# Compared on both sides with `diff`, and NEVER with `du`: du totals match even
# when one file is truncated, which is exactly what a killed transfer leaves.
manifest_find() {
    cat <<'MF'
LC_ALL=C find . -mindepth 1 -name .rsync-partial -prune -o \
  \( -type f -printf '%p\tf\t%s\n' \) -o \
  \( -type l -printf '%p\tl\t-\t%l\n' \) -o \
  \( -type s \) -o \
  \( -printf '%p\t%y\t-\n' \) | LC_ALL=C sort
MF
}

manifest_cmd() {   # $1 payload  $2 src|dst
    local d
    case "$2" in
        src) d="$(payload_src "$1")" || return 1 ;;
        dst) d="$(payload_dst "$1")" || return 1 ;;
        *)   return 1 ;;
    esac
    printf 'cd %q && \\\n' "$d"
    manifest_find
}

MODE="${1:-}"; P="${2:-}"; ARG="${3:-}"

case "$MODE" in
    cmd)
        [ -n "$P" ] || usage
        case "${ARG:-go}" in go|dry|delete|delete-dry) ;; *) usage ;; esac
        build_cmd "$P" "${ARG:-go}" || die "unknown payload: $P" 2
        printf '%q ' "${CMD[@]}"; printf '\n'
        ;;

    manifest-cmd)
        [ -n "$P" ] || usage
        case "$ARG" in src|dst) ;; *) usage ;; esac
        manifest_cmd "$P" "$ARG" || die "unknown payload: $P" 2
        ;;

    plan)
        [ -n "$P" ] || usage
        # `plan` means dry, so `plan <payload> delete` is the DRY delete pass:
        # it lists what --delete would remove, which is the whole point of
        # previewing it.
        case "${ARG:-}" in ''|dry) K=dry ;; delete) K=delete-dry ;; *) usage ;; esac
        build_cmd "$P" "$K" || die "unknown payload: $P" 2
        require_root
        say "dry run: $P"
        "${CMD[@]}"
        ;;

    stage|restage)
        [ -n "$P" ] || usage
        payload_src "$P" >/dev/null || die "unknown payload: $P" 2
        # The guard comes BEFORE the root check so it is reachable in the gate,
        # and because "postgres is still running" is the more useful message of
        # the two when both are true.
        if [ "$P" = pgdata ] && [ -e "$PGPID" ]; then
            die "postgres is still running — $PGPID exists.
A live PGDATA copies torn, and the result looks exactly like a backup; see
hosts/latitude/debian/mirror-refresh.sh's header. Stop it first:
  docker update --restart=no qaz-law-db-1 && docker stop qaz-law-db-1" 3
        fi
        require_root
        K=go
        if [ "$MODE" = restage ]; then
            K=delete
            # A delete pass is only ever a SECOND pass. Refuse a destination
            # that does not already hold a first one: with --delete armed
            # against the wrong path, rsync removes what is there. The check
            # goes AFTER require_root so a non-root run in `just test` stops at
            # the root refusal instead of reaching for the network.
            dstq="$(payload_dst "$P")"
            q="$(printf 'test -d %q && [ -n "$(ls -A %q)" ]' "$dstq" "$dstq")"
            # A here-string, not a pipe: with pipefail on, a pipe would let the
            # writer's EPIPE outvote ssh's own exit code.
            ssh $(ssh_opts_for "$P") "$(payload_host "$P")" "$(remote_sh "$P")" <<<"$q" \
                || die "restage refuses: $(payload_host "$P"):$dstq is missing or empty.
A delete pass is only ever a SECOND pass over a destination that already holds
one. Run 'stage $P' first, or fix STAGE_DIR." 5
        fi
        build_cmd "$P" "$K" || die "unknown payload: $P" 2
        mkdir -p "$LOGDIR" && chmod 755 "$LOGDIR"
        # 755 so the log is tailable over the DIRECT ssh into the distro as
        # `me`, instead of every progress check having to go back through
        # Windows for root.
        exec >>"$LOGDIR/$P.log" 2>&1
        say "=== $MODE $P"
        say "src=$(payload_src "$P")  dst=$(payload_host "$P"):$(payload_dst "$P")"
        mk="mkdir -p $(payload_dst "$P")"
        [ "$(payload_remote_sudo "$P")" = yes ] \
            && mk="sudo $mk && sudo chown me:me $(payload_dst "$P")"
        ssh $(ssh_opts_for "$P") "$(payload_host "$P")" "$mk" </dev/null \
            || die "could not create the destination directory"
        "${CMD[@]}"; rc=$?
        case "$rc" in
            0)  say "rsync clean" ;;
            24) say "rsync exit 24 (source files vanished mid-run) — benign here, treating as done"; rc=0 ;;
            *)  say "rsync exit $rc — re-run '$MODE $P', it resumes from .rsync-partial" ;;
        esac
        say "=== done rc=$rc"
        exit $rc
        ;;

    verify)
        [ -n "$P" ] || usage
        payload_src "$P" >/dev/null || die "unknown payload: $P" 2
        require_root
        mkdir -p "$LOGDIR" && chmod 755 "$LOGDIR"
        s="$LOGDIR/$P.src.manifest"; d="$LOGDIR/$P.dst.manifest"
        say "manifest: source $(payload_src "$P")"
        manifest_cmd "$P" src | bash > "$s" || die "source manifest failed"
        say "manifest: destination $(payload_host "$P"):$(payload_dst "$P")"
        manifest_cmd "$P" dst | ssh $(ssh_opts_for "$P") "$(payload_host "$P")" \
            "$(remote_sh "$P")" > "$d" || die "destination manifest failed"
        sn=$(wc -l < "$s"); dn=$(wc -l < "$d")
        say "entries: src=$sn dst=$dn"
        if cmp -s "$s" "$d"; then
            say "MANIFEST MATCH — $sn entries, path+size+symlink-target identical"
        else
            say "MANIFEST MISMATCH — first 40 differing lines:"
            diff -u "$s" "$d" | head -40
            say "full manifests: $s and $d"
            exit 4
        fi
        ;;

    status)
        require_root
        for p in pgdata home music; do
            printf '%-7s %8s  %s\n' "$p" \
                "$(du -sh "$(payload_src "$p")" 2>/dev/null | cut -f1)" \
                "$(payload_src "$p")"
        done
        printf -- '--- destinations:\n'
        for p in pgdata home music; do
            dd="$(payload_dst "$p")"; pre=""
            [ "$(payload_remote_sudo "$p")" = yes ] && pre="sudo "
            printf '%-7s %s:%s\n' "$p" "$(payload_host "$p")" "$dd"
            ssh $(ssh_opts_for "$p") "$(payload_host "$p")" \
                "df -h ${dd%/*} | tail -1; ${pre}du -sh $dd 2>/dev/null" </dev/null \
                | sed 's/^/  /'
        done
        printf -- '--- logs:\n'
        for f in "$LOGDIR"/*.log; do
            [ -e "$f" ] || continue
            printf '%s:\n' "$f"; tail -3 "$f" | sed 's/^/  /'
        done
        ;;

    *)  usage ;;
esac
