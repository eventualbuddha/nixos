# Managed by home-manager (hosts/vxdev/home.nix).
#
# What is left of the vendor shell hooks. proto, vite-plus and rustup all used
# to be sourced from here; all three now come from home/core/dev-tools.nix, so
# the only thing still needed is uv's completions.
#
# vite-plus in particular no longer needs ~/.vite-plus/bin on PATH: nix ships
# vp plus the proxy names it dispatches (node, pnpm, npm, yarn, ...), so that
# directory is pure data now -- the node and pnpm versions vp installs and
# resolves per-directory.
#
# Nothing here prepends to PATH any more, so 00-nix-profile-path.fish's entry
# stays at the front rather than being pushed behind a pile of shim
# directories.

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
