{ pkgs, inputs, ... }:

{
  imports = [
    inputs.zen-browser.homeModules.beta
  ];

  programs.zen-browser = {
    enable = true;
    setAsDefaultBrowser = false; # Firefox stays the system default for now

    profiles.default.presets.catppuccin = {
      enable = true;
      flavor = "Mocha";
      accent = "Mauve";
    };
  };

  # GUI-only. The terminal tools that used to live here (eza, bat, ripgrep,
  # gh, jq, yazi, btop, ...) moved to home/core/cli.nix so a headless machine
  # gets them too -- `ls`/`cat` in home/core/shell.nix are aliased to eza/bat
  # and were broken without them.
  home.packages = with pkgs; [
    vesktop
    pear-desktop # formerly `youtube-music`
  ];
}
