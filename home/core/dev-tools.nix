{ pkgs, lib, ... }:

let
  # vite-plus (https://viteplus.dev) is not in nixpkgs. Upstream ships a musl
  # build whose only content is a single static-pie `vp` -- `file` reports
  # "static-pie linked" and there is no .interp section -- so this needs no
  # autoPatchelfHook, just fetch and install, the same shape as `herdr` in
  # ./cli.nix.
  #
  # Nix owns the vp binary; vp keeps owning what it installs. The node and pnpm
  # toolchains it resolves per-directory still live in ~/.vite-plus and are
  # still managed by vp itself -- that is the whole point of having it, since it
  # is what makes a vxsuite checkout resolve the 24.19.0 and pnpm 10.34.5 that
  # repo pins. Only vp's own version comes from here now.
  #
  # The tradeoff of that split: `vp upgrade` cannot work against a store path.
  # Bump `version` and `hash` here instead (via
  # `nix store prefetch-file --json <release-url>`).
  vite-plus =
    let
      version = "0.3.0";
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "vite-plus";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://github.com/voidzero-dev/vite-plus/releases/download/v${version}/vp-x86_64-unknown-linux-musl.tar.gz";
        hash = "sha256-VI8pqJrYSsFFhoN309aJAnerAKe4Tv8z+j0hzHw3T5E=";
      };
      sourceRoot = ".";

      # vp dispatches on argv[0], so every tool it fronts is just another name
      # for the same binary -- exactly how nixpkgs' rustup ships cargo/rustc as
      # proxies. Providing them here means ~/.vite-plus/bin no longer has to be
      # on PATH at all: that directory becomes pure data (the installed node and
      # pnpm versions), which is the "nix installs the manager, the manager
      # installs the toolchains" split. Verified that a store-run proxy still
      # resolves per-directory -- 24.19.0/10.34.5 inside a vxsuite checkout,
      # the configured default elsewhere -- and that it needs no VP_HOME.
      installPhase = ''
        runHook preInstall
        install -Dm755 vp $out/bin/vp
        for proxy in node npm npx corepack pnpm pnpx pn pnx yarn yarnpkg vpr vpx hunk hunkdiff; do
          ln -s vp "$out/bin/$proxy"
        done
        runHook postInstall
      '';
      meta = {
        description = "Toolchain manager for JavaScript projects (node/pnpm/npm/yarn)";
        homepage = "https://viteplus.dev";
        platforms = [ "x86_64-linux" ];
        mainProgram = "vp";
      };
    };
in
{
  # Development toolchains that every machine gets, in the "nix installs the
  # manager, the manager installs the toolchains" shape. Distinct from
  # home/toolchains.nix, which is the ambient node/containers set that only
  # judy and work import.
  home.packages = with pkgs; [
    # rustup, not a pinned rustc: it reads each repo's rust-toolchain.toml
    # (vxsuite pins channel 1.98.0) and that is the source of truth nix should
    # not second-guess. The toolchains stay in ~/.rustup, installed and updated
    # by rustup itself.
    rustup
    # nixpkgs' `rustup` bundles its own bin/rust-analyzer proxy (like
    # cargo/rustc/etc, it just re-execs into `rustup`, which then errors with
    # "could not choose a version" since no default toolchain is set). hiPrio
    # makes the real rust-analyzer package win that filename collision in the
    # merged profile instead.
    (lib.hiPrio rust-analyzer)

    # cargo subcommands. Previously `cargo install`ed into ~/.cargo/bin, where
    # they shadowed the nix profile in bash and had to be updated by hand.
    cargo-binstall
    cargo-hack
    cargo-llvm-cov
    wasm-pack

    # go, replacing the copy proto used to provide. proto managed go, node and
    # pnpm, but vite-plus won the node/pnpm shims on PATH, so go was the only
    # thing it uniquely supplied -- not worth 739M and a second version manager.
    go

    # node, npm, npx and corepack collide with nodejs_22 from
    # home/toolchains.nix, which judy and work import alongside this file
    # (vxdev takes home/core only, so nothing opposes the proxies there).
    # vite-plus wins the collision: its proxies resolve the version a repo
    # pins, which a fixed ambient 22 cannot. Same shape as the hiPrio on
    # rust-analyzer above, and buildEnv fails the whole profile without it.
    (lib.hiPrio vite-plus)
  ];
}
