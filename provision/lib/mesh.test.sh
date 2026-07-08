#!/usr/bin/env bash
# provision/lib/mesh.test.sh — unit test for mesh.sh with a stubbed ssh + temp manifest.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Temp manifest: a hub + one member, matching the real field shape.
cat > "$tmp/fleet.json" <<'JSON'
{
  "machines": {
    "testbox": { "platform": "nixos", "mesh": { "ip": "10.0.0.9", "role": "member", "peerName": "nix-test" } },
    "vps": { "platform": "debian", "mesh": { "ip": "10.0.0.1", "role": "hub", "managePeers": "/srv/vps/manage-peers.sh" }, "ssh": { "user": "debian", "host": "cyphy.kz" } }
  }
}
JSON

# Stub ssh: `show` fails (peer not found), `add` returns a fake conf. Records args.
cat > "$tmp/ssh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SSH_CALLS"
case "$*" in
    *"show "*) exit 1 ;;                                   # not found -> triggers add
    *"add "*)  printf '[Interface]\nPrivateKey = SECRETKEY123\nAddress = 10.0.0.9/32\n[Peer]\n'; exit 0 ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$tmp/ssh"

export MESH_MANIFEST="$tmp/fleet.json"
export MESH_SSH="$tmp/ssh"
export SSH_CALLS="$tmp/calls"
: > "$SSH_CALLS"
# shellcheck source=/dev/null
source "$here/mesh.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1) hub target + script + peer resolution
[ "$(mesh_hub_target)" = "debian@cyphy.kz" ] || fail "hub target"
[ "$(mesh_hub_script)" = "/srv/vps/manage-peers.sh" ] || fail "hub script"
[ "$(mesh_peer_name testbox)" = "nix-test" ] || fail "peer name"
[ "$(mesh_peer_ip testbox)" = "10.0.0.9" ] || fail "peer ip"

# 2) fetch: show-then-add order; returns the conf; tried show BEFORE add
conf="$(mesh_ssh_fetch testbox)" || fail "fetch rc"
printf '%s' "$conf" | grep -q '^\[Interface\]' || fail "fetch conf"
grep -q "show 'nix-test' --conf-only" "$SSH_CALLS" || fail "show attempted"
grep -q "add 'nix-test' '10.0.0.9' --conf-only" "$SSH_CALLS" || fail "add attempted"
# show must precede add
show_ln="$(grep -n 'show ' "$SSH_CALLS" | head -1 | cut -d: -f1)"
add_ln="$(grep -n 'add ' "$SSH_CALLS" | head -1 | cut -d: -f1)"
[ "$show_ln" -lt "$add_ln" ] || fail "show before add"

# 3) dry-run line is key-free and names the install path
dry="$(mesh_dryrun_line testbox /etc/amnezia-wg/awg0.key)"
echo "$dry" | grep -q "would ssh debian@cyphy.kz" || fail "dryrun target"
echo "$dry" | grep -q "/etc/amnezia-wg/awg0.key" || fail "dryrun path"
echo "$dry" | grep -qi "SECRETKEY" && fail "dryrun leaked key"

# 4) successful show suppresses add entirely (no-rotation invariant)
cat > "$tmp/ssh2" <<'STUB2'
#!/usr/bin/env bash
echo "$*" >> "$SSH_CALLS2"
case "$*" in
    *"show "*) printf '[Interface]\nPrivateKey = STOREDKEY\nAddress = 10.0.0.9/32\n[Peer]\n'; exit 0 ;;
    *"add "*)  printf '[Interface]\nPrivateKey = NEWKEY\nAddress = 10.0.0.9/32\n[Peer]\n'; exit 0 ;;
    *) exit 2 ;;
esac
STUB2
chmod +x "$tmp/ssh2"

export SSH_CALLS2="$tmp/calls2"
: > "$SSH_CALLS2"

conf2="$(MESH_SSH="$tmp/ssh2" mesh_ssh_fetch testbox)" || fail "fetch rc (success-show)"
printf '%s' "$conf2" | grep -q "STOREDKEY" || fail "stored key not reused"
grep -q "show 'nix-test' --conf-only" "$SSH_CALLS2" || fail "show attempted (success-show)"
grep -q "add " "$SSH_CALLS2" && fail "add ran despite successful show (rotation!)"

echo "ALL TESTS PASS"
