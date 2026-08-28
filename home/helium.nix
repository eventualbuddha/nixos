# Helium (Chromium-based) browser, packaged directly from imputnet's own
# AppImage release rather than a third-party Nix flake -- we trust upstream's
# binary and use nixpkgs' own appimageTools to unpack/patch it, so there's no
# extra packaging maintainer in the trust chain. Bump `version`/`hash` by hand
# when you want to update (see https://github.com/imputnet/helium-linux/releases).
#
# Chosen over Firefox as the default browser specifically because Chromium's
# multi-profile model (`--profile-directory=NAME`, routed correctly to the
# right profile's window by the existing process singleton) is mature and
# scriptable. Firefox's newer "Selectable Profiles" feature shares one
# remoting endpoint across all profiles and just dumps external links into
# whichever window was most recently focused, with no way to target a
# specific profile -- which is exactly the bug this file works around.
{
  pkgs,
  config,
  lib,
  osConfig,
  ...
}:

let
  # Helium itself, and its default-browser association, are for every host.
  # The browser-picker Noctalia plugin below (multiple profiles to route
  # between) is judy-only -- other hosts only have one Helium profile, so
  # there's nothing to pick.
  isJudy = osConfig.networking.hostName == "judy";
  defaultBrowserDesktop = if isJudy then "browser-open.desktop" else "helium.desktop";

  version = "0.15.7.1";

  # The AppImage's own binary is called `helium`; appimageTools names the
  # wrapped executable after `pname`, so `helium/bin/helium` Just Works.
  helium = pkgs.appimageTools.wrapType2 {
    pname = "helium";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://github.com/imputnet/helium-linux/releases/download/${version}/helium-${version}-x86_64.AppImage";
      sha256 = "1psgyij2jdqcjvbxfca1w6nkp0wjxdqny635ya29b2a8z0cq8cgv";
    };
    extraPkgs = pkgs: with pkgs; [
      alsa-lib
      at-spi2-atk
      at-spi2-core
      atk
      cairo
      cups
      dbus
      expat
      gdk-pixbuf
      glib
      gtk3
      libdrm
      libGL
      libnotify
      libpulseaudio
      libxkbcommon
      mesa
      nspr
      nss
      pango
      pipewire
      systemd
      wayland
      libx11
      libxcomposite
      libxdamage
      libxext
      libxfixes
      libxrandr
      libxcb
      libxshmfence
    ];
  };

in
{
  home.packages = [
    helium
  ];

  # Lets you launch plain Helium (skipping the picker) from an app launcher.
  xdg.desktopEntries.helium = {
    name = "Helium";
    comment = "Private, fast, and honest browser";
    exec = "${helium}/bin/helium %U";
    terminal = false;
    type = "Application";
    categories = [
      "Network"
      "WebBrowser"
    ];
    mimeType = [
      "text/html"
      "text/xml"
      "application/xhtml+xml"
    ];
  };

  # The browser-picker Noctalia plugin (./noctalia-plugins/browser-picker):
  # a panel with one button per Helium profile, so external links land in
  # the right one. Symlinked whole into noctalia's local plugin source dir;
  # `noctalia msg plugins enable brian/browser-picker` (already done on this
  # machine) is separate runtime state, not managed here. Editing panel.luau
  # after this is nix-managed needs `./apply.sh` to take effect -- it's no
  # longer hot-reloaded from a loose directory.
  xdg.dataFile = lib.optionalAttrs isJudy {
    "noctalia/plugins/browser-picker".source = ./noctalia-plugins/browser-picker;
  };

  # Default browser handler on judy: routes every link through the
  # browser-picker panel above so you pick which Helium profile it opens in.
  # The panel id is "<plugin id>:<panel entry id>" -- see niri.nix's Mod+B
  # bind for the same id used as a manual trigger.
  xdg.desktopEntries.browser-open = lib.mkIf isJudy {
    name = "Helium (choose profile)";
    comment = "Pick which Helium profile opens a link";
    exec = "${config.programs.noctalia.package}/bin/noctalia msg panel-open brian/browser-picker:browser-picker %u";
    terminal = false;
    type = "Application";
    mimeType = [
      "text/html"
      "x-scheme-handler/http"
      "x-scheme-handler/https"
    ];
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = defaultBrowserDesktop;
      "x-scheme-handler/http" = defaultBrowserDesktop;
      "x-scheme-handler/https" = defaultBrowserDesktop;
      "x-scheme-handler/about" = defaultBrowserDesktop;
      "x-scheme-handler/unknown" = defaultBrowserDesktop;
    };
  };
}
