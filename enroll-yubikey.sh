#!/usr/bin/env bash
# Registers your YubiKey with pam_u2f for sudo + polkit prompts. Run this
# after `apply.sh` has switched you onto the new generation (it needs
# `pamu2fcfg`, which that generation installs). No sudo needed -- this only
# touches your own home directory. You'll need to touch the key when it
# blinks.
#
# The origin follows the hostname, because that is what pam_u2f looks up:
# with `security.pam.u2f.settings.origin` unset (it is), pam_u2f defaults to
# "pam://$HOSTNAME". Enrolling under a different origin than the machine you
# are on produces a credential PAM never matches -- and since control is
# "sufficient", that fails *silently* back to the password prompt, which looks
# exactly like the enrollment simply not taking. So each machine needs its own
# enrollment; ~/.config/Yubico/u2f_keys is local to the machine anyway.
#
# Safe to re-run, for a second YubiKey or a replacement. pam_u2f reads only the
# first line matching the user, so additional credentials have to be appended
# onto that same line (colon-separated), not added as new lines:
#   <username>:<KeyHandle1>,<UserKey1>,<CoseType1>,<Options1>:<KeyHandle2>,...
set -euo pipefail

ME="$(id -un)"
ORIGIN="pam://$(hostname)"
KEYS="${XDG_CONFIG_HOME:-$HOME/.config}/Yubico/u2f_keys"

command -v pamu2fcfg >/dev/null || {
  echo "error: pamu2fcfg not found -- run ./apply.sh first" >&2
  exit 1
}

mkdir -p "$(dirname "$KEYS")"

echo "Enrolling for origin: ${ORIGIN}"
echo "Touch your YubiKey when it starts blinking..."

if [ -s "$KEYS" ] && grep -q "^${ME}:" "$KEYS"; then
  echo "(existing enrollment found -- adding this key as an additional credential)"
  # -n prints just the registration info. Normalise the leading separator so
  # this is correct whether or not pamu2fcfg emits one.
  add="$(pamu2fcfg -n -o "$ORIGIN" -i "$ORIGIN")"
  add=":${add#:}"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  awk -v user="$ME" -v add="$add" -F: '
    $1 == user && !seen { printf "%s%s\n", $0, add; seen = 1; next }
    { print }
  ' "$KEYS" >"$tmp"
  cat "$tmp" >"$KEYS"
else
  pamu2fcfg -o "$ORIGIN" -i "$ORIGIN" >>"$KEYS"
fi

chmod 600 "$KEYS"

echo
echo "Registered. Current keys file ($KEYS):"
cat "$KEYS"
echo
echo "IMPORTANT: before trusting this, open a SEPARATE terminal (don't close"
echo "this one) and confirm both of these still work:"
echo "  sudo -k && sudo true      # try with the YubiKey touch"
echo "  sudo -k && sudo true      # try again, this time type your password instead"
