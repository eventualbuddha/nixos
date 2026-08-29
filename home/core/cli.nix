{ pkgs, ... }:

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
      version = "0.8.2";
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "herdr";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://github.com/herdrdev/herdr/releases/download/v${version}/herdr-linux-x86_64";
        hash = "sha256-l2FQoU1JDJSyQ+ouGn6y37Z/EuNrGC25CTb2co5q7PQ=";
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
  # Terminal tools that are wanted on every machine, graphical or not -- a
  # headless build VM reached over SSH gets exactly the same shell as the
  # laptop. Deliberately excludes language toolchains: those are per-project
  # and belong in a devShell, not on the profile PATH (see home/toolchains.nix
  # for why they are host-side only).
  home.packages = with pkgs; [
    # `ls` and `cat` in home/core/shell.nix are aliased to these two, so they
    # have to travel with that module rather than staying next to the GUI
    # apps -- the aliases are broken without them.
    eza
    bat

    yazi
    btop
    fastfetch

    # CLI quality-of-life
    gh # GitHub CLI
    lazygit
    ripgrep # rg
    dust # nicer `du` (you asked for "df-dust" -- the package/binary is `dust`)
    duf # nicer `df`, pairs with dust
    procs # nicer `ps`
    jq # JSON processor

    # Agent tooling. claude-code is deliberately absent -- see
    # ./claude-code.nix for why it is bootstrapped rather than installed.
    uv # python project/venv/interpreter management (pip/poetry/pyenv replacement)
    herdr
  ];

  # Per-project toolchain pinning: a project's own flake.nix/shell.nix +
  # direnv gives fully reproducible, per-directory tool versions via the Nix
  # store. This is what makes it safe to keep node/rust off the profile above.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
}
