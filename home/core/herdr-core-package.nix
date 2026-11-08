# herdr-core (`hc`), the server that runs the Herdr app's terminals, locally
# or on an SSH machine the app connects to. Built from herdr's prebuilt
# release tarball instead of its `curl | sh` installer. The binary is fully
# static, like the `herdr` TUI's, so there's nothing to patch.
#
# From the store it doesn't update itself: it sees it lives under /nix/store
# and reports itself as managed by nix, and the app then leaves it alone too.
# To update, bump `version` and `hash` from
# https://releases.herdr.dev/core/latest.json. The sha256 there is hex:
# `nix hash convert --hash-algo sha256 --to sri <hex>` turns it into a hash.
#
# A package rather than a module, so ./herdr-core.nix and
# ../desktop/herdr-app.nix both get the same build from it.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

stdenvNoCC.mkDerivation rec {
  pname = "herdr-core";
  version = "0.1.19";
  src = fetchurl {
    url = "https://releases.herdr.dev/core/${version}/herdr-core-linux-x86_64.tar.gz";
    hash = "sha256-Stz7Qj1S8kxcxKHizS/K0fYtKLt3h2rEcsKQgqPqpCQ=";
  };
  sourceRoot = ".";
  installPhase = ''
    runHook preInstall
    install -Dm755 herdr-core $out/bin/herdr-core
    ln -s herdr-core $out/bin/hc
    runHook postInstall
  '';
  meta = {
    description = "Terminals for coding agents that keep running";
    homepage = "https://herdr.dev";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "herdr-core";
  };
}
