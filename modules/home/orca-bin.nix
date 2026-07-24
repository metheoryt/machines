# Orca — "the worktree IDE for AI coding agents" (Claude Code / Codex / OpenCode
# side by side with worktree isolation). Electron app, not in nixpkgs and
# distributed only as prebuilt binaries, so we wrap the upstream Linux AppImage
# with appimageTools (FHS env + Electron's bundled libs). Upstream ships the
# desktop file with `--no-sandbox` (the bundled chrome-sandbox isn't setuid
# root under the Nix FHS wrapper), so we keep that flag.
#
# wrapType2 exposes the app as bin/${pname} (i.e. `orca-ide`); the extracted
# tree gives us the desktop entry + hicolor icons to install.
#
# To bump: run `just update-orca` (also triggered by `just update`/`just
# upgrade`), which rewrites `version` + `hash` below from the latest release.
# Manual: edit `version`, then `nix store prefetch-file --json \
#   https://github.com/stablyai/orca/releases/download/v$version/orca-linux.AppImage`.
#
# GOTCHA — do NOT use Orca's in-app "install shell command" (its CliInstaller):
# on NixOS it writes ~/.local/bin/orca-ide → resources/bin/orca-ide (the AppImage's
# own launcher), which execs the UNwrapped Electron binary and dies with
# `libnspr4.so: cannot open shared object file` — it bypasses this appimageTools
# bwrap wrapper (the only thing that supplies nss/nspr/glib/cups). ~/.local/bin
# also precedes the Nix profile on PATH, so that stale symlink SHADOWS the working
# `orca-ide` here. The `home.activation.orcaCliShadowPrune` script in
# modules/home/me.nix removes that symlink on every switch; rely on this
# Nix-wrapped binary for both GUI and CLI.
{
  lib,
  appimageTools,
  fetchurl,
}: let
  pname = "orca-ide";
  version = "1.4.155";

  src = fetchurl {
    url = "https://github.com/stablyai/orca/releases/download/v${version}/orca-linux.AppImage";
    hash = "sha256-cBcChT9+fRdxQGn7g64gww7XjzzqUHZ0+hFte1wLXqE=";
  };

  appimageContents = appimageTools.extract {inherit pname version src;};
in
  appimageTools.wrapType2 {
    inherit pname version src;

    extraInstallCommands = ''
      # Desktop entry: point Exec at the wrapped binary instead of AppRun,
      # keeping the upstream `--no-sandbox %U` tail intact.
      install -Dm444 ${appimageContents}/${pname}.desktop \
        -t $out/share/applications
      substituteInPlace $out/share/applications/${pname}.desktop \
        --replace-fail 'Exec=AppRun' 'Exec=${pname}'

      # Bundled hicolor icons (16px .. 1024px), referenced as Icon=orca-ide.
      cp -r ${appimageContents}/usr/share/icons $out/share/
    '';

    meta = {
      description = "Worktree IDE for AI coding agents (Claude Code, Codex, OpenCode side by side)";
      homepage = "https://www.onorca.dev";
      license = lib.licenses.unfree;
      platforms = ["x86_64-linux"];
      mainProgram = "orca-ide";
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
