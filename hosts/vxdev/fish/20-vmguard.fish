# Managed by home-manager (hosts/vxdev/home.nix).
#
# Egress from this guest goes through the vmguard proxy on whichever host it is
# booted on -- work and judy each run one -- and nothing reaches the internet
# directly. The address below is the same on both, which is what keeps this file
# host-independent; see modules/vmguard.nix.
#
# The bash half of this lives at /etc/profile.d/vmguard.sh system-wide, written
# per-guest outside this repo; this is the fish half, which used to be a
# hand-copied conf.d file.

set -gx HTTP_PROXY http://192.168.124.1:8080
set -gx HTTPS_PROXY http://192.168.124.1:8080
set -gx http_proxy http://192.168.124.1:8080
set -gx https_proxy http://192.168.124.1:8080
set -gx NO_PROXY localhost,127.0.0.1,::1
set -gx no_proxy localhost,127.0.0.1,::1

# Every host the proxy does not tunnel is TLS-bumped, presenting the MITM CA
# rather than the real server's chain. Clients that read the system trust store
# need nothing extra once that CA is installed there; clients that ship their
# own bundle have to be pointed at it by name. Node is one of those, and the
# failure is opaque -- SELF_SIGNED_CERT_IN_CHAIN from whatever npm, pnpm or a
# postinstall script was fetching, with nothing naming the proxy.
#
# The sibling cases: UV_SYSTEM_CERTS in 10-vendor-tools.fish and
# NIX_SSL_CERT_FILE from the nix hook (00-nix-profile-path.fish), plus the same
# variable in nix-daemon's drop-in, since the daemon inherits no shell
# environment. See READ_ONLY_HOSTS in modules/vmguard/egress_filter.py, which
# calls this out for downloads.claude.ai.
set -gx NODE_EXTRA_CA_CERTS /etc/ssl/certs/ca-certificates.crt

set -gx GIT_TERMINAL_PROMPT 0
