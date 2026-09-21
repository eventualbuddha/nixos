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
      version = "0.9.1";
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "herdr";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://github.com/herdrdev/herdr/releases/download/v${version}/herdr-linux-x86_64";
        hash = "sha256-KgL+0WvrZR7wBuHUPwSPZSyk3FitBTzS1ERQVj1cVLc=";
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

  # `ctree` -- copy-on-write directory cloning via reflinks. Not in nixpkgs,
  # and upstream ships no release binaries, so unlike herdr above this is built
  # from source; it is a small pure-Rust tree (clap, anyhow, reflink-copy) so
  # that costs little.
  #
  # The naming is worth writing down because it is genuinely confusing: the
  # *crate* is `clonetree` and it is a library, published for other Rust code
  # to call. The CLI lives in the same workspace as `crates/ctree` and is the
  # only part wanted on PATH, hence `-p ctree` below.
  #
  # Every machine in this config is on btrfs, so this belongs in core rather
  # than on the vxsuite guest alone. Bump `version` and both hashes to update
  # (src via `nix store prefetch-file --unpack --json <tarball>`; for cargoHash
  # set it to lib.fakeHash and read the right one out of the build error).
  ctree =
    let
      version = "0.0.2";
    in
    pkgs.rustPlatform.buildRustPackage {
      pname = "ctree";
      inherit version;
      src = pkgs.fetchFromGitHub {
        owner = "cortesi";
        repo = "clonetree";
        tag = "v${version}";
        hash = "sha256-ayk1nBgB4xllZbiU/574fKUCfcIDus1ue4ITCUxbEaU=";
      };
      cargoHash = "sha256-iT0W8DVPMPKuVwtorkjobUy2ChyCsKk6fiaT9TP9HyM=";
      cargoBuildFlags = [
        "-p"
        "ctree"
      ];

      # Upstream v0.0.2 never restores the destination file's mode: the only
      # copy call is `reflink_or_copy`, and `set_permissions` appears nowhere
      # outside its own test module. So every cloned file gets the process
      # umask -- executables lose +x, read-only files become writable.
      # Measured on real btrfs before patching: 755 -> 644, 444 -> 644.
      #
      # That is not cosmetic for what this is used for. A vxsuite worktree has
      # 1432 executable files (107 of them tracked, including .husky/pre-commit
      # and the scripts under apps/*/scripts), and a clone of it would arrive
      # with every one of them non-executable.
      #
      # The crate's own `file_permissions_are_preserved` test asserts the
      # correct behaviour and fails upstream, at the v0.0.2 tag and at main --
      # the four commits since the tag are style and dependency churn. So this
      # is not a patch racing a fix; send it upstream if you care to.
      patches = [ ./ctree-preserve-permissions.patch ];

      # With the patch applied the suite passes, so it is left on rather than
      # disabled -- that failing test is exactly the regression alarm wanted
      # here, and if a version bump ever makes the patch redundant this is what
      # will say so.
      checkFlags = [ ];
      meta = {
        description = "Copy-on-write directory cloning with reflinks";
        homepage = "https://github.com/cortesi/clonetree";
        license = pkgs.lib.licenses.mit;
        platforms = pkgs.lib.platforms.linux;
        mainProgram = "ctree";
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

    # Offline batch dedupe for btrfs, which every machine here runs. Worth
    # having around because reflink-aware tooling only makes *new* copies
    # cheap: a tree that was already written out full-size (an rsync'd /home,
    # a worktree made before the tooling existed) only gets its extents shared
    # by a pass of this. Root-only in practice -- it needs FIDEDUPERANGE on
    # files it does not own.
    duperemove

    # Previously `cargo install`ed into ~/.cargo/bin, where they shadowed the
    # nix profile in bash and needed updating by hand.
    hyperfine # benchmarking
    xh # nicer `curl` for HTTP APIs
    tealdeer # `tldr` -- community cheatsheets for common commands
    ripunzip # parallel unzip
    tree-sitter
    tuicr # code review TUI

    # Agent tooling. claude-code is deliberately absent -- see
    # ./claude-code.nix for why it is bootstrapped rather than installed.
    uv # python project/venv/interpreter management (pip/poetry/pyenv replacement)
    herdr
    ctree

    brightnessctl
  ];

  # Per-project toolchain pinning: a project's own flake.nix/shell.nix +
  # direnv gives fully reproducible, per-directory tool versions via the Nix
  # store. This is what makes it safe to keep node/rust off the profile above.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
}
