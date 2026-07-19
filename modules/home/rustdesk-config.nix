# Declarative seed for RustDesk's self-hosted server + known peers.
#
# RustDesk rewrites its config files (~/.config/rustdesk/*.toml) at runtime —
# window geometry, last-connect, direct_failures, etc. — so we can't manage them
# as read-only Home-Manager symlinks (RustDesk would fail to write). Instead this
# is a SEED-ONLY activation script: it drops each file only when it's absent
# (fresh machine / wiped config) and never touches one RustDesk already owns.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Self-hosted rendezvous/relay server — identical on every machine.
  # `key` is the server's PUBLIC key, so it's safe to commit.
  server = {
    custom-rendezvous-server = "cyphy.kz";
    relay-server = "cyphy.kz";
    key = "MUJKMH88yTSlixlnLpYxBtNgD8ixlyIt6Vdy6MferKs=";
  };

  # Known peers to pre-populate the recent-connections list. Keyed by the peer
  # file's basename: a RustDesk ID (works anywhere via the server) or a LAN IP
  # (only resolves on that network). Identity only — NO passwords: those are
  # per-install-encrypted secrets we must not commit, so RustDesk prompts for the
  # password on first connect. Add an `alias` once RustDesk supports it in-file,
  # or just rename in the UI afterwards. Prune the LAN-IP duplicates if unwanted.
  peers = {
    "399975738" = {
      hostname = "me-g614jv";
      username = "methe";
      platform = "Windows";
    };
    "482036139" = {
      hostname = "g513ie";
      username = "methe";
      platform = "Windows";
    };
    "173199886" = {
      hostname = "win-kiokq9idol4";
      username = "";
      platform = "Windows";
    };
    "192.168.8.145" = {
      hostname = "me-g614jv";
      username = "methe";
      platform = "Windows";
    };
    "192.168.8.170" = {
      hostname = "g513ie";
      username = "methe";
      platform = "Windows";
    };
  };

  serverFile = pkgs.writeText "RustDesk2.toml" ''
    [options]
    custom-rendezvous-server = '${server.custom-rendezvous-server}'
    relay-server = '${server.relay-server}'
    key = '${server.key}'
  '';

  mkPeerFile = id: p:
    pkgs.writeText "rustdesk-peer-${id}.toml" ''
      [info]
      username = '${p.username}'
      hostname = '${p.hostname}'
      platform = '${p.platform}'
    '';

  # Store files are 0444; `cp` copies that mode, which would leave RustDesk unable
  # to rewrite the file — so every seeded file is chmod'd back to 0600 (RustDesk's
  # own mode).
  peerSeeds = lib.concatStringsSep "\n" (lib.mapAttrsToList (id: p: ''
      if [ ! -e "$peersDir/${id}.toml" ]; then
        run cp ${mkPeerFile id p} "$peersDir/${id}.toml"
        run chmod 600 "$peersDir/${id}.toml"
      fi
    '')
    peers);
in {
  home.activation.rustdeskSeed = lib.hm.dag.entryAfter ["writeBoundary"] ''
    cfgDir="${config.xdg.configHome}/rustdesk"
    peersDir="$cfgDir/peers"
    run mkdir -p "$peersDir"

    if [ ! -e "$cfgDir/RustDesk2.toml" ]; then
      run cp ${serverFile} "$cfgDir/RustDesk2.toml"
      run chmod 600 "$cfgDir/RustDesk2.toml"
    fi

    ${peerSeeds}
  '';
}
