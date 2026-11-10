{ pkgs, ... }:

{
  # Terminal tools that are wanted on every machine, graphical or not -- a
  # headless build VM reached over SSH gets exactly the same shell as the
  # laptop. Deliberately excludes language toolchains: those are per-project
  # and belong in a devShell, not on the profile PATH (see home/toolchains.nix
  # for why they are host-side only).
  home.packages = with pkgs; [
    # `ls` and `cat` in home/core/shell.nix are aliased to these two, so they
    # have to travel with that module rather than staying next to the GUI
    # apps -- the aliases are broken without them.
    eza
    bat

    yazi
    btop
    fastfetch

    # CLI quality-of-life
    gh # GitHub CLI
    lazygit
    difftastic
    ripgrep # rg
    dust # nicer `du` (you asked for "df-dust" -- the package/binary is `dust`)
    duf # nicer `df`, pairs with dust
    procs # nicer `ps`
    jq # JSON processor
    bubblewrap # process sandboxing (bwrap)

    # Offline batch dedupe for btrfs, which every machine here runs. Worth
    # having around because reflink-aware tooling only makes *new* copies
    # cheap: a tree that was already written out full-size (an rsync'd /home,
    # a worktree made before the tooling existed) only gets its extents shared
    # by a pass of this. Root-only in practice -- it needs FIDEDUPERANGE on
    # files it does not own.
    duperemove

    # Previously `cargo install`ed into ~/.cargo/bin, where they shadowed the
    # nix profile in bash and needed updating by hand.
    hyperfine # benchmarking
    xh # nicer `curl` for HTTP APIs
    ripunzip # parallel unzip
    tree-sitter
    tuicr # code review TUI

    # Agent tooling. claude-code, codex and copilot are deliberately absent --
    # see ./claude-code.nix, ./codex.nix and ./copilot.nix for why they are
    # bootstrapped rather than installed.
    uv # python project/venv/interpreter management (pip/poetry/pyenv replacement)
    herdr

    brightnessctl
  ];

  # Shared by every host: a `herdr --remote` attach draws the sidebar from the
  # local config, and takes keybindings from it too unless run with
  # `--remote-keybindings server` -- except `[[keys.command]]` entries, which
  # a local-keybindings attach drops (see `hvx` in ../desktop/terminal.nix).
  xdg.configFile."herdr/config.toml".source = ./herdr.toml;

  # `tldr` -- community cheatsheets for common commands. tealdeer's default TLS
  # backend verifies against webpki roots compiled into the binary, so inside
  # the vmguard VM `tldr --update` dies in the handshake with the proxy's MITM
  # CA (same story as REQUESTS_CA_BUNDLE in hosts/vxdev/fish/20-vmguard.fish).
  # Native roots read the system bundle, which carries that CA in the guest and
  # is the ordinary public set everywhere else.
  programs.tealdeer = {
    enable = true;
    settings.updates.tls_backend = "rustls-with-native-roots";
  };

  # Per-project toolchain pinning: a project's own flake.nix/shell.nix +
  # direnv gives fully reproducible, per-directory tool versions via the Nix
  # store. This is what makes it safe to keep node/rust off the profile above.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
}
