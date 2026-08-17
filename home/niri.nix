{ config, pkgs, ... }:

# NB: no `imports` here for niri's home-manager module. The NixOS module
# (`programs.niri.enable = true;` in hosts/nixos/configuration.nix) already
# auto-imports `niri.homeModules.config` (settings only) for every user and
# wires up the correct package -- importing `homeModules.niri` again here
# would redeclare `programs.niri.package`/`enable` and fail to eval.

let
  screenRecordToggle = pkgs.writeShellScriptBin "screen-record-toggle" ''
    set -euo pipefail
    DIR="$HOME/Videos/Recordings"
    PIDFILE="/tmp/screen-record.pid"
    mkdir -p "$DIR"

    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      kill -INT "$(cat "$PIDFILE")"
      rm -f "$PIDFILE"
      ${pkgs.libnotify}/bin/notify-send "Screen recording" "Stopped. Saved to $DIR"
    else
      OUT="$DIR/$(date +%Y-%m-%d_%H-%M-%S).mp4"
      ${pkgs.wf-recorder}/bin/wf-recorder -f "$OUT" &
      echo $! > "$PIDFILE"
      ${pkgs.libnotify}/bin/notify-send "Screen recording" "Started: $OUT"
    fi
  '';
in
{
  home.packages = [
    screenRecordToggle
    pkgs.wf-recorder
    pkgs.libnotify
  ];

  programs.niri = {
    settings = {
      prefer-no-csd = true;

      hotkey-overlay.skip-at-startup = true;

      layout = {
        background-color = "transparent";

        focus-ring = {
          enable = true;
          width = 3;
          active.color = "#A8AEFF";
          inactive.color = "#505050";
        };

        gaps = 6;

        struts = {
          left = 20;
          right = 20;
          top = 20;
          bottom = 20;
        };
      };

      input = {
        keyboard.xkb.layout = "us";
        touchpad = {
          click-method = "button-areas";
          dwt = true;
          dwtp = true;
          natural-scroll = true;
          scroll-method = "two-finger";
          tap = true;
          tap-button-map = "left-right-middle";
          middle-emulation = true;
          accel-profile = "adaptive";
        };
        focus-follows-mouse.enable = true;
        warp-mouse-to-focus.enable = false;
      };

      # No `outputs` block: niri auto-detects whatever monitor(s) are connected.
      # Tune per-output scale/position/refresh-rate here once you know your setup:
      # outputs."eDP-1".scale = 1.5;

      environment = {
        CLUTTER_BACKEND = "wayland";
        GDK_BACKEND = "wayland";
        MOZ_ENABLE_WAYLAND = "1";
        NIXOS_OZONE_WL = "1";
        QT_QPA_PLATFORM = "wayland";
        QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
        ELECTRON_OZONE_PLATFORM_HINT = "auto";
        XDG_SESSION_TYPE = "wayland";
        XDG_CURRENT_DESKTOP = "niri";
      };

      window-rules = [
        {
          matches = [ { } ];
          geometry-corner-radius = {
            top-left = 20.0;
            top-right = 20.0;
            bottom-left = 20.0;
            bottom-right = 20.0;
          };
          clip-to-geometry = true;
        }
      ];

      layer-rules = [
        {
          # Set the overview wallpaper on the backdrop
          matches = [ { namespace = "^noctalia-wallpaper*"; } ];
          place-within-backdrop = true;
        }
      ];

      spawn-at-startup = [
        { command = [ "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1" ]; }
        { command = [ "noctalia" ]; }
      ];

      binds = {
        "Mod+Escape".action.toggle-keyboard-shortcuts-inhibit = [ ];
        "Mod+Shift+P".action.power-off-monitors = [ ];
        "Control+Alt+Delete".action.quit = [ ];

        # Volume / media, via noctalia's IPC
        "XF86AudioRaiseVolume".action.spawn = [ "noctalia" "msg" "volume-up" ];
        "XF86AudioLowerVolume".action.spawn = [ "noctalia" "msg" "volume-down" ];
        "XF86AudioMute".action.spawn = [ "noctalia" "msg" "volume-mute" ];
        "XF86AudioPlay".action.spawn = [ "noctalia" "msg" "media" "toggle" ];
        "XF86AudioNext".action.spawn = [ "noctalia" "msg" "media" "next" ];
        "XF86AudioPrev".action.spawn = [ "noctalia" "msg" "media" "previous" ];

        "Mod+Space".action.spawn = [ "noctalia" "msg" "panel-toggle" "launcher" ];
        "Mod+L".action.spawn = [ "noctalia" "msg" "session" "lock" ];

        "Mod+Return".action.spawn = [ "ghostty" ];
        "Mod+B".action.spawn = [ "firefox" ];
        "Mod+E".action.spawn = [ "nautilus" ];
        "Mod+Shift+E".action.spawn = [ "ghostty" "-e" "yazi" ];

        "Mod+Q".action.close-window = [ ];
        "Mod+F".action.fullscreen-window = [ ];
        "Mod+Shift+Space".action.toggle-window-floating = [ ];

        "Super+Shift+3".action.screenshot-screen = { show-pointer = false; };
        "Super+Shift+4".action.screenshot = [ ];
        "Super+Shift+5".action.spawn = [ "screen-record-toggle" ];

        "Mod+Left".action.focus-column-left = [ ];
        "Mod+Right".action.focus-column-right = [ ];
        "Mod+Down".action.focus-workspace-down = [ ];
        "Mod+Up".action.focus-workspace-up = [ ];

        "Mod+Shift+Left".action.move-column-left = [ ];
        "Mod+Shift+Right".action.move-column-right = [ ];
        "Mod+Shift+Down".action.move-column-to-workspace-down = [ ];
        "Mod+Shift+Up".action.move-column-to-workspace-up = [ ];

        "Mod+1".action.focus-workspace = 1;
        "Mod+2".action.focus-workspace = 2;
        "Mod+3".action.focus-workspace = 3;
        "Mod+4".action.focus-workspace = 4;
        "Mod+5".action.focus-workspace = 5;

        # Note: Ctrl+Shift+N here (not Mod+Shift+N) so these never collide with
        # the Super+Shift+3/4/5 screenshot/recording binds above -- niri's "Mod"
        # is the Super key by default.
        "Ctrl+Shift+1".action.move-column-to-workspace = 1;
        "Ctrl+Shift+2".action.move-column-to-workspace = 2;
        "Ctrl+Shift+3".action.move-column-to-workspace = 3;
        "Ctrl+Shift+4".action.move-column-to-workspace = 4;
        "Ctrl+Shift+5".action.move-column-to-workspace = 5;
      };
    };
  };
}
