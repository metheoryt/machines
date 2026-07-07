# RustDesk repackaged from the upstream Flutter .deb.
#
# nixpkgs only ships rustdesk-flutter 1.4.5 (and the Sciter rustdesk 1.4.6),
# both lagging upstream. This unpacks the official 1.4.7 amd64 .deb and
# patchelfs it against nixpkgs libraries so we get the exact upstream binary
# without a long Rust/Flutter source build.
#
# To bump: run `just update-rustdesk` (also triggered by `just update` /
# `just upgrade`), which rewrites `version` + `hash` below from the latest
# upstream release. Manual path: edit `version`, then `nix store prefetch-file
# <url>` and paste the resulting sha256-… into `hash`.
{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  # runtime libs
  gtk3,
  glib,
  pango,
  cairo,
  gdk-pixbuf,
  atk,
  libxkbcommon,
  alsa-lib,
  libpulseaudio,
  pipewire,
  gst_all_1,
  libva,
  libvdpau,
  libvpx,
  libyuv,
  libaom,
  libopus,
  openssl,
  pam,
  libayatana-appindicator,
  xdotool,
  zlib,
  libGL,
  libxcb,
  libxrandr,
  libx11,
  libxi,
  libxfixes,
  libxtst,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "rustdesk-bin";
  version = "1.4.9";

  src = fetchurl {
    url = "https://github.com/rustdesk/rustdesk/releases/download/${finalAttrs.version}/rustdesk-${finalAttrs.version}-x86_64.deb";
    hash = "sha256-ckS6R8QOgEFyBEv75llGfFTORlVMmOeMjAQG8dYS/aM=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    gtk3
    glib
    pango
    cairo
    gdk-pixbuf
    atk
    libxkbcommon
    alsa-lib
    libpulseaudio
    pipewire
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    libva
    libvdpau
    libvpx
    libyuv
    libaom
    libopus
    openssl
    pam
    libayatana-appindicator
    xdotool
    zlib
    libGL
    stdenv.cc.cc.lib
    libx11
    libxi
    libxfixes
    libxtst
    libxrandr
    libxcb
  ];

  # GApps wrapper handles the env; don't double-wrap.
  dontWrapGApps = true;

  # The .deb ships the real ELF at usr/share/rustdesk/rustdesk and relies on a
  # postinst symlink for /usr/bin/rustdesk (which isn't in the data archive).
  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r usr/* $out/

    runHook postInstall
  '';

  # Point bin/rustdesk at the real binary and pin it to X11/XWayland so keyboard
  # input works. RustDesk is a Flutter (GTK) app, and keyboard forwarding breaks
  # on native Wayland. GDK_BACKEND=x11 is the authoritative lever for GTK;
  # blanking WAYLAND_DISPLAY alone is not enough once the session exports
  # XDG_SESSION_TYPE=wayland / QT_QPA_PLATFORM=wayland (see modules/desktop/gnome.nix).
  # QT_QPA_PLATFORM=xcb covers any Qt subcomponents. Then apply the GApps env fixes.
  #
  # libva is in buildInputs, but RustDesk's bundled ffmpeg dlopen()s "libva.so.2"
  # by soname at runtime — autopatchelf can't see that, so it never lands in the
  # binary's RUNPATH and VAAPI fails ("Failed to load libva … H265 decoder" falls
  # back to CPU, causing laggy playback even on a fast LAN). Put libva on
  # LD_LIBRARY_PATH so the dlopen resolves, and point libva at the host's VAAPI
  # driver dir (/run/opengl-driver/lib/dri holds iHD on Intel, nvidia on g16),
  # which NixOS populates from hardware.graphics.extraPackages.
  postFixup = ''
    makeWrapper $out/share/rustdesk/rustdesk $out/bin/rustdesk \
      --set GDK_BACKEND x11 \
      --set QT_QPA_PLATFORM xcb \
      --set WAYLAND_DISPLAY "" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ libva ]}" \
      --set-default LIBVA_DRIVERS_PATH "/run/opengl-driver/lib/dri" \
      "''${gappsWrapperArgs[@]}"
  '';

  meta = {
    description = "Open source virtual / remote desktop infrastructure (upstream Flutter build)";
    homepage = "https://rustdesk.com";
    license = lib.licenses.agpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "rustdesk";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
