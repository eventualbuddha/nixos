# vite-plus (`vp`), imported by vxdev only.
#
# It lived in home/core until it turned out to be unusable on NixOS: the
# node/pnpm runtimes vp installs could not exec, because they were musl builds
# (`interpreter /lib/ld-musl-x86_64.so.1`) and NixOS has no musl loader --
# programs.nix-ld does not cover it, since nix-ld shims the *glibc* loader at
# /lib64/ld-linux-x86-64.so.2. On top of that, vp's four argv[0] proxies
# (node/npm/npx/corepack) collided with nodejs_26 from home/toolchains.nix and
# broke the profile build outright, so it is vxdev-only.
#
# The musl half of that story turned out to be self-inflicted, and it bit vxdev
# too: vp picks the libc of the node tarball it downloads from *its own* build
# target, not from the host. Installing the `-musl` vp release below therefore
# made vp fetch musl node builds -- invisible for a while, because node only
# publishes musl tarballs for v26+, so every 20/22/24 runtime here is glibc and
# only the v26 ones broke. On Debian that surfaced as
#
#   error: Failed to exec .../js_runtime/node/26.8.1/bin/node:
#   No such file or directory (os error 2)
#
# i.e. the ELF interpreter is missing, not the binary. Hence the `-gnu` release
# below. Any runtime installed while the musl vp was in the profile is still
# musl and still cannot run: `vp env uninstall <version>` and reinstall it.
{
  pkgs,
  ...
}:

let
  # vite-plus (https://viteplus.dev) is not in nixpkgs, so fetch the release
  # tarball, whose only content is a single `vp`. The musl build is the
  # tempting one -- static-pie, no .interp section, no autoPatchelfHook needed,
  # the same shape as `herdr` in ./cli.nix -- but see the header: vp derives
  # the libc of the node tarballs it downloads from its own target triple, so
  # the musl vp hands this Debian box node builds it cannot exec. The gnu build
  # is dynamically linked against glibc/libgcc and needs the usual patchelf
  # pass.
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
        url = "https://github.com/voidzero-dev/vite-plus/releases/download/v${version}/vp-x86_64-unknown-linux-gnu.tar.gz";
        hash = "sha256-aOAquir4d8OPGepADnMB0IPqGOrYdx3IB1eBLCSsxNA=";
      };
      sourceRoot = ".";

      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      buildInputs = [
        pkgs.stdenv.cc.cc.lib # libgcc_s.so.1
        pkgs.glibc # libc/libm/libdl/librt/libpthread
      ];

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
