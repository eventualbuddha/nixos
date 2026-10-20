# T3 Code (https://t3.codes), a desktop front-end for coding agents. It drives
# the `claude` and `codex` installs from ../core, locally or on a VM over SSH.
#
# It gets the same treatment as claude and codex: nix sets it up once, then
# leaves it alone. The app updates itself with electron-updater, which on Linux
# replaces the AppImage file at $APPIMAGE. A store path cannot be replaced, so
# wrapping it with appimageTools (as ./helium.nix does) would freeze it at
# whatever version the flake pins. Instead the AppImage lives at a fixed
# mutable path in $HOME, and the pinned release below is only where a fresh
# machine starts from.
#
# The filename deliberately has no version in it. electron-updater overwrites
# a file whose name has no version string in place. A versioned name makes it
# write the new file under a new name instead, which would leave the launcher
# below pointing at a file that no longer exists.
#
# Running it relies on hosts/common.nix: programs.appimage.binfmt is what lets
# the path below be exec'd directly (by the launcher, by the updater's
# relaunch, and by the t3code:// URL-handler entry the app writes for itself),
# and its appimage-run is the one that can see /etc/ssh, so SSH environments
# can use aliases like `vx`.
{
  pkgs,
  lib,
  config,
  ...
}:

let
  # Bootstrap only -- see the header. Bumping it changes nothing on a machine
  # that already has the AppImage.
  version = "0.1.0";
  src = pkgs.fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/v${version}/T3-Code-${version}-x86_64.AppImage";
    hash = "sha256-442cX7UTsezgpwi5BtM4O1tH7RmVdbOaMeQauINOt0Q=";
  };

  appImage = "${config.xdg.dataHome}/t3code/T3-Code.AppImage";

  # The launcher's icon, copied out of the bootstrap release, so the extraction
  # (about half a gigabyte) is a build-time input only and garbage collection
  # can drop it. The AppImage itself stays in the closure either way, because
  # the bootstrap below copies it from the store.
  icon = pkgs.runCommand "t3code-icon.png" { } ''
    cp ${
      pkgs.appimageTools.extract {
        pname = "t3code";
        inherit version src;
      }
    }/usr/share/icons/hicolor/512x512/apps/t3code.png $out
  '';
in
{
  # Copied out of the store rather than downloaded here, so the bootstrap does
  # no network I/O and is checked against the pinned hash. Guarded on the file
  # already existing, which is the steady state: from then on the app owns it.
  # `install` rather than `cp` because a store path is read-only, and
  # electron-updater needs to be able to replace the file.
  home.activation.bootstrapT3Code = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -e "${appImage}" ]; then
      run ${pkgs.coreutils}/bin/install -D -m 755 ${src} "${appImage}"
    fi
  '';

  # Every update leaves its predecessor's extraction behind. appimage-run
  # unpacks into ~/.cache/appimage-run/<sha256 of the AppImage>, never reuses
  # or removes old ones, and each is about half a gigabyte. On each switch,
  # remove T3 extractions other than the current file's. One is recognized as
  # T3's by the t3code.desktop file at its top level, so other AppImages'
  # extractions are left alone.
  #
  # This cannot remove a running instance's directory: electron-updater
  # replaces the file only when the app quits.
  home.activation.pruneT3CodeExtractions = lib.hm.dag.entryAfter [ "bootstrapT3Code" ] ''
    cache="${config.xdg.cacheHome}/appimage-run"
    if [ -e "${appImage}" ] && [ -d "$cache" ]; then
      current="$(${pkgs.coreutils}/bin/sha256sum "${appImage}" | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
      for dir in "$cache"/*/; do
        dir="''${dir%/}"
        if [ -e "$dir/t3code.desktop" ] && [ "''${dir##*/}" != "$current" ]; then
          run ${pkgs.coreutils}/bin/rm -rf "$dir"
        fi
      done
    fi
  '';

  # The launcher. StartupWMClass matches the app's own .desktop file, so niri
  # and the bar attribute its windows to this entry. The app also writes a
  # hidden com.t3tools.T3Code.desktop for its t3code:// URL handler. That one
  # is the app's, and it points at the same path.
  xdg.desktopEntries.t3code = {
    name = "T3 Code";
    comment = "Desktop app for coding agents";
    exec = "${appImage} %U";
    icon = "${icon}";
    terminal = false;
    categories = [ "Development" ];
    settings.StartupWMClass = "t3code";
  };
}
