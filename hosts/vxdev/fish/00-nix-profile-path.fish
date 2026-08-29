# Managed by home-manager (hosts/vxdev/home.nix).
#
# fish sources conf.d/*.fish in name order and only then config.fish, which is
# what home-manager generates -- so a PATH set from programs.fish.shellInit
# lands after every other file here has already run. Several of them look for
# tools that live in the nix profile (10-vendor-tools.fish guards uv
# completions on `type -q uv`), so the profile has to be on PATH first. The 00-
# prefix guarantees that.
#
# -m moves the entry to the front if something else already added it.
fish_add_path -gm $HOME/.nix-profile/bin

# claude, agy and moshi live here -- the tools with no nixpkgs equivalent, plus
# the self-updating claude install (see home/core/claude-code.nix). home-manager's
# sessionPath also adds this, but only from config.fish, which is too late for
# anything in conf.d to see it.
fish_add_path -g $HOME/.local/bin
