{ pkgs, lib, ... }:

{
  home.username = "brian";
  home.homeDirectory = "/home/brian";
  home.stateVersion = "25.05";

  imports = [
    ./niri.nix
    ./noctalia.nix
    ./terminal.nix
    ./editor.nix
    ./dev.nix
    ./shell.nix
    ./tunnels.nix
    ./apps.nix
    ./theme.nix
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
  };

  programs.home-manager.enable = true;
}
