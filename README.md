# nixos

Personal NixOS flake. Primary desktop is [niri](https://github.com/niri-wm/niri)
(scrollable-tiling Wayland compositor) + [ghostty](https://ghostty.org/) +
[noctalia](https://github.com/noctalia-dev/noctalia) (shell/bar/launcher), with
GNOME + GDM kept fully intact as a fallback session -- pick either at login.

Loosely inspired by [ctknightdev/nixos](https://github.com/ctknightdev/nixos),
rebuilt from scratch for this hardware/setup rather than adapted from it.

## Layout

```
flake.nix
hosts/
  common.nix              # shared system config across every machine
  <hostname>/
    configuration.nix     # host-specific: just hostname + hardware quirks
    hardware-configuration.nix   # from `nixos-generate-config` on that machine
home/                      # home-manager, user "brian", shared across hosts
  niri.nix                # compositor settings, keybinds, window rules
  noctalia.nix             # shell/bar config
  terminal.nix             # ghostty
  editor.nix                # neovim + LazyVim bootstrap
  dev.nix                   # rust/node/dev CLI tooling
  shell.nix                  # fish + starship
  apps.nix                    # browsers, chat, CLI utilities
  theme.nix                    # gtk/cursor theme
```

Adding a new machine: run `nixos-generate-config`, drop the two files under
`hosts/<name>/`, add `<name> = mkHost "<name>";` in `flake.nix`. Everything in
`hosts/common.nix` and `home/` applies automatically.

## Applying changes

```
nixos-rebuild build --flake .#<host>          # no root needed, just evaluates/builds
sudo nixos-rebuild switch --flake .#<host>    # or: ./apply.sh
```

## If niri doesn't work out

1. **Easiest**: log out, and on the GDM login screen pick "GNOME" from the
   session dropdown instead of "niri". Nothing about GNOME/GDM is touched by
   this config -- it's the exact same session that was there before.
2. **If GDM itself won't come up**: reboot, and at the systemd-boot menu pick
   an earlier generation (the ones from before niri was ever added are still
   there).
3. Plain `sudo nixos-rebuild switch` (no `--flake` flag) run from `/etc/nixos`
   still rebuilds the original, untouched, GNOME-only `/etc/nixos/configuration.nix`
   as a manual last resort, entirely independent of this flake.

## YubiKey (sudo / polkit)

Run `./enroll-yubikey.sh` once, after the first switch. `pam_u2f` is
configured with `control = "sufficient"`, so your password always still works
even without the key.
