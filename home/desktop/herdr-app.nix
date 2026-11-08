# Herdr (https://herdr.dev/download/), a desktop front-end for coding-agent
# terminals, and herdr-core (`hc`), the server it talks to. Not the same
# program as the `herdr` TUI in ../core/cli.nix.
#
# Both come from herdr's prebuilt release tarballs instead of its `curl | sh`
# installer. The installer would put them in ~/.local, where they update
# themselves. From the store, neither does:
#
# - The app only updates itself when `herdr-app.svg` sits next to its binary,
#   so the icon goes under share/ instead.
# - herdr-core sees it lives under /nix/store and reports itself as managed by
#   nix. The app then leaves it alone too.
#
# To update, bump `version` and `hash` from the manifests at
# https://releases.herdr.dev/{app,core}/latest.json. The sha256 there is hex:
# `nix hash convert --hash-algo sha256 --to sri <hex>` turns it into a hash.
# The app manifest names the oldest core it supports (`core_min`).
{ pkgs, lib, ... }:

let
  # Fully static, like the `herdr` release binary, so there's nothing to patch.
  herdr-core =
    let
      version = "0.1.19";
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "herdr-core";
      inherit version;
      src = pkgs.fetchurl {
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
    };

  herdr-app =
    let
      version = "0.1.14";
    in
    pkgs.stdenv.mkDerivation {
      pname = "herdr-app";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://releases.herdr.dev/app/${version}/herdr-app-linux-x86_64.tar.gz";
        hash = "sha256-R1o4P49DnjGRqGY1tcEobOTf0tn83x58vf3Wxxdvj/M=";
      };

      nativeBuildInputs = [
        pkgs.autoPatchelfHook
        pkgs.makeWrapper
      ];
      buildInputs = [
        pkgs.stdenv.cc.cc.lib
        pkgs.libxcb
        pkgs.libxkbcommon
      ];
      # dlopen()ed at runtime, so autoPatchelf can't see them in the ELF
      # headers. The Vulkan driver itself comes from hardware.graphics.
      runtimeDependencies = [
        pkgs.vulkan-loader
        pkgs.wayland
        pkgs.libGL
      ];

      installPhase = ''
        runHook preInstall
        install -Dm755 herdr-app $out/libexec/herdr-app
        install -Dm644 herdr-app.svg $out/share/icons/hicolor/scalable/apps/herdr-app.svg
        # The app looks for the core on PATH, so this pins it to the one
        # packaged above.
        makeWrapper $out/libexec/herdr-app $out/bin/herdr-app \
          --prefix PATH : ${herdr-core}/bin
        runHook postInstall
      '';

      meta = {
        description = "Desktop app for terminals and coding agents that keep running";
        homepage = "https://herdr.dev";
        license = lib.licenses.asl20;
        platforms = [ "x86_64-linux" ];
        mainProgram = "herdr-app";
      };
    };
in
{
  # herdr-core is on PATH too, for `hc` from a terminal.
  home.packages = [
    herdr-app
    herdr-core
  ];

  # The same entry the installer writes. StartupWMClass lets niri and the bar
  # match the app's windows to this entry.
  xdg.desktopEntries.herdr-app = {
    name = "Herdr";
    comment = "Terminals and coding agents that keep running";
    exec = "herdr-app";
    icon = "herdr-app";
    terminal = false;
    categories = [ "Development" ];
    settings.StartupWMClass = "herdr-app";
  };
}
