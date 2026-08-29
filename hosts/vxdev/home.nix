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
  };

  programs.home-manager.enable = true;

  # This VM's fish configuration, all of it. What used to be a pile of
  # hand-copied files in ~/.config/fish/conf.d is now declared here, so a
  # rebuilt guest gets the same shell without anyone remembering what was in
  # that directory. The shared half -- aliases, prompt, vi bindings, zoxide --
  # comes from home/core/shell.nix; these are the parts that are specific to
  # this machine.
  #
  # Kept as real .fish files under hosts/vxdev/fish/ rather than inline Nix
  # strings: fish is full of `$` and these scripts are long enough that
  # escaping them into '' '' blocks would cost more than the indirection, and
  # this way they stay syntax-highlighted and directly editable.
  #
  # The numeric prefixes are load order, which matters -- see the comments in
  # each file.
  xdg.configFile = {
    "fish/conf.d/00-nix-profile-path.fish".source = ./fish/00-nix-profile-path.fish;
    "fish/conf.d/10-vendor-tools.fish".source = ./fish/10-vendor-tools.fish;
    "fish/conf.d/20-vmguard.fish".source = ./fish/20-vmguard.fish;

    # `wt` manages the vxsuite worktrees under ~/code (see `wt help`). Only
    # here, not in home/core: it hardcodes ~/code/vxsuite and is meaningless on
    # a machine without that checkout. The completions call back into the
    # function itself (`wt __targets` / `wt __branches`) so the two stay in
    # sync, which is why they have to travel together.
    "fish/functions/wt.fish".source = ./fish/wt.fish;
    "fish/completions/wt.fish".source = ./fish/wt-completions.fish;
  };

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
