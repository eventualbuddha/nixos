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
      brightness.show_label = false;
      workspaces.show_labels = false;
      media.album_art_only = true;
      clock.format = "{:%I:%M %p}"; # 12-hour
      # Drop the "Cloudy"-style condition text, keep just the icon +
      # temperature. Note: the temperature suffix itself ("°F"/"°C") is
      # hardcoded in noctalia's widget code, not configurable -- no field
      # exists to show the degree symbol without the letter.
      weather = {
        show_condition = false;
        show_temperature = true;
      };
    };

    # Bars are named (`[bar.<name>]`) -- a bare top-level `[bar]` table is
    # silently ignored ("no [bar.*] defined, using defaults" in the log),
    # which is why `weather` wasn't showing up before despite being enabled
    # below. "main" matches noctalia's own example config's convention.
    # Also: the field is `end`/`start`/`center`, not `end_widgets`.
    bar.main = {
      # Full default start list (launcher, wallpaper, workspaces) plus
      # weather, tacked onto the left side instead of mixed into the
      # right-hand icon tray.
      start = [ "launcher" "wallpaper" "workspaces" "weather" ];
      end = [
        "media"
        "tray"
        "notifications"
        "clipboard"
        "network"
        "bluetooth"
        "volume"
        "brightness"
        "battery"
        "control-center"
        "session"
      ];
    };

    # IP-based geolocation, feeding both the weather widget and night light.
    location.auto_locate = true;
    weather = {
      enabled = true;
      unit = "imperial";
    };

    # Wallpaper rotation. ~/Pictures/Wallpapers holds one subfolder per "set"
    # (e.g. Vancouver/) so sets stay exclusive -- `directory` below points at
    # whichever set is currently active; switch sets by changing this to a
    # different subfolder path and re-applying.
    wallpaper = {
      directory = "/home/brian/Pictures/Wallpapers/Vancouver";
      automation = {
        enabled = true;
        interval_seconds = 1800; # 30 min
        order = "random";
        recursive = true;
      };
    };
  };
}
