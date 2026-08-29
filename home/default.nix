{ ... }:

{
  home.username = "brian";
  home.homeDirectory = "/home/brian";
  home.stateVersion = "25.05";

  imports = [
    ./core
    ./desktop
    ./toolchains.nix
  ];

  programs.home-manager.enable = true;
}
