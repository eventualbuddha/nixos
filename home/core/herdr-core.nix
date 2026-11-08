{ pkgs, ... }:

{
  # On every host, not just the graphical ones: the Herdr app in
  # ../desktop/herdr-app.nix runs a machine's terminals through that machine's
  # own core, so an SSH machine it connects to (like the vx VM) needs one too.
  # Also gives `hc` in a terminal.
  home.packages = [ (pkgs.callPackage ./herdr-core-package.nix { }) ];
}
