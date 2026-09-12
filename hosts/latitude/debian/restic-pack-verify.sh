#!/usr/bin/env bash
# restic-pack-verify.sh — prove a restic repository's bytes are intact, with NO
# password and NO restic binary.
#
# WHY THIS EXISTS AND WHAT IT REPLACES. The offsite box must be able to catch
# bitrot on its own disk. The obvious tool, `restic check --read-data`, needs the
# repository password — which would put the key next to the ciphertext in a house
# nobody occupies, so a stolen box would hand over every photo. It also needs to
# read the data, and doing that from Almaty over a residential uplink means
# pulling 5% of a terabyte on every run.
#
# It is unnecessary. MEASURED ON LATITUDE 2026-09-12: a restic pack file's NAME
# is the SHA-256 of its own stored bytes.
#
#   /mnt/wd8/restic/latitude/data/8a/8a1f4ccec0325b33172aa7b558604f4b8e5990f6c87c7cce88bf9f8b5030cc75
#   sha256sum                        8a1f4ccec0325b33172aa7b558604f4b8e5990f6c87c7cce88bf9f8b5030cc75
#
# So hashing every file under data/, index/ and snapshots/ and comparing with its
# own name is a 100% read-data check that needs no key at all — stronger coverage
# than `--read-data-subset 5%`, on a box that holds nothing but ciphertext.
#
# WHAT IT DOES NOT COVER, and nobody should later claim it did:
#   * That blobs DECRYPT. A pack can be byte-perfect and the key wrong.
#   * That the index agrees with the packs, or that a snapshot's tree resolves.
# Those are structural, they live in metadata, and metadata is small — so they
# are checked from Almaty with a keyed, metadata-only `restic check` over the
# link. The split is deliberate: bytes here, structure there, and neither end can
# hide the other's failure.
#
#   ./restic-pack-verify.sh /mnt/vault/restic/latitude
#   ./restic-pack-verify.sh /mnt/vault/restic/latitude --baseline /var/lib/offsite/baseline.sha
#
# EXIT — two failures must never share one status (AGENTS.md). Surveyed against
# every other exit map that runs on the offsite box before these were chosen:
# install-rest-server.sh uses 1/2/3/78/79 and install-timers.sh uses 20..23, so
# 4 and 5 were free.
#   0  clean
#   1  a hash mismatch — a content-addressed file's bytes are not its name
#   2  usage, or a precondition (the path is not a restic repository)
#   4  a content-addressed DIRECTORY is missing: data/, index/ or snapshots/ is
#      not there at all. This is a collapse in COVERAGE, not corruption, and it
#      is the one the sweep used to report as `files=1 bad=0`, exit 0 — `find`
#      walked whatever subset existed and 2>/dev/null hid the rest, so a repo
#      with every pack file deleted rendered healthy all the way to the board.
#   5  a file under them could not be READ (stat or sha256sum failed): a vanished
#      file, an EIO on a dying platter, a permission error. Counting it BAD would
#      attribute corruption to a file nobody read; skipping it silently is the
#      failure class this whole script exists to catch. It is its own state.
# Precedence when several apply: 4 returns before any hashing; otherwise a
# confirmed mismatch (1) outranks an unread file (5), because it is the
# actionable one — and the counts for BOTH are carried in the summary line, so
# the rc can never be the only place a failure is visible.
#
# THE SUMMARY LINE IS THE MACHINE-READABLE CONTRACT, one line, always printed:
#   files=<n> bad=<n> bytes=<n> unreadable=<n> missing=<none|data,index,…> \
#     baseline=<ok|none> secs=<n>
# offsite-verify.sh parses it field by field into verify.json. `files` and
# `bytes` are there because their absence was the root enabler of the coverage
# bug above: one file hashed and four hundred thousand files hashed used to be
# byte-identical downstream.

# ── pure helpers (unit-tested by provision/tests/backup-offsite.test.sh) ──────

# Is this relative path named by the hash of its own contents?
rpv_is_content_addressed() {
    case "$1" in data/* | index/* | snapshots/*) echo yes ;; *) echo no ;; esac
}

# Empty when the basename equals the hash; a BAD line naming the file otherwise.
rpv_check_line() {
    local rel="$1" sha="$2"
    [ "${rel##*/}" = "$sha" ] || printf 'BAD %s\n' "$rel"
}

# ── main ─────────────────────────────────────────────────────────────────────

rpv_main() {
    local repo="${1:-}" baseline="" rel sha sz line d missing="" t0
    local files=0 bad=0 bytes=0 unreadable=0 bl=none
    [ -n "$repo" ] || { echo "usage: $0 <repo-dir> [--baseline <file>]" >&2; return 2; }
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            # `shift 2` with one argument left is a no-op that returns 1 — under
            # no `set -e` that is an infinite loop, not an error message.
            --baseline)
                [ $# -ge 2 ] || { echo "--baseline needs a file" >&2; return 2; }
                baseline="$2"; shift 2 ;;
            *) echo "unknown argument: $1" >&2; return 2 ;;
        esac
    done
    # A missing drive leaves an ordinary empty directory under a `nofail` mount,
    # so "the path exists" proves nothing. Test the repo's own config object.
    [ -f "$repo/config" ] || { echo "not a restic repository: $repo" >&2; return 2; }

    t0=$SECONDS

    # EXISTENCE of each content-addressed directory, asserted BEFORE the sweep.
    # Not non-emptiness: a freshly initialised repository has an empty index/,
    # and refusing that would be a gate that cries wolf. `find data index
    # snapshots 2>/dev/null` walked whatever subset existed and the suppressed
    # stderr hid the rest, so a tree with data/ and index/ deleted outright swept
    # one snapshot and printed `files=1 bad=0`, exit 0.
    for d in data index snapshots; do
        [ -d "$repo/$d" ] || missing="${missing:+$missing,}$d"
    done
    if [ -n "$missing" ]; then
        printf 'MISSING %s (no coverage at all for %s)\n' "$missing" "$missing"
        printf 'files=0 bad=0 bytes=0 unreadable=0 missing=%s baseline=%s secs=%s\n' \
            "$missing" "$bl" "$((SECONDS - t0))"
        return 4
    fi

    while IFS= read -r rel; do
        [ "$(rpv_is_content_addressed "$rel")" = yes ] || continue
        files=$((files + 1))
        sz="$(stat -c %s "$repo/$rel" 2>/dev/null)"
        sha="$(sha256sum "$repo/$rel" 2>/dev/null | cut -d' ' -f1)"
        case "$sz" in '' | *[!0-9]*) sz="" ;; esac
        # A file that could not be measured or hashed is its own state. The old
        # form was `bytes=$((bytes + $(stat -c %s ...)))`: a failed stat expanded
        # to nothing, bash printed an arithmetic syntax error to stderr nobody
        # reads, and the file stayed counted in `files` while never being
        # verified at all.
        if [ -z "$sz" ] || [ -z "$sha" ]; then
            unreadable=$((unreadable + 1)); printf 'UNREADABLE %s\n' "$rel"
            continue
        fi
        bytes=$((bytes + sz))
        if [ -n "$(rpv_check_line "$rel" "$sha")" ]; then
            bad=$((bad + 1)); rpv_check_line "$rel" "$sha"
        fi
    done < <(cd "$repo" && find data index snapshots -type f | sort)

    # config and keys/* are NOT content-addressed, so they are compared against a
    # recorded baseline instead of against their own names. Without a baseline
    # they are reported and not judged — silence would read as "verified". The
    # `baseline=` field carries that all the way into status.json: the NOTE alone
    # was scraped by nobody, so an operator who forgot to copy baseline.sha left
    # config and keys/* unjudged forever with no signal anywhere.
    if [ -n "$baseline" ] && [ -f "$baseline" ]; then
        bl=ok
        while read -r want rel; do
            [ -n "${want:-}" ] || continue
            sha="$(sha256sum "$repo/$rel" 2>/dev/null | cut -d' ' -f1)"
            if [ -z "$sha" ]; then
                unreadable=$((unreadable + 1)); printf 'UNREADABLE %s (baseline)\n' "$rel"
            elif [ "$sha" != "$want" ]; then
                bad=$((bad + 1)); printf 'BAD %s (baseline)\n' "$rel"
            fi
        done < "$baseline"
    else
        printf 'NOTE config and keys/* not judged (no --baseline)\n'
    fi

    printf 'files=%s bad=%s bytes=%s unreadable=%s missing=none baseline=%s secs=%s\n' \
        "$files" "$bad" "$bytes" "$unreadable" "$bl" "$((SECONDS - t0))"
    if [ "$bad" -gt 0 ]; then return 1; fi
    if [ "$unreadable" -gt 0 ]; then return 5; fi
    return 0
}


# Sourceable: the suite sources this file to drive the pure helpers above.
[ -n "${RESTIC_PACK_VERIFY_LIB_ONLY:-}" ] || { set -uo pipefail; export PATH=/usr/sbin:/sbin:/usr/bin:/bin; rpv_main "$@"; exit $?; }
