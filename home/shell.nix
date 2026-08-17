{ ... }:

{
  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      set -g fish_greeting
    '';
    shellAliases = {
      ls = "eza --icons --group-directories-first";
      ll = "eza -l --icons --group-directories-first";
      lt = "eza --tree --icons --group-directories-first";
    };
  };

  programs.zoxide.enable = true;

  # Starship prompt, using the upstream "gruvbox-rainbow" preset verbatim
  # (fetched from starship/starship's own presets, not hand-rolled).
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    settings = builtins.fromTOML (builtins.readFile ./starship-gruvbox-rainbow.toml);
  };
}
