# Managed by home-manager (hosts/vxdev/home.nix).
#
# Shell integration for the version managers this VM's vxsuite work depends on.
# They are not nix packages and are not managed here -- this only sources the
# env files their own installers write, guarded so a shell still starts if one
# is uninstalled. Deliberately ordered after 00-nix-profile-path.fish: these
# prepend their own shim directories, which is what makes `node` and `pnpm`
# resolve per-directory to the versions vxsuite pins rather than to anything on
# the profile.

# proto
set -gx PROTO_HOME "$HOME/.proto"
set -gx PATH "$PROTO_HOME/shims" "$PROTO_HOME/bin" $PATH

# vite-plus (https://viteplus.dev) -- resolves node/pnpm from .node-version and
# package.json's packageManager, which is why the VM already had the 24.19.0 and
# pnpm 10.34.5 that vxsuite pins.
test -e "$HOME/.vite-plus/env.fish"; and source "$HOME/.vite-plus/env.fish"

# moon
test -e "$HOME/.moon/bin/env.fish"; and source "$HOME/.moon/bin/env.fish"

# rustup (this VM's rustup is its own install, not the nixpkgs one that
# home/toolchains.nix gives judy and work)
test -e "$HOME/.cargo/env.fish"; and source "$HOME/.cargo/env.fish"

# uv. home-manager generates fish completions from the packages it installs, but
# uv is not among the ones it can do that for, so they are still loaded here.
# UV_SYSTEM_CERTS makes uv use the system trust store -- without it uv fails TLS
# verification against package indexes behind vmguard's MITM proxy with
# "invalid peer certificate: UnknownIssuer".
set -gx UV_SYSTEM_CERTS 1
if type -q uv
    uv generate-shell-completion fish | source
    uvx --generate-shell-completion fish | source
end

# vxsuite's own scripts read this.
set -gx VX_USE_TURBO true
