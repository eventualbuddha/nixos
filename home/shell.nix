{ ... }:

{
  programs.fish = {
    enable = true;
    shellAliases = {
      ls = "eza --icons --group-directories-first";
      ll = "eza -l --icons --group-directories-first";
      lt = "eza --tree --icons --group-directories-first";
    };
  };

  programs.zoxide.enable = true;
}
