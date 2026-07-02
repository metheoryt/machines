# Zed repackaged from the upstream Linux tarball.
#
# nixpkgs lags upstream (zed-editor 1.3.6), so unpack the official
# zed-linux-x86_64.tar.gz (https://zed.dev/docs/linux) and patchelf it against
# nixpkgs libraries. The tarball bundles most of its own libs under zed.app/lib;
# autoPatchelfHook discovers those and only pulls the rest (libstdc++, alsa,
# zlib) from buildInputs. Vulkan/Wayland/GL are dlopen'd at runtime, so they're
# appended to every RUNPATH via appendRunpaths (mirrors nixpkgs' --add-rpath).
#
# Drop-in for pkgs.zed-editor: exposes bin/zeditor (real CLI) + bin/zed alias.
# Auto-update is compiled into the upstream binary; disable it at runtime with
# `auto_update = false;` in programs.zed-editor.userSettings.
#
# To bump: run `just update-zed` (also triggered by `just update`/`just
# upgrade`), which rewrites `version` + `hash` below from the latest stable
# release. Manual: edit `version`, then `nix store prefetch-file <url>`.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  alsa-lib,
  zlib,
  libGL,
  vulkan-loader,
  wayland,
  xkeyboard-config,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "zed-bin";
  version = "1.9.0";

  src = fetchurl {
    url = "https://github.com/zed-industries/zed/releases/download/v${finalAttrs.version}/zed-linux-x86_64.tar.gz";
    hash = "sha256-OeVTzjoA/ut46rY6XLcjfLRg88lZaxsZBSzre56OxN0=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
    stdenv.cc.cc.lib # libstdc++ / libgcc_s for the bundled libs
  ];

  buildInputs = [
    stdenv.cc.cc.lib
    alsa-lib
    zlib
  ];

  # dlopen'd at runtime (not in NEEDED) — append to every patched ELF's RUNPATH.
  appendRunpaths = [
    "${libGL}/lib"
    "${vulkan-loader}/lib"
    "${wayland}/lib"
  ];

  # The tarball extracts to zed.app/{bin,libexec,lib,share}; unpackPhase cd's
  # into that dir, so the source root already holds bin/ libexec/ lib/ share/.
  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r ./* $out/

    # Match nixpkgs: real CLI is `zeditor`, keep `zed` as an alias (the desktop
    # file and muscle memory both use `zed`). Wrap it to point libxkbcommon at
    # nixpkgs' xkeyboard-config: the bundled libxkbcommon.so.0 has the upstream
    # default `/usr/share/X11/xkb` baked in, which is absent on NixOS, so keymap
    # init segfaults the editor on launch. The CLI spawns libexec/zed-editor,
    # which inherits this env. (Mirrors how nixpkgs' zed-editor is wrapped.)
    mv $out/bin/zed $out/bin/.zeditor-unwrapped
    makeWrapper $out/bin/.zeditor-unwrapped $out/bin/zeditor \
      --set-default XKB_CONFIG_ROOT ${xkeyboard-config}/share/X11/xkb
    ln -s zeditor $out/bin/zed

    runHook postInstall
  '';

  meta = {
    description = "High-performance, multiplayer code editor (upstream prebuilt binary)";
    homepage = "https://zed.dev";
    license = lib.licenses.gpl3Only;
    platforms = ["x86_64-linux"];
    mainProgram = "zeditor";
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
  };
})
