_:

{
  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      set -g fish_greeting
      # Vi-style bindings; "insert" arg starts each new prompt in insert mode
      # (fish_vi_key_bindings otherwise defaults to normal/command mode).
      # Escape always drops to normal mode regardless.
      fish_vi_key_bindings insert
    '';
    shellAliases = {
      ls = "eza --icons --group-directories-first";
      ll = "eza -l --icons --group-directories-first";
      lt = "eza --tree --icons --group-directories-first";
      cat = "bat";
    };
  };

  programs.zoxide.enable = true;

  # Starship prompt, using the upstream "gruvbox-rainbow" preset verbatim
  # (fetched from starship/starship's own presets, not hand-rolled).
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    settings = fromTOML (builtins.readFile ./starship-gruvbox-rainbow.toml);
  };
}
