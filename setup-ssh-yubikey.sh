#!/usr/bin/env bash
# Enrolls a YubiKey-backed (FIDO2 "sk") SSH key on a remote host, so you can log
# in there with a touch instead of a password. No sudo needed.
#
# Usage: ./setup-ssh-yubikey.sh <user@host>
#   e.g. ./setup-ssh-yubikey.sh brian@fedora
#
# Safe to re-run. First host, a new host, or the same host again because you
# forgot all converge on the same end state. Every run re-checks that the local
# key still corresponds to a credential on the YubiKey that is plugged in right
# now, and re-enrolls only if it doesn't.
#
# Touch-only by design: no FIDO PIN is set, and -O verify-required is
# deliberately NOT used, so `ssh` asks for a tap and nothing else. The tradeoff
# is real -- whoever physically holds the YubiKey can use this key.
#
# Deliberately NOT resident. A resident (discoverable) credential is stored on
# the token and identified by (application, username) -- and ssh-keygen defaults
# those to "ssh:" and an empty username. So every resident key generated with
# the defaults REPLACES the previous one. That is not hypothetical: it silently
# destroyed the git signing credential for ~/.ssh/id_ed25519_sign_sk, twice,
# because both keys claimed the same (application, username) pair.
#
# Resident's only payoff is `ssh-keygen -K`, which re-downloads credentials onto
# a fresh machine with no file to copy. That needs a FIDO PIN to enumerate, and
# this touch-only setup deliberately has none -- so resident cost a working key
# and bought nothing.
#
# Non-resident means the token stores nothing per key: ~/.ssh/id_ed25519_sk
# holds an encrypted key handle that the token unwraps in order to sign. Keep
# that file. Without it the key is unusable even with the YubiKey in hand, so
# moving to a new machine means copying it across.
set -euo pipefail

KEY="$HOME/.ssh/id_ed25519_sk"
PROBE_TIMEOUT=2 # a missing credential fails in well under a second

die() {
  echo "error: $*" >&2
  exit 1
}

# Is a FIDO/U2F security token plugged in? This has to be answered *before*
# probing the key: an unplugged YubiKey reports the same "device not found" as a
# credential that no longer exists, and mistaking one for the other would throw
# away a perfectly good key.
token_present() {
  local h
  for h in /dev/hidraw*; do
    [ -e "$h" ] || continue
    if udevadm info -q property -n "$h" 2>/dev/null | grep -q '^ID_SECURITY_TOKEN=1'; then
      return 0
    fi
  done
  return 1
}

# Does the connected YubiKey still hold the credential this key file refers to?
#
# Answered without spending a touch. ssh-keygen probes the token for the
# credential before it ever asks for user presence, so a credential the token no
# longer honours -- evicted by a colliding resident key, wiped by a
# `ykman fido reset`, or simply belonging to a different YubiKey -- reports
# "device not found" almost immediately. A credential that is still there
# instead blocks waiting for a tap, which we take as proof of life and cut short
# via `timeout`.
#
# SSH_AUTH_SOCK is cleared so we talk to the device rather than to an agent, and
# SSH_ASKPASS_REQUIRE=never keeps the presence prompt on the terminal instead of
# flashing a GUI dialog that vanishes the moment the probe fails.
credential_is_live() {
  local dir out rc
  dir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" RETURN
  echo probe >"$dir/msg"

  set +e
  out=$(timeout "$PROBE_TIMEOUT" \
    env -u SSH_AUTH_SOCK SSH_ASKPASS_REQUIRE=never \
    ssh-keygen -Y sign -f "$KEY" -n probe "$dir/msg" 2>&1)
  rc=$?
  set -e

  # Timed out waiting for a tap, or the tap actually landed: credential exists.
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ]; then
    return 0
  fi
  if grep -qi 'device not found\|no FIDO SecurityKeyProvider\|key not found' <<<"$out"; then
    return 1
  fi

  # Anything else is unexpected. Treat it as live rather than silently
  # destroying a key on an error we don't understand.
  echo "warning: could not verify the key against the YubiKey:" >&2
  sed 's/^/  /' <<<"$out" >&2
  echo "warning: assuming it is still good; re-run after unplugging/replugging if ssh fails." >&2
  return 0
}

generate_key() {
  echo "Generating a YubiKey-backed FIDO2 SSH key -- touch your YubiKey when it blinks..."
  # -N "": the on-disk file is only a key handle, the real secret never leaves
  # the token, so a passphrase here would add a prompt without adding protection.
  ssh-keygen -t ed25519-sk -N "" -f "$KEY" -C "$(id -un)@$(hostname)"
}

# Move a dead key aside rather than deleting it, so a misdiagnosis is recoverable.
archive_key() {
  local stamp suffix
  stamp=$(date +%Y%m%d-%H%M%S)
  suffix="stale-$stamp"
  [ -f "$KEY" ] && mv "$KEY" "$KEY.$suffix"
  [ -f "$KEY.pub" ] && mv "$KEY.pub" "$KEY.pub.$suffix"
  echo "  (previous key saved as $(basename "$KEY").$suffix)"
}

[ $# -eq 1 ] || die "usage: $0 <user@host>"
TARGET="$1"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

token_present || die "no FIDO security token detected -- plug in your YubiKey and re-run."

# 1. Decide whether we can reuse what is already on disk.
if [ -f "$KEY" ]; then
  # A stub with no .pub is recoverable: the public half derives from it.
  if [ ! -f "$KEY.pub" ]; then
    echo "Public key missing; regenerating it from $KEY..."
    ssh-keygen -y -f "$KEY" >"$KEY.pub"
  fi

  echo "Checking that $KEY still matches the connected YubiKey (no touch needed)..."
  if credential_is_live; then
    echo "  OK -- existing key is still valid on this YubiKey."
  else
    echo "  This key's credential is NOT on the connected YubiKey."
    echo "  (it was evicted or reset, or this is a different YubiKey)"
    archive_key
    generate_key
    REENROLLED=1
  fi
elif [ -f "$KEY.pub" ]; then
  # Orphaned public key with no stub: unusable, nothing to verify against.
  echo "Found $KEY.pub but no private key; it cannot be used."
  archive_key
  generate_key
  REENROLLED=1
else
  generate_key
fi

# 2. Install the public key remotely. ssh-copy-id skips keys already present, so
#    re-running against the same host is a no-op.
echo
echo "Copying the public key to $TARGET (you may need your password there once)..."
ssh-copy-id -i "${KEY}.pub" "$TARGET"

echo
echo "Done. Test it:"
echo "  ssh $TARGET"
echo "You should be prompted to touch your YubiKey instead of typing a password."

if [ -n "${REENROLLED:-}" ]; then
  echo
  echo "NOTE: this run created a NEW key, so the old public key is now dead."
  echo "      Remove the stale line from ~/.ssh/authorized_keys on any OTHER"
  echo "      host you had previously enrolled, and re-run this script for each."
fi
