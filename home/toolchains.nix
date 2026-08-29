{
  pkgs,
  lib,
  config,
  ...
}:

{
  # Language toolchains and containers, deliberately NOT in home/core.
  #
  # A toolchain on the profile PATH is a global default, and a global default
  # is exactly what per-project pinning is trying to get rid of: on the vxsuite
  # build VM a profile-level `nodejs_22` would sit in front of the 24.19.0 that
  # repo pins, which is the same class of bug as the proto/vite-plus shims that
  # already shadowed it there. Machines that want a convenient ambient
  # toolchain (judy, work) import this; machines that get their toolchains from
  # a project devShell + direnv (see home/core/cli.nix) do not.
  home = {
    packages = with pkgs; [
      rustup
      # nixpkgs' `rustup` bundles its own bin/rust-analyzer proxy (like
      # cargo/rustc/etc, it just re-execs into `rustup`, which then errors
      # with "could not choose a version" since no default toolchain is
      # set). hiPrio makes the real rust-analyzer package win that filename
      # collision in the merged profile instead.
      (lib.hiPrio rust-analyzer)
      nodejs_22
      gcc
      git
      podman
    ];

    # `npm install -g` can't write into the Nix store (where nodejs_22 lives), so
    # point npm's global prefix at a writable directory in $HOME instead -- this
    # makes `npm install -g <pkg>` work exactly like it would anywhere else.
    sessionVariables.NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/.npm-global";
    sessionPath = [ "${config.home.homeDirectory}/.npm-global/bin" ];
  };

  xdg.configFile."containers/registries.conf".text = ''
    [registries.search]
    registries = ['docker.io', 'quay.io']
  '';
}
