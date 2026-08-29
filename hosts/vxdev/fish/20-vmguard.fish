# Managed by home-manager (hosts/vxdev/home.nix).
#
# Egress from this guest goes through the vmguard proxy on `work`; nothing
# reaches the internet directly. guest-setup.sh writes the bash half of this to
# /etc/profile.d/vmguard.sh system-wide; this is the fish half, which used to be
# a hand-copied conf.d file.
#
# PROTO_OFFLINE_HOSTS points proto's connectivity check at the proxy rather than
# at a host it cannot reach, so it does not decide it is offline.
set -gx HTTP_PROXY http://192.168.124.1:8080
set -gx HTTPS_PROXY http://192.168.124.1:8080
set -gx http_proxy http://192.168.124.1:8080
set -gx https_proxy http://192.168.124.1:8080
set -gx NO_PROXY localhost,127.0.0.1,::1
set -gx no_proxy localhost,127.0.0.1,::1
set -gx PROTO_OFFLINE_HOSTS 192.168.124.1:8080
set -gx GIT_TERMINAL_PROMPT 0
