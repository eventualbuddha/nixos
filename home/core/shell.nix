{ lib, ... }:

{
  # EDITOR was set in home/default.nix and again in hosts/vxdev/home.nix; VISUAL
  # only existed in a hand-written conf.d file on the VM. Both belong next to
  # the rest of the shell config, set once for every machine.
  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };

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
      # Walk up. fish has no built-in for these and they are pure muscle
      # memory, so they belong with the shared config rather than in a
      # per-machine file.
      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";
      "....." = "cd ../../../..";

      ls = "eza -l --icons --group-directories-first";
      ll = "eza -l --icons --group-directories-first";
      lt = "eza --tree --icons --group-directories-first";
      cat = "bat";
    };
  };

  programs.zoxide.enable = true;

  # Starship prompt, using the upstream "tokyo-night" preset verbatim (fetched
  # from starship/starship's own presets, not hand-rolled).
  #
  # mkDefault so a host can swap the theme without unsetting anything. Three
  # machines, three prompts, so a terminal is identifiable at a glance:
  #
  #   work   this default, stock tokyo-night
  #   judy   gruvbox-rainbow          (hosts/judy/configuration.nix)
  #   vxdev  tokyo-night in VotingWorks purple  (hosts/vxdev/home.nix)
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    settings = lib.mkDefault (fromTOML (builtins.readFile ./starship-tokyo-night.toml));
  };
}
