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
{
  pkgs,
  lib,
  config,
  ...
}:

{
  imports = [
    ../../home/core
    # moshi-hook is wanted here and on work, but not on judy -- so it is
    # imported per-host rather than living in home/core or home/desktop.
    ../../home/moshi.nix
    # vite-plus: vxdev only, because its managed node/pnpm runtimes are musl
    # builds that cannot exec on NixOS. See the header of that file.
    ../../home/vite-plus.nix
  ];

  home = {
    username = "vx";
    homeDirectory = "/home/vx";
    stateVersion = "25.05";
  };

  programs.home-manager.enable = true;

  # Make the nix fish the login shell.
  #
  # On judy and work this is one line of NixOS (`users.users.brian.shell`), but
  # standalone home-manager owns nothing outside $HOME, so it cannot touch
  # /etc/passwd. The result was two fishes: `programs.fish.enable` put 4.8.1 in
  # the profile and generated ~/.config/fish/config.fish, while /etc/passwd
  # still pointed at Debian's /usr/bin/fish (3.6.0). Both read the same
  # generated config, so the prompt and aliases looked identical and the
  # version gap was invisible -- the outer shell was 3.6.0 and typing `fish`
  # inside it got you 4.8.1.
  #
  # So: do the privileged bit from activation, which is only tolerable because
  # this box has passwordless sudo (/etc/sudoers.d/vx). `sudo -n` so a machine
  # that ever loses that fails fast and visibly instead of hanging activation
  # on a password prompt nobody is watching.
  #
  # ~/.nix-profile/bin/fish rather than a ${pkgs.fish} store path, deliberately:
  # a store path would rewrite /etc/passwd on every fish update and leave
  # /etc/shells accumulating dead entries, and it would pin the login shell to
  # one generation. The profile symlink follows whatever generation is current.
  # The trade is that `nix-collect-garbage -d` plus a broken generation could
  # leave the login shell dangling; recover with `ssh vx -t /bin/bash`.
  home.activation.setLoginShell = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    let
      shell = "${config.home.homeDirectory}/.nix-profile/bin/fish";
    in
    ''
      if [ "$(/usr/bin/getent passwd "${config.home.username}" | ${pkgs.coreutils}/bin/cut -d: -f7)" != "${shell}" ]; then
        # chsh as root ignores /etc/shells, but other things that read it do
        # not, so keep it listed as a valid login shell either way.
        if ! ${pkgs.gnugrep}/bin/grep -qxF "${shell}" /etc/shells; then
          echo "${shell}" | run /usr/bin/sudo -n /usr/bin/tee -a /etc/shells > /dev/null
        fi
        run /usr/bin/sudo -n /usr/bin/chsh -s "${shell}" "${config.home.username}"
      fi
    ''
  );

  # Purple prompt on the VM. home/core/shell.nix sets the stock tokyo-night
  # preset for every machine; this overrides just the colors with VotingWorks
  # purple, so the vxsuite VM's terminals are distinguishable from judy's and
  # work's at a glance. See the header of the toml for where the colors come
  # from.
  programs.starship.settings = fromTOML (
    builtins.readFile ../../home/core/starship-tokyo-night-vx.toml
  );

  # Let home-manager own bash too, so this VM's shell environment comes from the
  # flake whichever shell is in use. fish has been fully declared for a while;
  # bash was the last hand-written surface, and it was carrying four lines that
  # had quietly become redundant plus two that had not.
  #
  # What the hand-written files were still doing, and what happens to each:
  #
  #   ~/.local/bin on PATH        kept -- now via home.sessionPath (declared in
  #                               home/core/claude-code.nix), which home-manager
  #                               writes into hm-session-vars.sh and this module
  #                               finally sources. Without it `claude` and
  #                               `moshi-hook` are simply missing: they are the
  #                               two tools nix bootstraps rather than packages.
  #   vmguard proxy               kept, below. /etc/profile.d is read by login
  #                               shells only, so ~/.bashrc is the only thing
  #                               covering non-login interactive ones -- without
  #                               it those shells have no egress at all.
  #   . ~/.vite-plus/env          dropped. vite-plus and its proxies (node,
  #   . ~/.cargo/env              pnpm, ...) and rustup now come from
  #                               home/core/dev-tools.nix, so these only served
  #                               to prepend the old self-installed copies ahead
  #                               of the nix ones. Removing them is what makes
  #                               bash resolve them the way fish already does.
  #   ~/bin, ~/.bash_aliases      Debian defaults guarding paths that do not
  #                               exist here; home-manager does not recreate
  #                               them and nothing notices.
  #
  # ~/.nix-profile/bin itself needs no help here, unlike in fish: the nix
  # installer put a nix-daemon.sh source line in /etc/bash.bashrc and
  # /etc/profile.d/nix.sh, which covers non-login and login bash respectively.
  programs.bash = {
    enable = true;

    # bashrcExtra rather than initExtra: this needs to apply to every bash, not
    # just interactive ones, since a non-interactive shell that reaches the
    # network needs the proxy just as much.
    bashrcExtra = ''
      # Egress from this guest goes through the vmguard proxy on `work`. The
      # fish half of this is hosts/vxdev/fish/20-vmguard.fish; guest-setup.sh
      # writes the file being sourced.
      [ -f /etc/profile.d/vmguard.sh ] && . /etc/profile.d/vmguard.sh

      # hm-session-vars.sh carries home.sessionPath (~/.local/bin, i.e. claude
      # and moshi-hook) and EDITOR/VISUAL, but home-manager sources it only from
      # ~/.profile -- which non-login interactive shells never read. Without
      # this, `claude` is missing in exactly those shells and present in login
      # ones, which is a miserable thing to debug. The script self-guards on
      # __HM_SESS_VARS_SOURCED, so sourcing it from both places is a no-op the
      # second time.
      . "${config.home.profileDirectory}/etc/profile.d/hm-session-vars.sh"
    '';

    # Debian's stock ~/.profile sources ~/.bashrc when the shell is bash;
    # home-manager's generated one does not. Without this a login shell gets
    # hm-session-vars and nothing else -- no prompt, no completions, no direnv,
    # no zoxide -- while non-login interactive shells get all of it, which is a
    # confusing split to debug. This restores what Debian did.
    profileExtra = ''
      if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
      fi
    '';
  };

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
