{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:
# gortex — code-intelligence engine / MCP server (Go static-ish binary).
# Not in nixpkgs; we fetch the upstream release tarball and patchelf it so it
# runs against the Nix store instead of relying on nix-ld.
#
# To update: bump `version`, then update both hashes. The tarball hash comes
# from upstream `checksums.txt`:
#   v=v0.56.0
#   curl -fsSL https://github.com/zzet/gortex/releases/download/$v/checksums.txt \
#     | grep gortex_linux_amd64.tar.gz
#   nix hash convert --hash-algo sha256 --to sri <hex>
stdenv.mkDerivation (finalAttrs: {
  pname = "gortex";
  version = "0.60.0";

  src = fetchurl {
    url = "https://github.com/zzet/gortex/releases/download/v${finalAttrs.version}/gortex_linux_amd64.tar.gz";
    hash = "sha256-MbRFBuSO6UINeF1M7zjwz5QMebjn89WyJ6eAjp832cM=";
  };

  sourceRoot = ".";

  nativeBuildInputs = [autoPatchelfHook];
  buildInputs = [stdenv.cc.cc.lib]; # libstdc++ / libgcc_s

  installPhase = ''
    runHook preInstall
    install -Dm755 gortex $out/bin/gortex
    runHook postInstall
  '';

  meta = {
    description = "High-performance code-intelligence engine for AI agents and IDEs";
    homepage = "https://github.com/zzet/gortex";
    license = lib.licenses.asl20;
    platforms = ["x86_64-linux"];
    mainProgram = "gortex";
  };
})
