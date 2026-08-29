#!/usr/bin/env bash
# The one privileged step in this whole setup: activates the new NixOS
# generation. Everything else (writing files, `nixos-rebuild build`, git init)
# doesn't need root and was already done. Run this yourself so you get the
# sudo password prompt; full output also lands in switch.log next to this
# script either way.
#
# Defaults to the host it's run on, so this is safe to run from any machine in
# the flake; pass a name (`./apply.sh judy`) to build a different one.
set -euo pipefail
cd "$(dirname "$0")"

HOST="${1:-$(hostname)}"

# NixOS ships two sudos: the setuid wrapper in /run/wrappers/bin, and a plain
# non-setuid one in systemPackages at /run/current-system/sw/bin. Only PATH
# order decides which you get, and a shell that puts sw/bin first fails with
# "must be owned by uid 0 and have the setuid bit set" -- which looks alarming
# but just means the wrong sudo was found. Pin the wrapper dir first so this
# script works from any shell.
PATH="/run/wrappers/bin:$PATH"

if ! nix eval --raw ".#nixosConfigurations.${HOST}.config.networking.hostName" >/dev/null 2>&1; then
  echo "No host '${HOST}' in this flake. Available:" >&2
  nix eval --json '.#nixosConfigurations' --apply builtins.attrNames 2>/dev/null >&2 || true
  exit 1
fi

LOG="switch.log"
echo "Switching to the new generation (host: ${HOST})..." | tee "$LOG"
sudo nixos-rebuild switch --flake ".#${HOST}" 2>&1 | tee -a "$LOG"
echo "Done. Active generation: $(readlink /nix/var/nix/profiles/system)" | tee -a "$LOG"
