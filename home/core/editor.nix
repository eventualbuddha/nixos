{
  inputs,
  pkgs,
  lib,
  ...
}:

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
    unzip
    nixd
    # statix (lint) and nixfmt (format) -- the lang.nix LazyVim extra wires
    # nvim-lint/conform.nvim to call these directly, with no Mason install
    # path for either, so they have to come from here (same as nixd above).
    statix
    nixfmt
    # No `gcc` here, even though treesitter builds parsers with one. A compiler
    # on the profile PATH is a toolchain, and core carries no toolchains (see
    # home/core/default.nix) -- the hosts that want an ambient one already get
    # it from home/toolchains.nix. It also actively breaks vxdev, which imports
    # core without toolchains.nix: nix's gcc shadows Debian's, and it does not
    # search /usr/include, so every apt -dev header goes missing and native node
    # modules stop compiling (node-quirc on <png.h>, with libpng-dev installed).
    # Debian's own build-essential gcc serves treesitter there just fine.
  ];

  # Bootstrap the official LazyVim starter config: LazyVim expects a normal,
  # mutable config directory that lazy.nvim manages at runtime, which is not
  # something declarative nixvim fits. Only the initial seeding happens here.
  #
  # The starter comes from a pinned flake input rather than a `git clone` at
  # activation time. Activation runs at boot, often before DNS is up, and it
  # aborts at the first failing step -- so a failed clone took out every step
  # after it, linkGeneration included. That is what left this machine's niri
  # with its stock default config and no noctalia on first boot. Reading from
  # the store instead means activation never touches the network, and the
  # starter revision is pinned/updatable like every other input
  # (`nix flake update lazyvim-starter`).
  #
  # Ordered after linkGeneration, and guarded on init.lua rather than on the
  # directory, because linkGeneration also populates ~/.config/nvim (options.lua,
  # keymaps.lua, plugins/): a directory test would report "already installed"
  # for a tree with no LazyVim in it, and seeding first would make the starter's
  # own copies of those files collide with the home-manager-owned ones. `cp -n`
  # then leaves anything home-manager owns untouched, and --no-preserve=mode
  # drops the store's read-only bits so lazy.nvim can write there.
  home.activation.installLazyVim = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if [ ! -e "$HOME/.config/nvim/init.lua" ]; then
      run mkdir -p "$HOME/.config/nvim"
      run cp -rn --no-preserve=mode,ownership \
        ${inputs.lazyvim-starter}/. "$HOME/.config/nvim/"
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
    --
    -- LazyVim's own lazyvim.config.options sets clipboard=unnamedplus by
    -- default and loads before this file, so it has to be explicitly reset
    -- here -- otherwise its default silently wins and every yank/delete
    -- still syncs to the system clipboard despite the above.
    vim.opt.clipboard = ""

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

  # Inline "who last touched this line" blame, shown as dimmed virtual text at
  # the end of the cursor's line. gitsigns.nvim already ships with LazyVim, so
  # this is only turning on an option it has but leaves off by default -- no
  # extra plugin, and the spec merges into LazyVim's own gitsigns spec.
  xdg.configFile."nvim/lua/plugins/gitsigns.lua".text = ''
    return {
      "lewis6991/gitsigns.nvim",
      opts = {
        current_line_blame = true,
        current_line_blame_opts = {
          virt_text = true,
          virt_text_pos = "eol",
          delay = 300,
          ignore_whitespace = false,
        },
        current_line_blame_formatter = "  <author>, <author_time:%R> - <summary>",
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
