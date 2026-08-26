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
home/                     # home-manager, user "brian", shared across hosts
  niri.nix                # compositor settings, keybinds, window rules
  noctalia.nix            # shell/bar config
  terminal.nix            # ghostty
  editor.nix              # neovim + LazyVim bootstrap
  dev.nix                 # git/signing + rust/node/dev CLI tooling
  shell.nix               # fish + starship
  apps.nix                # browsers, chat, CLI utilities
  theme.nix               # gtk/cursor theme
  tunnels.nix             # socket-activated SSH forwards
```

Adding a new machine: run `nixos-generate-config`, drop the two files under
`hosts/<name>/`, add `<name> = mkHost "<name>";` in `flake.nix`. Everything in
`hosts/common.nix` and `home/` applies automatically.

## Applying changes

```
nixos-rebuild build --flake .#<host>          # no root needed, just evaluates/builds
sudo nixos-rebuild switch --flake .#<host>    # or: ./apply.sh
```

`./apply.sh` builds the host it is run on. Pass a name (`./apply.sh judy`) to
build a different one.

## If niri doesn't work out

1. **Easiest**: log out, and on the GDM login screen pick "GNOME" from the
   session dropdown instead of "niri". Nothing about GNOME/GDM is touched by
   this config -- it's the exact same session that was there before.
2. **If GDM itself won't come up**: reboot, and at the systemd-boot menu pick
   an earlier generation (on judy, that includes the ones from before niri was
   ever added).
3. **judy only**: plain `sudo nixos-rebuild switch` (no `--flake` flag) run from
   `/etc/nixos` still rebuilds the original, untouched, GNOME-only
   `/etc/nixos/configuration.nix` as a manual last resort, entirely independent
   of this flake. Machines installed straight from this flake (work) have no
   such file -- `/etc/nixos` is empty there, so only 1 and 2 apply.

## YubiKey (sudo / polkit)

Run `./enroll-yubikey.sh` once per machine, after the first switch. `pam_u2f`
is configured with `control = "sufficient"`, so your password always still
works even without the key.

Per machine, not once ever: the script enrolls against `pam://$HOSTNAME`,
which is what `pam_u2f` looks up when `security.pam.u2f.settings.origin` is
unset. A credential enrolled under another host's origin is simply never
matched, and because the control is `sufficient` that failure is silent -- it
falls back to the password prompt, which looks exactly like the enrollment not
having taken.

## Git commit signing

Commits are signed with a YubiKey-backed SSH key, per machine. The key is
non-resident, so `~/.ssh/id_ed25519_sign_sk` is the **only** copy -- it cannot
be re-downloaded from the token (`ssh-keygen -K` needs a FIDO PIN, and this
setup is touch-only by design). Back that file up.

Setting up a new machine:

```
ssh-keygen -t ed25519-sk -f ~/.ssh/id_ed25519_sign_sk -C "<email> (git signing, <host>)"
```

Then add the `.pub` line to `signingKeys` in `home/dev.nix` and re-apply, and
register it at https://github.com/settings/keys as a **Signing Key** (not an
Authentication Key -- GitHub treats those as distinct roles). Every machine
trusts every key in that list, which is what lets `git log --show-signature`
verify commits made on the other machine.
