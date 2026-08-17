{ pkgs, ... }:

{
  home.packages = with pkgs; [
    rustup
    nodejs_22
    lazygit
    gcc
    git
    claude-code
  ];

  # Per-project toolchain pinning (the NixOS-native analog to mise/proto/volta):
  # a project's own flake.nix/shell.nix + direnv gives fully reproducible,
  # per-directory tool versions via the Nix store. `devenv` (cachix/devenv) is a
  # popular friendlier layer on top of this if you want more mise-like ergonomics
  # later -- not installed here, easy to add.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
}
