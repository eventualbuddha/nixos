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

  home.packages = with pkgs; [
    vesktop
    pear-desktop # formerly `youtube-music`
    evolution # mail client; auto-uses the GNOME Online Accounts config
    yazi
    btop
    fastfetch
    eza

    # CLI quality-of-life
    gh # GitHub CLI
    ripgrep # rg
    dust # nicer `du` (you asked for "df-dust" -- the package/binary is `dust`)
    duf # nicer `df`, pairs with dust
    bat # nicer `cat`, syntax highlighting
    procs # nicer `ps`
  ];
}
