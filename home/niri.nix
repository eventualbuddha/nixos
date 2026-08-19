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

  # gnome-control-center hard-exits unless XDG_CURRENT_DESKTOP says GNOME/Unity
  # (it is under niri, correctly). This wrapper overrides just its own view of
  # that variable so panels like Online Accounts still work when launched
  # directly; apps that deep-link into it (e.g. GNOME Calendar's "Online
  # Account Settings" button) don't go through this and will still no-op.
  gnomeSettings = pkgs.writeShellScriptBin "gnome-settings" ''
    exec env XDG_CURRENT_DESKTOP=GNOME ${pkgs.gnome-control-center}/bin/gnome-control-center "$@"
  '';

  # macOS-style universal copy/paste. Ctrl+C and Ctrl+V mean copy/paste almost
  # everywhere, but terminals reserve Ctrl+C for SIGINT (and Ctrl+V for the
  # literal-next-key quote) and use the Ctrl+Shift+ variants instead -- so these
  # check the focused window's app-id and inject the right combo. Add more
  # app-ids to the terminal case as you add more terminal emulators.
  modClipboard =
    name: key:
    pkgs.writeShellScriptBin name ''
      set -euo pipefail
      app_id=$(${pkgs.niri}/bin/niri msg --json focused-window | ${pkgs.jq}/bin/jq -r '.app_id // empty')
      case "$app_id" in
        com.mitchellh.ghostty)
          ${pkgs.wtype}/bin/wtype -M ctrl -M shift -k ${key} -m shift -m ctrl
          ;;
        *)
          ${pkgs.wtype}/bin/wtype -M ctrl -k ${key} -m ctrl
          ;;
      esac
    '';
  modCopy = modClipboard "mod-copy" "c";
  modPaste = modClipboard "mod-paste" "v";

  # macOS Option-key typography. These are global binds that inject a character
  # through a virtual keyboard (wtype) rather than real xkb-level input, so the
  # key combo is swallowed by niri and never reaches the focused app at all --
  # which is why the set below sticks to punctuation keys. Alt+<letter> is left
  # alone on purpose (GTK menu mnemonics live there), so macOS's Option+G/R/2
  # for (c)/(R)/(TM) are deliberately not bound.
  typeChar = char: {
    action.spawn = [
      "wtype"
      char
    ];
  };
in
{
  home.packages = [
    screenRecordToggle
    gnomeSettings
    modCopy
    modPaste
    pkgs.wf-recorder
    pkgs.libnotify
    pkgs.wl-clipboard
    pkgs.wtype # virtual-keyboard text injection, used by mod-copy/mod-paste and the Alt+ typography binds
    pkgs.jq # used by mod-copy/mod-paste to read niri's focused-window JSON
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
            top-left = 8.0;
            top-right = 8.0;
            bottom-left = 8.0;
            bottom-right = 8.0;
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

      # No manually-spawned polkit agent here: `programs.niri.enable` (niri-flake)
      # already installs and starts its own (niri-flake-polkit.service, wanted by
      # niri.service) -- spawning a second one here made both fight over the same
      # D-Bus name and crash-loop.
      spawn-at-startup = [
        { command = [ "noctalia" ]; }
      ];

      binds = {
        "Mod+Escape".action.spawn = [
          "noctalia"
          "msg"
          "session"
          "lock"
        ];
        "Mod+Shift+Escape".action.toggle-keyboard-shortcuts-inhibit = [ ];
        "Mod+Shift+P".action.power-off-monitors = [ ];
        "Control+Alt+Delete".action.quit = [ ];

        # Volume / media, via noctalia's IPC
        "XF86AudioRaiseVolume".action.spawn = [
          "noctalia"
          "msg"
          "volume-up"
        ];
        "XF86AudioLowerVolume".action.spawn = [
          "noctalia"
          "msg"
          "volume-down"
        ];
        "XF86AudioMute".action.spawn = [
          "noctalia"
          "msg"
          "volume-mute"
        ];
        "XF86AudioPlay".action.spawn = [
          "noctalia"
          "msg"
          "media"
          "toggle"
        ];
        "XF86AudioNext".action.spawn = [
          "noctalia"
          "msg"
          "media"
          "next"
        ];
        "XF86AudioPrev".action.spawn = [
          "noctalia"
          "msg"
          "media"
          "previous"
        ];

        "Mod+Space".action.spawn = [
          "noctalia"
          "msg"
          "panel-toggle"
          "launcher"
        ];
        "Mod+Ctrl+L".action.spawn = [
          "noctalia"
          "msg"
          "session"
          "lock"
        ];
        "Mod+Shift+V".action.spawn = [
          "noctalia"
          "msg"
          "panel-toggle"
          "clipboard"
        ];
        "Mod+C".action.spawn = [ "mod-copy" ]; # macOS-style copy, any app
        "Mod+V".action.spawn = [ "mod-paste" ]; # macOS-style paste, any app
        "Mod+Shift+C".action.center-column = [ ];
        # Emoji picker: the launcher's built-in emoji provider, opened straight
        # into its `/emo` prefix (`/` is noctalia's provider_prefix). Picking a
        # result copies the emoji, then noctalia auto-pastes per
        # shell.launcher.auto_paste.
        "Mod+Period".action.spawn = [
          "noctalia"
          "msg"
          "panel-open"
          "launcher"
          "/emo"
        ];
        # Confirm-with-countdown logout/power panel (noctalia's own session UI).
        "Mod+Shift+Q".action.spawn = [
          "noctalia"
          "msg"
          "panel-toggle"
          "session"
        ];

        "Mod+Return".action.spawn = [ "ghostty" ];
        "Mod+B".action.spawn = [ "firefox" ];
        "Mod+E".action.spawn = [ "nautilus" ];
        "Mod+Shift+E".action.spawn = [
          "ghostty"
          "-e"
          "yazi"
        ];

        "Mod+Q".action.close-window = [ ];
        # Mod+F: maximize within the scrollable layout (leaves gaps/border).
        # Mod+Shift+F: true fullscreen (hides bar, no gaps/border).
        "Mod+F".action.maximize-column = [ ];
        "Mod+Shift+F".action.fullscreen-window = [ ];
        "Mod+Shift+Space".action.toggle-window-floating = [ ];

        # Grow/shrink the focused column horizontally.
        "Mod+Minus".action.set-column-width = "-10%";
        "Mod+Equal".action.set-column-width = "+10%";

        # macOS Option-key typography (see `typeChar` above for the mechanism
        # and for why no Alt+<letter> binds live here).
        #
        # NB: the dashes are swapped relative to real macOS, where Option+-
        # is the en dash and Option+Shift+- the em dash. The em dash is by far
        # the more common one to type, so it keeps the shorter combo here.
        "Alt+Minus" = typeChar "—";
        "Alt+Shift+Minus" = typeChar "–";
        "Alt+Semicolon" = typeChar "…";
        "Alt+8" = typeChar "•";
        # Curly quotes. niri matches binds on the *raw* (unshifted) keysym with
        # Shift as an ordinary modifier, hence BracketLeft/BracketRight rather
        # than BraceLeft/BraceRight for the shifted pairs.
        "Alt+BracketLeft" = typeChar "“";
        "Alt+Shift+BracketLeft" = typeChar "”";
        "Alt+BracketRight" = typeChar "‘";
        "Alt+Shift+BracketRight" = typeChar "’";
        # Math, on the same keys macOS puts them. The rest of macOS's math set
        # (v/p/x/j/w/b/d/z/m/l -> sqrt/pi/approx/delta/sum/integral/partial/
        # omega/mu/not) sits on Alt+<letter> and is left unbound for the reason
        # in the `typeChar` comment -- Alt+V is Firefox's View menu, and so on.
        "Alt+Comma" = typeChar "≤";
        "Alt+Period" = typeChar "≥";
        "Alt+Equal" = typeChar "≠";
        "Alt+Shift+Equal" = typeChar "±";
        "Alt+Slash" = typeChar "÷";
        "Alt+5" = typeChar "∞";
        "Alt+Shift+8" = typeChar "°";

        # macOS-style screenshot triad, all on the actual Print Screen key
        # instead of Super+Shift+3/4/5 (freed up below for move-to-workspace).
        "Print".action.screenshot = [ ]; # interactive area select
        "Shift+Print".action.screenshot-screen = {
          show-pointer = false;
        }; # fullscreen
        "Ctrl+Print".action.spawn = [ "screen-record-toggle" ]; # toggle recording

        "Mod+O".action.toggle-overview = [ ];

        # Arrow keys...
        "Mod+Left".action.focus-column-left = [ ];
        "Mod+Right".action.focus-column-right = [ ];
        "Mod+Down".action.focus-workspace-down = [ ];
        "Mod+Up".action.focus-workspace-up = [ ];

        # ...and vim-style h/j/k/l aliases: h/l move across columns, j/k move
        # between stacked windows within a column, u/i switch workspaces.
        "Mod+H".action.focus-column-left = [ ];
        "Mod+L".action.focus-column-right = [ ];
        "Mod+J".action.focus-window-down = [ ];
        "Mod+K".action.focus-window-up = [ ];
        "Mod+U".action.focus-workspace-down = [ ];
        "Mod+I".action.focus-workspace-up = [ ];

        "Mod+Shift+Left".action.move-column-left = [ ];
        "Mod+Shift+Right".action.move-column-right = [ ];
        "Mod+Shift+Down".action.move-column-to-workspace-down = [ ];
        "Mod+Shift+Up".action.move-column-to-workspace-up = [ ];

        # vim-style aliases for the above: h/l move the column, j/k reorder
        # the focused window within its column.
        "Mod+Shift+H".action.move-column-left = [ ];
        "Mod+Shift+L".action.move-column-right = [ ];
        "Mod+Shift+J".action.move-window-down = [ ];
        "Mod+Shift+K".action.move-window-up = [ ];

        "Mod+1".action.focus-workspace = 1;
        "Mod+2".action.focus-workspace = 2;
        "Mod+3".action.focus-workspace = 3;
        "Mod+4".action.focus-workspace = 4;
        "Mod+5".action.focus-workspace = 5;

        "Mod+Shift+1".action.move-column-to-workspace = 1;
        "Mod+Shift+2".action.move-column-to-workspace = 2;
        "Mod+Shift+3".action.move-column-to-workspace = 3;
        "Mod+Shift+4".action.move-column-to-workspace = 4;
        "Mod+Shift+5".action.move-column-to-workspace = 5;
      };
    };
  };
}
