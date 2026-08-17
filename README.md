# judy

NixOS flake for host `judy`: niri + ghostty + noctalia, with GNOME kept as a
fully-working fallback session.

## Applying changes

```
nixos-rebuild build --flake .#judy   # no root needed, just evaluates/builds
sudo nixos-rebuild switch --flake .#judy   # or: ./apply.sh
```

## If niri doesn't work out

1. **Easiest**: log out, and on the GDM login screen pick "GNOME" from the
   session dropdown instead of "niri". Nothing about GNOME/GDM was touched by
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
