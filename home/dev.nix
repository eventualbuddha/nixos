{ pkgs, config, ... }:

{
  home.packages = with pkgs; [
    rustup
    nodejs_22
    lazygit
    gcc
    git
    claude-code
    uv # python project/venv/interpreter management (pip/poetry/pyenv replacement)
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

  # `npm install -g` can't write into the Nix store (where nodejs_22 lives), so
  # point npm's global prefix at a writable directory in $HOME instead -- this
  # makes `npm install -g <pkg>` work exactly like it would anywhere else.
  home.sessionVariables.NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/.npm-global";
  home.sessionPath = [ "${config.home.homeDirectory}/.npm-global/bin" ];
}
