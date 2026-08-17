{ pkgs, lib, ... }:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    extraPackages = with pkgs; [
      ripgrep
      fd
      gcc
      unzip
    ];
  };

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
