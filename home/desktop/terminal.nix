_:

{
  programs.ghostty = {
    enable = true;
    settings = {
      font-size = 9;
      font-family = "JetBrainsMono Nerd Font";
      theme = "Catppuccin Mocha";
      window-decoration = false;
    };
  };

  # Attach to herdr on the vxsuite guest. `--remote-keybindings server`
  # matters: with the default (local) keybindings, herdr drops the client's
  # `[[keys.command]]` entries, so `prefix+d` (proj's dashboard, a plugin
  # action that runs on vx) would do nothing. vx's config.toml is the same
  # home/core/herdr.toml, so nothing else changes.
  programs.fish.shellAbbrs.hvx = "herdr --remote vx --remote-keybindings server";
}
