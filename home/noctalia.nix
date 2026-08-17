{ inputs, ... }:

{
  imports = [
    inputs.noctalia.homeModules.default
  ];

  programs.noctalia.enable = true;
  # Defaults are already a polished, animated bar/launcher/OSD set --
  # tune from noctalia's own settings UI once you know what you want to change.
}
