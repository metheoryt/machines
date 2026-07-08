# PyCharm bumped to the latest upstream release.
#
# nixpkgs' jetbrains.pycharm is itself a repackage of the official
# download.jetbrains.com tarball (same artifact we'd fetch by hand), so instead
# of rebuilding the derivation from scratch we just override `version` + `src`
# and inherit all of nixpkgs' wrapping (bundled JBR patching, fonts, fsnotifier,
# FHS plugin env, desktop entry). nixpkgs lags upstream by a patch release or
# two; this keeps us current the day JetBrains ships.
#
# To bump: run `just update-pycharm` (also triggered by `just update`/`just
# upgrade`), which rewrites `version` + `hash` below from the JetBrains release
# API. Manual: edit `version`, then `nix store prefetch-file <url>`.
{pkgs}:
pkgs.jetbrains.pycharm.overrideAttrs (_: rec {
  version = "2026.1.4";

  src = pkgs.fetchurl {
    url = "https://download.jetbrains.com/python/pycharm-${version}.tar.gz";
    hash = "sha256-RIufgZhg/n+D1uEdcDyYRjTDfh8Jicyz4h0B1kTbVXs=";
  };
})
