#!/usr/bin/env bash
# Generates a YubiKey-backed (FIDO2 "sk") SSH key, then copies the public
# half to a remote host so you can log in there with a touch instead of a
# password. No sudo needed.
#
# Usage: ./setup-ssh-yubikey.sh <user@host>
#   e.g. ./setup-ssh-yubikey.sh brian@fedora
#
# The key is "resident" (-O resident): the credential itself lives on the
# YubiKey, not just a handle to it -- so on a brand new machine you can
# recreate the local stub file with `ssh-keygen -K` instead of copying
# ~/.ssh/id_ed25519_sk around. No PIN is required (touch-only), matching
# the low-friction sudo/polkit setup from enroll-yubikey.sh.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <user@host>" >&2
  exit 1
fi

TARGET="$1"
KEY="$HOME/.ssh/id_ed25519_sk"

if [ ! -f "$KEY" ]; then
  echo "Generating a resident FIDO2 SSH key -- touch your YubiKey when it blinks..."
  ssh-keygen -t ed25519-sk -O resident -f "$KEY" -C "brian@$(hostname)"
else
  echo "Using existing key: $KEY"
fi

echo
echo "Copying the public key to $TARGET (you'll need your password there once)..."
ssh-copy-id -i "${KEY}.pub" "$TARGET"

echo
echo "Done. Test it:"
echo "  ssh $TARGET"
echo "You should be prompted to touch your YubiKey instead of typing a password."
