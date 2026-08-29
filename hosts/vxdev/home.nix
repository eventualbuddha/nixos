# Standalone home-manager for `vx`: the Debian 12 VM that vxsuite is built in.
#
# Not a NixOS host -- vxsuite's dev environment is deliberately Debian, to match
# what VotingWorks ships on, and several parts of the repo assume it (a
# `sudo apt install` in apps/pollbook/backend/Makefile, `lsb_release -cs` in the
# scan backends, and playwright's postinstall, which downloads an FHS-linked
# Chromium and shells out to apt for its system libraries). So this imports
# home/core only: the portable half that has no NixOS modules and no graphical
# session behind it.
#
# What nix is here for is the thing Debian 12 is bad at: current tools on an old
# libc. Debian 12 ships glibc 2.36, and neovim's own releases now need newer, so
# nvim was being built from source and symlinked out of a build tree at
# ~/code/3rd-party/neovim/build/bin/nvim -- one `git clean` away from no editor.
# A nix-built neovim links the store's own glibc (2.42) rather than Debian's, so
# it just runs.
#
# Apply with:
#   nix run home-manager/master -- switch --flake ~/nixos#vx@vxdev
_:

{
  imports = [ ../../home/core ];

  home = {
    username = "vx";
    homeDirectory = "/home/vx";
    stateVersion = "25.05";
    sessionVariables.EDITOR = "nvim";
  };

  programs.home-manager.enable = true;

  # Standalone home-manager installs into ~/.nix-profile, and nothing on this
  # Debian box puts that directory on PATH: /etc/fish/conf.d/nix.fish adds only
  # the daemon's default profile (/nix/var/nix/profiles/default/bin), not the
  # per-user one. Meanwhile every conf.d file this VM has accumulated --
  # vite-plus, proto, moon, rustup, local-bin -- calls `fish_add_path` to put
  # itself at the front.
  #
  # fish sources conf.d/*.fish before config.fish, and home-manager generates
  # config.fish, so this runs last and wins. `-m` moves the entry to the front
  # rather than skipping it if some other file already added it.
  #
  # Not in home/core/shell.nix because it is wrong on NixOS: there
  # `useUserPackages` puts these packages in /etc/profiles/per-user/$USER/bin
  # and ~/.nix-profile does not exist.
  #
  # Without this the whole config silently does nothing useful: `nvim` still
  # resolved to the hand-built 0.12.2 symlink in ~/.local/bin, and `rg`/`eza`
  # to ~/.cargo/bin.
  programs.fish.shellInit = ''
    fish_add_path -gm $HOME/.nix-profile/bin
  '';

  # Everything that was in ~/.gitconfig, which guest-setup.sh and hand-editing
  # built up over the life of this VM. home-manager writes ~/.config/git/config,
  # and git reads BOTH globals with ~/.gitconfig winning -- so leaving that file
  # in place would silently shadow every setting below. It gets moved aside when
  # this config is first switched to.
  programs.git.settings = {
    user.email = "brian@voting.works"; # commits from this VM are work commits
    init.defaultBranch = "main";
    core = {
      editor = "nvim";
      autocrlf = "input";
    };
    pull.rebase = true;
    rebase = {
      autoStash = true;
      autoSquash = true;
    };
    push = {
      autoSetupRemote = true;
      default = "simple";
    };
    fetch = {
      prune = true;
      pruneTags = false;
    };
    merge.conflictStyle = "zdiff3";
    diff = {
      algorithm = "histogram";
      colorMoved = "default";
    };
    branch.sort = "-committerdate";
    tag.sort = "version:refname";
    rerere.enabled = true;
    help.autocorrect = "prompt";

    # Egress from this guest goes through the vmguard proxy on the host; nothing
    # reaches the internet directly.
    http.proxy = "http://192.168.124.1:8080";

    # No SSH egress to GitHub from here -- the proxy only carries HTTPS -- so
    # rewrite the SSH form of every votingworks remote to HTTPS. Note this is
    # the reverse of what vxsuite's docs/development.md suggests, which assumes
    # a VM that can reach github.com over SSH directly.
    url."https://github.com/".insteadOf = "git@github.com:";

    # The guest carries no git credentials of its own beyond the gh token; an
    # empty top-level helper stops git falling back to any system helper, while
    # the per-host entries in home/core/git.nix still route GitHub through
    # `gh auth git-credential`. Those now point at the nix-provided gh rather
    # than /usr/bin/gh, which is what ~/.gitconfig had.
    credential.helper = "";
  };

  # No YubiKey is passed through to this guest, so the sk- key home/core/git.nix
  # defaults to cannot be used at all -- ssh-keygen would need the token present
  # to produce a signature. This is a plain ed25519 key that lives only here,
  # generated with:
  #   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 \
  #     -C "brian@voting.works git signing (vxvm local)"
  # and registered as a Signing Key at https://github.com/settings/keys.
  programs.git.signing.key = "/home/vx/.ssh/id_ed25519.pub";

}
