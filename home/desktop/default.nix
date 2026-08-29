_:

{
  # Graphical session: niri (Wayland compositor), its bar/shell, the GUI
  # browsers and apps, GTK/cursor theming, and the SSH forwards that only make
  # sense from a machine with a browser on it. All of this assumes NixOS --
  # niri comes from a NixOS module, and helium.nix reads `osConfig` -- so it is
  # deliberately not importable from a standalone home-manager config.
  imports = [
    ./niri.nix
    ./noctalia.nix
    ./terminal.nix
    ./editors.nix
    ./apps.nix
    ./theme.nix
    ./tunnels.nix
    ./helium.nix
  ];
}
