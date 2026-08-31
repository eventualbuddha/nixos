# Managed by home-manager (hosts/vxdev/home.nix).
#
# fish sources conf.d/*.fish in name order and only then config.fish, which is
# what home-manager generates -- so a PATH set from programs.fish.shellInit
# lands after every other file here has already run. Several of them look for
# tools that live in the nix profile (10-vendor-tools.fish guards uv
# completions on `type -q uv`), so the profile has to be on PATH first. The 00-
# prefix guarantees that.

# The nix installer's own shell hook. bash gets this for free -- the installer
# put source lines in /etc/bash.bashrc and /etc/profile.d/nix.sh, covering
# non-login and login bash -- but the fish half it wrote, /etc/fish/conf.d/nix.fish,
# does not fire for us, so fish has to source the hook itself.
#
# Source it rather than hand-copying what it does. It sets four things, and a
# partial reimplementation of it here is what previously left fish without
# `nix` on PATH at all (it lives in the default profile, not ~/.nix-profile)
# while bash had it:
#
#   PATH               /nix/var/nix/profiles/default/bin and ~/.nix-profile/bin
#   NIX_PROFILES       both profiles, for tools that walk them
#   NIX_SSL_CERT_FILE  the system trust store -- needed for anything nix
#                      fetches through vmguard's MITM proxy (compare
#                      UV_SYSTEM_CERTS in 10-vendor-tools.fish)
#   XDG_DATA_DIRS      the profiles' share/ trees
#
# It self-guards on __ETC_PROFILE_NIX_SOURCED, so sourcing it here is a no-op
# in any shell that already ran it.
if test -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish
    source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish
end

# -m moves the entry to the front if something else already added it -- which
# the hook above just did, in the other order.
fish_add_path -gm $HOME/.nix-profile/bin

# claude, agy and moshi live here -- the tools with no nixpkgs equivalent, plus
# the self-updating claude install (see home/core/claude-code.nix). home-manager's
# sessionPath also adds this, but only from config.fish, which is too late for
# anything in conf.d to see it.
fish_add_path -g $HOME/.local/bin
