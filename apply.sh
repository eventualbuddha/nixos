#!/usr/bin/env bash
# The one privileged step in this whole setup: activates the new NixOS
# generation. Everything else (writing files, `nixos-rebuild build`, git init)
# doesn't need root and was already done. Run this yourself so you get the
# sudo password prompt; full output also lands in switch.log next to this
# script either way.
set -euo pipefail
cd "$(dirname "$0")"

LOG="switch.log"
echo "Switching to the niri/ghostty/noctalia generation (host: judy)..." | tee "$LOG"
sudo nixos-rebuild switch --flake ".#judy" 2>&1 | tee -a "$LOG"
echo "Done. Active generation: $(readlink /nix/var/nix/profiles/system)" | tee -a "$LOG"
echo "Log out and check the GDM session picker for 'niri' next to 'GNOME'."
