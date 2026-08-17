{ pkgs, config, ... }:

let
  # herdr isn't in nixpkgs. Building it from source isn't practical: it
  # vendors Ghostty's libghostty-vt (a Zig library) and pulls in Ghostty's
  # own Zig dependency-fetching machinery to build it -- nixpkgs' own
  # `ghostty` package already solves that problem, but it's substantial
  # machinery not worth re-deriving just for this. Its GitHub release
  # binaries are fully static (`file` reports "static-pie linked", no
  # `.interp` section) though, so no autoPatchelfHook/dynamic-linking dance
  # is needed -- just fetch and drop it in $out/bin. Bump `version` and
  # `hash` (via `nix store prefetch-file --json <release-url>`) to update.
  herdr =
    let
      version = "0.8.0";
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "herdr";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://github.com/herdrdev/herdr/releases/download/v${version}/herdr-linux-x86_64";
        hash = "sha256-uHLqfkD6LLF+hXrJtisb8m23tAPGIvXS8/WzX26azSg=";
      };
      dontUnpack = true;
      installPhase = ''
        runHook preInstall
        install -Dm755 $src $out/bin/herdr
        runHook postInstall
      '';
      meta = {
        description = "Terminal workspace manager for AI coding agents";
        homepage = "https://herdr.dev";
        license = pkgs.lib.licenses.asl20;
        platforms = [ "x86_64-linux" ];
        mainProgram = "herdr";
      };
    };
in
{
  home.packages = with pkgs; [
    rustup
    nodejs_22
    lazygit
    gcc
    git
    claude-code
    uv # python project/venv/interpreter management (pip/poetry/pyenv replacement)
    herdr
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
