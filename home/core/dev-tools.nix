{ pkgs, lib, ... }:

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
    # pnpm, but vite-plus (now home/vite-plus.nix, vxdev only) won the node/pnpm
    # shims, so go was the only thing it uniquely supplied -- not worth 739M and
    # a second version manager.
    go
  ];
}
