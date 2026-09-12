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
# EXIT: 0 clean · 1 a hash mismatch · 2 usage or precondition (not a repo).
# Distinct on purpose — see AGENTS.md, two failures must not share one status.

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
    local repo="${1:-}" baseline="" rel sha files=0 bad=0 bytes=0 t0
    [ -n "$repo" ] || { echo "usage: $0 <repo-dir> [--baseline <file>]" >&2; return 2; }
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --baseline) baseline="${2:-}"; shift 2 ;;
            *) echo "unknown argument: $1" >&2; return 2 ;;
        esac
    done
    # A missing drive leaves an ordinary empty directory under a `nofail` mount,
    # so "the path exists" proves nothing. Test the repo's own config object.
    [ -f "$repo/config" ] || { echo "not a restic repository: $repo" >&2; return 2; }

    t0=$SECONDS
    while IFS= read -r rel; do
        [ "$(rpv_is_content_addressed "$rel")" = yes ] || continue
        files=$((files + 1))
        bytes=$((bytes + $(stat -c %s "$repo/$rel")))
        sha="$(sha256sum "$repo/$rel" | cut -d' ' -f1)"
        if [ -n "$(rpv_check_line "$rel" "$sha")" ]; then
            bad=$((bad + 1)); rpv_check_line "$rel" "$sha"
        fi
    done < <(cd "$repo" && find data index snapshots -type f 2>/dev/null | sort)

    # config and keys/* are NOT content-addressed, so they are compared against a
    # recorded baseline instead of against their own names. Without a baseline
    # they are reported and not judged — silence would read as "verified".
    if [ -n "$baseline" ] && [ -f "$baseline" ]; then
        while read -r want rel; do
            sha="$(sha256sum "$repo/$rel" 2>/dev/null | cut -d' ' -f1)"
            [ "$sha" = "$want" ] || { bad=$((bad + 1)); printf 'BAD %s (baseline)\n' "$rel"; }
        done < "$baseline"
    else
        printf 'NOTE config and keys/* not judged (no --baseline)\n'
    fi

    printf 'files=%s bad=%s bytes=%s secs=%s\n' "$files" "$bad" "$bytes" "$((SECONDS - t0))"
    [ "$bad" -eq 0 ]
}

# Sourceable: the suite sources this file to drive the pure helpers above.
[ -n "${RESTIC_PACK_VERIFY_LIB_ONLY:-}" ] || { set -uo pipefail; export PATH=/usr/sbin:/sbin:/usr/bin:/bin; rpv_main "$@"; exit $?; }
