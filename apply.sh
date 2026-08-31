#!/usr/bin/env bash
# Activates a new generation. On the NixOS hosts that means `nixos-rebuild
# switch`, which is the one privileged step in this whole setup; on the hosts
# that get only standalone home-manager it means `home-manager switch`, which
# needs no root. Everything else (writing files, building, git init) was
# already done and needs no root either. Run this yourself so you get the sudo
# password prompt where there is one; full output also lands in switch.log next
# to this script either way.
#
# Defaults to the host it's run on, so this is safe to run from any machine in
# the flake; pass a name to build a different one -- `./apply.sh judy` for a
# NixOS host, `./apply.sh vx@vxdev` for a home-manager one.
set -euo pipefail
cd "$(dirname "$0")"

LOG="switch.log"

# Both branches below shell out to `nix`, and a non-interactive bash script
# inherits PATH from whatever launched it -- it reads neither
# /etc/profile.d/nix.sh (login shells) nor /etc/bash.bashrc (interactive ones).
# So `nix` is only on PATH here if the calling shell had it, which a fish that
# has not sourced the nix hook does not. Pin the default profile's bin dir for
# the same reason the NixOS branch below pins /run/wrappers/bin: so the script
# does not depend on the caller's environment.
if [[ -d /nix/var/nix/profiles/default/bin ]]; then
  PATH="/nix/var/nix/profiles/default/bin:${PATH}"
fi

# vxdev is Debian, not NixOS: there is no system generation to switch, so the
# flake exposes it under homeConfigurations and activation goes through
# home-manager. /etc/NIXOS is the marker the NixOS installer leaves, and it is
# what we branch on rather than `hostname` -- the VM answers to `vxsuite` while
# its flake attribute is `vx@vxdev`, so those two never line up.
if [[ ! -e /etc/NIXOS ]]; then
  # Capture only stdout: nix's warnings (a dirty git tree, most often) go to
  # stderr, and merging them in here would put them in the attribute list.
  if ! ATTRS_RAW="$(
    nix eval --raw '.#homeConfigurations' \
      --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)'
  )"; then
    echo "Could not read homeConfigurations from the flake (see nix output above)." >&2
    exit 1
  fi
  mapfile -t ATTRS <<<"${ATTRS_RAW}"

  # With a single entry there is nothing to disambiguate, so no argument is
  # needed; the hostname would not have identified it anyway.
  ATTR="${1:-}"
  if [[ -z "${ATTR}" && ${#ATTRS[@]} -eq 1 ]]; then
    ATTR="${ATTRS[0]}"
  fi

  if [[ -z "${ATTR}" ]] || ! printf '%s\n' "${ATTRS[@]}" | grep -qxF "${ATTR}"; then
    echo "Not a homeConfigurations entry: '${ATTR:-<none>}'. Available:" >&2
    printf '  %s\n' "${ATTRS[@]}" >&2
    exit 1
  fi

  # home-manager installs itself onto the profile, so the CLI is normally
  # right there. Fall back to the flake if a half-broken generation has left it
  # missing -- that is exactly when you need this script to still run.
  if command -v home-manager >/dev/null 2>&1; then
    HM=(home-manager)
  else
    HM=(nix run home-manager/master --)
  fi

  echo "Activating the new home-manager generation (${ATTR})..." | tee "${LOG}"
  "${HM[@]}" switch --flake ".#${ATTR}" 2>&1 | tee -a "${LOG}"
  echo "Done. Active generation: $(readlink ~/.local/state/nix/profiles/home-manager)" \
    | tee -a "${LOG}"
  exit 0
fi

# NixOS ships two sudos: the setuid wrapper in /run/wrappers/bin, and a plain
# non-setuid one in systemPackages at /run/current-system/sw/bin. Only PATH
# order decides which you get, and a shell that puts sw/bin first fails with
# "must be owned by uid 0 and have the setuid bit set" -- which looks alarming
# but just means the wrong sudo was found. Pin the wrapper dir first so this
# script works from any shell.
PATH="/run/wrappers/bin:$PATH"

HOST="${1:-$(hostname)}"

if ! nix eval --raw ".#nixosConfigurations.${HOST}.config.networking.hostName" >/dev/null 2>&1; then
  echo "No host '${HOST}' in this flake. Available:" >&2
  nix eval --json '.#nixosConfigurations' --apply builtins.attrNames 2>/dev/null >&2 || true
  exit 1
fi

echo "Switching to the new generation (host: ${HOST})..." | tee "${LOG}"
sudo nixos-rebuild switch --flake ".#${HOST}" 2>&1 | tee -a "${LOG}"
echo "Done. Active generation: $(readlink /nix/var/nix/profiles/system)" | tee -a "${LOG}"
