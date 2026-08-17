#!/usr/bin/env bash
# Registers your YubiKey with pam_u2f for sudo + polkit prompts. Run this
# after `apply.sh` has switched you onto the new generation (it needs
# `pamu2fcfg`, which that generation installs). No sudo needed -- this only
# touches your own home directory. You'll need to touch the key when it
# blinks.
set -euo pipefail

mkdir -p "$HOME/.config/Yubico"
echo "Touch your YubiKey when it starts blinking..."
pamu2fcfg -o "pam://judy" -i "pam://judy" >> "$HOME/.config/Yubico/u2f_keys"
echo
echo "Registered. Current keys file:"
cat "$HOME/.config/Yubico/u2f_keys"
echo
echo "IMPORTANT: before trusting this, open a SEPARATE terminal (don't close"
echo "this one) and confirm both of these still work:"
echo "  sudo -k && sudo true      # try with the YubiKey touch"
echo "  sudo -k && sudo true      # try again, this time type your password instead"
