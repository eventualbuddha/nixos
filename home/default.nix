{ ... }:

{
  home.username = "brian";
  home.homeDirectory = "/home/brian";
  home.stateVersion = "25.05";

  imports = [
    ./core
    ./desktop
    ./toolchains.nix
    # libvirt env, NixOS-only: the Debian VM in hosts/vxdev imports home/core
    # directly and has no libvirtd on it.
    ./libvirt.nix
  ];

  programs.home-manager.enable = true;
}
