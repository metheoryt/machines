{
  lib,
  buildNpmPackage,
  fetchurl,
  nodejs_22,
}:
# openclaude — a multi-provider fork of Claude Code (OpenAI/Gemini/Ollama/...).
# Distributed only on npm; the published tarball ships a prebuilt, bundled
# dist/cli.mjs but still resolves ~60 runtime deps from node_modules.
#
# Upstream has NO committed lockfile and builds with `bun`, so we vendor a
# generated, production-only ./package-lock.json and skip the build.
#
# To update:
#   v=0.20.1   # new version
#   url=https://registry.npmjs.org/@gitlawb/openclaude/-/openclaude-$v.tgz
#   curl -fsSLO "$url" && tar -xzf openclaude-$v.tgz
#   ( cd package && npm install --package-lock-only --omit=dev --ignore-scripts )
#   cp package/package-lock.json ./package-lock.json
#   nix-prefetch-url "$url" | xargs nix hash convert --hash-algo sha256 --to sri   # -> hash
#   nix run nixpkgs#prefetch-npm-deps -- package/package-lock.json               # -> npmDepsHash
buildNpmPackage (finalAttrs: {
  pname = "openclaude";
  version = "0.20.1";

  src = fetchurl {
    url = "https://registry.npmjs.org/@gitlawb/openclaude/-/openclaude-${finalAttrs.version}.tgz";
    hash = "sha256-6iDucFQKhdEKmuAbRSFjGX8KtGDRSQDao9QeVsEcZLg=";
  };
  # npm tarballs unpack into ./package
  sourceRoot = "package";

  nodejs = nodejs_22;

  npmDepsHash = "sha256-1RZfWI02Qg4KZgIw/YQZgkWLeFL4Jld62HN3Ius3ACI=";

  # Inject our vendored lockfile (none upstream).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  # Upstream overrides node-domexception with a local file: shim
  # (vendor/node-domexception-shim) that just re-exports native DOMException.
  # `npm ci` materializes this override as a dangling symlink; replace it with
  # the real shim that ships in the package so noBrokenSymlinks passes.
  postInstall = ''
    oc=$out/lib/node_modules/@gitlawb/openclaude
    rm -f $oc/node_modules/node-domexception
    cp -r $oc/vendor/node-domexception-shim $oc/node_modules/node-domexception
  '';

  # dist/ is prebuilt; the `build`/`prepack` scripts need bun. Skip both the
  # build and all lifecycle scripts, and install production deps only.
  dontNpmBuild = true;
  npmFlags = [
    "--omit=dev"
    "--ignore-scripts"
  ];

  meta = {
    description = "Open-source coding-agent CLI (Claude Code fork) for cloud and local model providers";
    homepage = "https://github.com/Gitlawb/openclaude";
    license = lib.licenses.mit;
    platforms = nodejs_22.meta.platforms;
    mainProgram = "openclaude";
  };
})
