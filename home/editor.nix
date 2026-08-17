{ pkgs, lib, ... }:

{
  # Plain package, not `programs.neovim.enable` -- that module unconditionally
  # writes its own ~/.config/nvim/init.lua (host-provider settings), which
  # collides with LazyVim owning that same path as a normal mutable config
  # dir. `home.sessionVariables.EDITOR` (set in home/default.nix) covers what
  # `defaultEditor` would have given us.
  home.packages = with pkgs; [
    neovim
    ripgrep
    fd
    gcc
    unzip
  ];

  # Bootstrap the official LazyVim starter config, but only if ~/.config/nvim
  # doesn't already exist -- this never clobbers your own edits, and matches
  # LazyVim's own documented install method (a normal, mutable config directory
  # managed by lazy.nvim at runtime, not something declarative nixvim fits).
  home.activation.installLazyVim = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -d "$HOME/.config/nvim" ]; then
      $DRY_RUN_CMD ${pkgs.git}/bin/git clone --depth 1 https://github.com/LazyVim/starter "$HOME/.config/nvim"
      $DRY_RUN_CMD rm -rf "$HOME/.config/nvim/.git"
    fi
  '';
}
