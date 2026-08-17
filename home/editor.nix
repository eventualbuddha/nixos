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
    nixd
    # statix (lint) and nixfmt (format) -- the lang.nix LazyVim extra wires
    # nvim-lint/conform.nvim to call these directly, with no Mason install
    # path for either, so they have to come from here (same as nixd above).
    statix
    nixfmt
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

  # Everything else under ~/.config/nvim stays a normal mutable directory
  # (lazy.nvim's plugin state lives there) -- these two files are LazyVim's
  # own designated "put your stuff here" files, and are small/static enough
  # to manage declaratively without fighting lazy.nvim for ownership.
  xdg.configFile."nvim/lua/config/options.lua".text = ''
    -- Options are automatically loaded before lazy.nvim startup
    -- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
    -- Add any additional options here

    -- System clipboard via OSC 52 (built into Neovim 0.10+, no plugin needed).
    -- Works locally (ghostty writes straight to the Wayland clipboard) and
    -- transparently over SSH too, since it's just a terminal escape sequence
    -- rather than a call to wl-copy.
    --
    -- Deliberately NOT setting clipboard=unnamedplus: that would fire an OSC 52
    -- write (and ghostty's clipboard-write indicator) on every single yank/
    -- delete, which gets noisy fast. Instead the "+ register stays opt-in --
    -- see the <leader>y keymap in keymaps.lua for the actual "copy this to the
    -- system clipboard" action.
    vim.g.clipboard = {
      name = "OSC 52",
      copy = {
        ["+"] = require("vim.ui.clipboard.osc52").copy("+"),
        ["*"] = require("vim.ui.clipboard.osc52").copy("*"),
      },
      paste = {
        ["+"] = require("vim.ui.clipboard.osc52").paste("+"),
        ["*"] = require("vim.ui.clipboard.osc52").paste("*"),
      },
    }
  '';

  xdg.configFile."nvim/lua/config/keymaps.lua".text = ''
    -- Keymaps are automatically loaded on the VeryLazy event
    -- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
    -- Add any additional keymaps here

    -- Explicit "copy to system clipboard" (via OSC 52) -- see options.lua for
    -- why this isn't wired to every yank/delete via clipboard=unnamedplus.
    vim.keymap.set({ "n", "v" }, "<leader>y", '"+y', { desc = "Copy to system clipboard" })
  '';
}
