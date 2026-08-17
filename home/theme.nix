{ pkgs, lib, config, ... }:

let
  cursorPkg = pkgs.catppuccin-cursors.mochaDark;
  cursorName = "catppuccin-mocha-dark-cursors";
in
{
  gtk = {
    enable = true;
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    gtk4.theme = config.gtk.theme;
  };

  home.pointerCursor = {
    enable = true;
    package = cursorPkg;
    name = cursorName;
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  dconf.settings."org/gnome/desktop/interface" = {
    color-scheme = "prefer-dark";
  };
}
