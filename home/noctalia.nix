{ inputs, ... }:

{
  imports = [
    inputs.noctalia.homeModules.default
  ];

  programs.noctalia.enable = true;
  # Defaults are already a polished, animated bar/launcher/OSD set --
  # tune from noctalia's own settings UI once you know what you want to change.

  programs.noctalia.settings = {
    # Icons-only bar: drop the text labels on widgets that support it, and
    # collapse the media widget to just album art. `[widget.<type>]` settings
    # apply to every instance of that widget type.
    widget = {
      network.show_label = false;
      volume.show_label = false;
      battery.show_label = false;
      bluetooth.show_label = false;
      workspaces.show_labels = false;
      media.album_art_only = true;
    };
  };
}
