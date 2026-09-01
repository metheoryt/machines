#!/usr/bin/env bash
# provision/backup-client.sh — install THIS box's restic schedule.
#
#   bash provision/backup-client.sh [--dry-run] [<identity>]
#
# THE PROFILE DIR IS KEYED ON WHO THE BOX IS, not on which fleet.json entry owns
# the hardware. Windows and each WSL distro on it are separate boxes with
# separate things to lose, so each gets its own client and its own backup/<id>/.
# Identity is a fleet.json machine name (latitude, desktop, g15) or a
# fleet.local.json nickname (desktop-wsl, g15-wsl) -- one flat namespace, and the
# names are already unique. Each box provisions itself from the chain that
# already provisions it, so nothing reaches across a machine boundary.
#
# ── THE TRAP THIS RESOLVER EXISTS TO CLOSE ───────────────────────────────────
# `fleet_detect` returns the WRONG machine on a WSL box, differently wrong on
# each one. On desktop-wsl `hostname` is g614jv -- which IS `desktop`'s
# detect.hostname -- so detection returns `desktop`, and this distro would
# schedule WINDOWS' profile against its own filesystem. On g15-wsl the OS
# hostname is not g513ie, so detection returns nothing at all. Same code, two
# different wrong answers.
#
# So fleet.local.json's nickname WINS OUTRIGHT: if it exists, fleet_detect is
# never consulted. This is AGENTS.md's documented `{{ .Hostname }}`-expands-to-
# the-Windows-hostname trap wearing a different hat, and fleet-local.sh's own
# header records the same asymmetry as the reason `--parent` must be declared
# rather than inferred.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# backup_client_identity — echo this box's backup identity, or nothing.
backup_client_identity() {
    local f="$REPO/fleet.local.json" nick=""
    if [ -f "$f" ]; then
        if command -v jq >/dev/null 2>&1; then
            nick="$(jq -r '.self.nickname // empty' "$f" 2>/dev/null)"
        else
            # hub has no jq; the same python3 fallback lib/fleet.sh uses.
            nick="$(python3 -c 'import json,sys
print(json.load(open(sys.argv[1])).get("self",{}).get("nickname",""))' "$f" 2>/dev/null)"
        fi
        # A self-declaration with no nickname is malformed, not a licence to
        # fall through to a detection that is known wrong on this class of box.
        [ -n "$nick" ] && { echo "$nick"; return 0; }
        echo "backup-client: $f has no .self.nickname" >&2
        return 1
    fi
    # shellcheck source=provision/lib/fleet.sh
    source "$REPO/provision/lib/fleet.sh"
    fleet_detect
}

# backup_client_install <mode> <identity>
#   mode: dry-run | apply
backup_client_install() {
    local mode="$1" id="$2"
    local dir="$REPO/backup/$id"
    local script="$dir/install-tasks.sh"

    # A DECLARED-BUT-UNCONFIGURED CLIENT IS A SKIP, NOT A FAILURE -- it keeps an
    # unfinished thing visible without turning a provision run red.
    if [ ! -d "$dir" ]; then
        echo "  backup-client: no profile dir for $id (skipped)"
        echo "                 expected $dir"
        return 0
    fi
    # Dir but no script is the opposite: somebody added config and no way to
    # install it. The scope decision lives in that script (latitude's profiles
    # are schedule-permission: system and need sudo; a user-scope client must
    # NOT be root, or its units land in the system manager and the timer that
    # actually backs the box up is never installed), so there is nothing
    # sensible to guess here.
    if [ ! -f "$script" ]; then
        echo "  backup-client: $dir exists but has no install-tasks.sh" >&2
        return 1
    fi

    local missing=""
    command -v restic        >/dev/null 2>&1 || missing="restic"
    command -v resticprofile >/dev/null 2>&1 || missing="$missing resticprofile"

    if [ "$mode" != "apply" ]; then
        # DRY RUN WRITES NOTHING. `resticprofile schedule` creates systemd units
        # and has no dry-run of its own, so the only safe preview is to print.
        echo "  backup-client: identity $id, profile dir $dir"
        if [ -n "$missing" ]; then
            echo "  backup-client: would install$missing"
        else
            echo "  backup-client: restic + resticprofile present"
        fi
        echo "  backup-client: would run: bash $script"
        return 0
    fi

    if [ -n "$missing" ]; then
        if [ -r /etc/debian_version ]; then
            echo "  backup-client: installing$missing…"
            bash "$REPO/backup/restic-install.sh" || return 1
        else
            # restic-install.sh is apt + a curl'd installer into /usr/local/bin.
            # Neither is right elsewhere, and guessing is worse than stopping.
            echo "  backup-client: missing$missing — install them for this OS first" >&2
            return 1
        fi
    fi
    # Nudge, not a gate. It matters for a user-scope client (a WSL distro):
    # without linger its timer dies with the last login shell, which is the
    # difference between a backup and the appearance of one. latitude's units
    # are system-scope and need no linger at all.
    if command -v loginctl >/dev/null 2>&1 \
       && [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "no" ]; then
        echo "  backup-client: note — linger is off; a user-scope timer dies at"
        echo "                 logout. sudo loginctl enable-linger $USER"
    fi
    bash "$script"
}

backup_client_main() {
    local mode="apply" id=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) mode="dry-run"; shift ;;
            --apply)   mode="apply"; shift ;;
            -*) echo "backup-client: unknown option: $1" >&2; return 2 ;;
            *)  [ -n "$id" ] && { echo "backup-client: unexpected argument: $1" >&2; return 2; }
                id="$1"; shift ;;
        esac
    done
    if [ -z "$id" ]; then
        id="$(backup_client_identity)" || return 1
    fi
    if [ -z "$id" ]; then
        echo "backup-client: could not resolve this box's identity" >&2
        echo "  no fleet.local.json, and no fleet.json machine matches $(hostname)" >&2
        echo "  pass one explicitly: bash $0 <identity>" >&2
        return 1
    fi
    backup_client_install "$mode" "$id"
}

[ -n "${BACKUP_CLIENT_LIB_ONLY:-}" ] || backup_client_main "$@"
