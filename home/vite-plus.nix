# vite-plus (`vp`), imported by vxdev only.
#
# It lived in home/core until it turned out to be unusable on NixOS. vp's whole
# job is managing node/pnpm toolchains per project, and every runtime it
# installs is a musl build (`interpreter /lib/ld-musl-x86_64.so.1`). NixOS has
# no musl loader; programs.nix-ld does not cover it, because nix-ld shims the
# *glibc* loader at /lib64/ld-linux-x86-64.so.2. Supplying the musl loader by
# hand is not enough either -- the binary then wants musl builds of
# libstdc++.so.6 and libgcc_s.so.1 -- and `vp env off` (system-first) does not
# rescue it, since a configured default version still resolves to the managed
# runtime. So on judy and work `node` via vp could not execute at any version,
# while its four argv[0] proxies (node/npm/npx/corepack) collided with nodejs_26
# from home/toolchains.nix and broke the profile build outright.
#
# On vxdev none of that applies: it is Debian, it can run the musl runtimes, and
# per-directory resolution of the node/pnpm versions a vxsuite checkout pins is
# exactly what the VM needs. Judy and work get an ambient nix node instead and
# per-project toolchains from a devShell + direnv.
{ pkgs, ... }:

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
  home.packages = [ vite-plus ];
}
