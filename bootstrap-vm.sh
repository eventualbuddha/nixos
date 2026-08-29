#!/usr/bin/env bash
# Bootstrap a fresh Debian 12 VM into the `vx@vxdev` home-manager config --
# the vxsuite build guest. Meant to be curl'd into a box that has nothing on it
# but a Debian install and a `vx` user:
#
#   curl -fsSL https://raw.githubusercontent.com/eventualbuddha/nixos/main/bootstrap-vm.sh | bash
#
# Re-running is safe: every step checks for its own result first and skips.
# Run with CHECK=1 to print what each step *would* do and change nothing.
#
# What this does NOT do, on purpose: the vmguard guest side (MITM CA into the
# trust store, /etc/profile.d/vmguard.sh, the apt proxy). That is `guest-setup.sh`
# on `work`, run as `just guest-setup` from hosts/work/vmguard/Justfile, and it
# needs the CA off the host -- which is not in this repo and must not be. This
# script detects whether that has happened and adapts; see step 2.
#
# WHERE THIS FITS in the vmguard provisioning order (Justfile header):
#
#     just net-up → just install → just firewall-open → just guest-setup
#         → *** this script, inside the guest ***  → just move-nic
#
# Anywhere after `guest-setup` works, on either side of `move-nic`. Everything
# this script fetches is allowlisted read-only in the egress filter: the four
# nixos.org hosts (NOTES 46, `egress_filter.py`), deb.debian.org and
# security.debian.org for apt, and github.com for the clone. Running it before
# `move-nic` on the NAT network works too, and needs no policy at all.
#
# The one hard ordering rule is `guest-setup` FIRST if the guest is already on
# the isolated net: without the MITM CA in the trust store and the proxy env it
# writes, nothing here can reach anything. Step 5 checks reachability before
# running the nix installer, so both that case and a lapsed allowlist fail with
# a reason rather than as a download timeout.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/eventualbuddha/nixos}"
REPO_REF="${REPO_REF:-main}"
REPO_DIR="${REPO_DIR:-$HOME/nixos}"
# The flake's homeConfigurations attribute, and the user it hardcodes. Both are
# set in hosts/vxdev/home.nix; changing one here without the other just moves
# the failure later.
HM_TARGET="${HM_TARGET:-vx@vxdev}"
TARGET_USER="${TARGET_USER:-vx}"
CHECK="${CHECK:-}"

step_n=0
step() { step_n=$((step_n + 1)); printf '\n\033[1;35m[%d/8]\033[0m %s\n' "$step_n" "$*"; }
say()  { printf '      %s\n' "$*"; }
skip() { printf '      \033[2m-- already done: %s\033[0m\n' "$*"; }
warn() { printf '      \033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Every mutating command goes through this, so CHECK=1 is honest rather than
# approximate: there is no second code path for it to drift away from.
run() {
  if [ -n "$CHECK" ]; then
    printf '      \033[2mwould run:\033[0m %s\n' "$*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
step "Preflight"

[ "$(id -u)" -ne 0 ] || die "run this as $TARGET_USER, not root -- it installs a *user's* home-manager
       config, and a root-owned ~/.nix-profile is tedious to unpick."

[ "$(id -un)" = "$TARGET_USER" ] || die "this must run as '$TARGET_USER' (you are '$(id -un)').
       hosts/vxdev/home.nix hardcodes home.username = \"$TARGET_USER\" and
       homeDirectory = \"/home/$TARGET_USER\"; home-manager refuses to activate
       a config whose username does not match the running user."

if [ -r /etc/os-release ]; then
  . /etc/os-release
  # Not fatal. Debian 12 is what this targets and what vxsuite assumes (see the
  # header of hosts/vxdev/home.nix), but nothing below is bookworm-specific
  # except the apt calls, so a different Debian is worth a warning, not a stop.
  [ "${ID:-}" = "debian" ] || warn "expected Debian, found '${ID:-unknown}' -- continuing anyway"
  [ "${VERSION_ID:-}" = "12" ] || warn "expected Debian 12, found '${VERSION_ID:-unknown}' -- continuing anyway"
fi

command -v sudo >/dev/null || die "sudo is not installed. As root: apt-get install -y sudo && adduser $TARGET_USER sudo"
say "user $TARGET_USER on ${PRETTY_NAME:-unknown OS}"

# ---------------------------------------------------------------------------
step "Passwordless sudo for $TARGET_USER"

SUDOERS="/etc/sudoers.d/$TARGET_USER"
if sudo -n true 2>/dev/null; then
  skip "sudo already runs without a password"
else
  say "you will be prompted for $TARGET_USER's password once, to write $SUDOERS"
  say "(sudo reads it from the terminal, so this works under curl | bash)"
  # Validated into a temp file and only then moved into place: a syntactically
  # bad file in /etc/sudoers.d locks *everyone* out of sudo, including the
  # session that would have to fix it. visudo -c is the whole safety net here.
  if [ -n "$CHECK" ]; then
    printf '      \033[2mwould write:\033[0m %s  (%s ALL=(ALL) NOPASSWD: ALL)\n' "$SUDOERS" "$TARGET_USER"
  else
    tmp="$(mktemp)"
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$TARGET_USER" > "$tmp"
    sudo visudo -cqf "$tmp" || { rm -f "$tmp"; die "generated sudoers file failed validation -- nothing was changed"; }
    sudo install -m 0440 -o root -g root "$tmp" "$SUDOERS"
    rm -f "$tmp"
    sudo -n true 2>/dev/null || die "wrote $SUDOERS but sudo still wants a password"
    say "wrote $SUDOERS"
  fi
fi

# The login-shell activation in hosts/vxdev/home.nix runs `sudo -n chsh`, so
# this step is a hard prerequisite for step 8 rather than a convenience.

# ---------------------------------------------------------------------------
step "Egress: vmguard proxy, if this guest is behind one"

PROXIED=""
if [ -r /etc/profile.d/vmguard.sh ]; then
  # Written by guest-setup.sh on `work`. Sourcing it here matters because this
  # script is not a login shell: without it curl, git and the nix installer all
  # have no route out on the isolated network.
  # shellcheck disable=SC1091
  . /etc/profile.d/vmguard.sh
  PROXIED="${https_proxy:-}"
  say "vmguard proxy in use: $PROXIED"

  # sudo strips proxy env from the environment it hands to apt, which is why
  # guest-setup.sh writes apt its own config. Without that file the apt step
  # below hangs until it times out, looking exactly like a dead network.
  if [ ! -r /etc/apt/apt.conf.d/00-vmguard-proxy ]; then
    warn "/etc/apt/apt.conf.d/00-vmguard-proxy is missing -- sudo strips proxy env,"
    warn "so apt has no egress. Step 4 passes the proxy to apt explicitly to work"
    warn "around it, but the real fix is running \`just guest-setup\` from work."
  fi
else
  say "no /etc/profile.d/vmguard.sh -- assuming direct internet (pre-move-nic, or not a vmguard guest)"
fi

# ---------------------------------------------------------------------------
step "Prerequisites from apt"

APT_OPTS=()
# Only when we have a proxy *and* apt has not been told about it independently;
# passing an empty proxy would otherwise override a working config with nothing.
if [ -n "$PROXIED" ] && [ ! -r /etc/apt/apt.conf.d/00-vmguard-proxy ]; then
  APT_OPTS=(-o "Acquire::http::Proxy=$PROXIED" -o "Acquire::https::Proxy=$PROXIED")
fi

# xz-utils is the one that is easy to miss: the nix installer downloads a
# .tar.xz and unpacks it with `tar -xJf`, so without xz it fails *after* the
# download and hash check, which reads as a corrupt tarball rather than a
# missing package.
missing=()
for p in curl git xz-utils ca-certificates; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed$" || missing+=("$p")
done
if [ ${#missing[@]} -eq 0 ]; then
  skip "curl git xz-utils ca-certificates all installed"
else
  say "installing: ${missing[*]}"
  run sudo apt-get "${APT_OPTS[@]}" update -qq
  run sudo DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -y -qq "${missing[@]}"
fi

# ---------------------------------------------------------------------------
step "Nix (multi-user)"

NIX_PROFILE_SH=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

if [ -e /nix/var/nix/profiles/default ]; then
  skip "nix is installed"
else
  # Check reachability before running the installer rather than after: this is
  # the failure the header warns about, and the installer's own error for it is
  # a download failure with no hint that an egress policy is responsible.
  for host in https://releases.nixos.org/ https://cache.nixos.org/nix-cache-info; do
    if [ -n "$CHECK" ]; then
      say "would check: $host"
    elif ! curl -fsS -o /dev/null --max-time 20 "$host"; then
      die "cannot reach $host.
       The nixos.org hosts are allowlisted read-only in the egress filter (NOTES 46),
       so on the isolated network this most likely means \`just guest-setup\` has not
       run here yet -- no MITM CA, no proxy env, no egress at all. If it has, check
       that the deployed addon on work matches hosts/work/vmguard/egress_filter.py
       (\`just denies\` will show the 403)."
    fi
  done

  say "installing nix (this pulls ~100MB and takes a couple of minutes)"
  # NIX_INSTALLER_YES because stdin is the script itself under `curl | bash`;
  # the installer's confirmation prompt would otherwise read the rest of this
  # file as its answer.
  # --daemon (multi-user) to match how this VM is already set up: root-owned
  # /nix, a nixbld group, and a nix-daemon unit -- which is also what makes the
  # proxy drop-in in the next step both possible and necessary.
  # --no-channel-add: this config is entirely flake-based, and a stale
  # nixpkgs-unstable channel is only a way to get confusing results later.
  if [ -n "$CHECK" ]; then
    say "would run: curl -L https://nixos.org/nix/install | NIX_INSTALLER_YES=1 sh -s -- --daemon --no-channel-add"
  else
    installer="$(mktemp)"
    curl -fsSL --max-time 120 -o "$installer" https://nixos.org/nix/install \
      || die "failed to download the nix installer"
    NIX_INSTALLER_YES=1 sh "$installer" --daemon --no-channel-add \
      || { rm -f "$installer"; die "nix installer failed"; }
    rm -f "$installer"
  fi
fi

# The installer edits /etc/profile.d and the shell rc files, none of which this
# already-running shell has read. Source it so the rest of the script has `nix`.
if [ -z "$CHECK" ]; then
  [ -r "$NIX_PROFILE_SH" ] || die "nix installed but $NIX_PROFILE_SH is missing"
  # shellcheck disable=SC1090
  . "$NIX_PROFILE_SH"
  command -v nix >/dev/null || die "nix is still not on PATH after sourcing $NIX_PROFILE_SH"
  say "nix $(nix --version | awk '{print $3}')"
fi

# Flakes for the user. Also passed explicitly on every nix call below, so the
# script works even on a box where this file is somehow not read -- this exists
# so that *interactive* use after the bootstrap works too.
if grep -qs "experimental-features" "$HOME/.config/nix/nix.conf"; then
  skip "flakes enabled in ~/.config/nix/nix.conf"
else
  run mkdir -p "$HOME/.config/nix"
  if [ -n "$CHECK" ]; then
    say "would add 'experimental-features = nix-command flakes' to ~/.config/nix/nix.conf"
  else
    echo "experimental-features = nix-command flakes" >> "$HOME/.config/nix/nix.conf"
    say "enabled flakes in ~/.config/nix/nix.conf"
  fi
fi

# ---------------------------------------------------------------------------
step "Teach nix-daemon about the proxy"

# The piece that is invisible until it bites. On a multi-user install the
# *daemon* does all substituter traffic, and systemd units inherit none of the
# shell's environment -- so with vmguard in play and no drop-in, every user-side
# proxy variable is set correctly and nix still cannot reach cache.nixos.org.
# It fails as a download timeout with nothing pointing at the cause.
#
# This VM has had this file since its own setup, hand-written and recorded
# nowhere in this repo. That is exactly why it is here.
DROPIN_DIR=/etc/systemd/system/nix-daemon.service.d
DROPIN="$DROPIN_DIR/override.conf"

if [ -z "$PROXIED" ]; then
  say "no proxy in use -- nix-daemon needs no drop-in"
  # Deliberately not removing an existing one: a guest bootstrapped before
  # `move-nic` has no proxy *yet* and will need the drop-in the moment it moves.
elif [ -r "$DROPIN" ] && grep -qF "$PROXIED" "$DROPIN" 2>/dev/null; then
  skip "$DROPIN already points at $PROXIED"
else
  say "writing $DROPIN"
  if [ -n "$CHECK" ]; then
    say "would write the proxy Environment= lines and restart nix-daemon"
  else
    sudo mkdir -p "$DROPIN_DIR"
    # Both cases: some tools read the lowercase names, some the uppercase, and
    # nix has historically read either depending on the code path.
    sudo tee "$DROPIN" >/dev/null <<EOF
# Written by bootstrap-vm.sh. The nix daemon does all substituter traffic on a
# multi-user install, and inherits none of the shell's environment -- without
# this it cannot reach cache.nixos.org through the vmguard proxy.
[Service]
Environment=http_proxy=$PROXIED
Environment=https_proxy=$PROXIED
Environment=no_proxy=${no_proxy:-localhost,127.0.0.1,::1}
Environment=HTTP_PROXY=$PROXIED
Environment=HTTPS_PROXY=$PROXIED
Environment=NO_PROXY=${NO_PROXY:-localhost,127.0.0.1,::1}
EOF
    sudo systemctl daemon-reload
    sudo systemctl restart nix-daemon
    say "nix-daemon restarted with proxy environment"
  fi
fi

# ---------------------------------------------------------------------------
step "Clone $REPO_URL"

if [ -d "$REPO_DIR/.git" ]; then
  if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
    # Not touching a dirty tree. Re-running the bootstrap on a machine someone
    # has been editing should activate what is there, not silently discard it.
    warn "$REPO_DIR has uncommitted changes -- leaving it exactly as it is"
  else
    say "updating existing checkout"
    run git -C "$REPO_DIR" fetch --quiet origin "$REPO_REF"
    run git -C "$REPO_DIR" checkout --quiet "$REPO_REF"
    run git -C "$REPO_DIR" merge --quiet --ff-only "origin/$REPO_REF"
  fi
else
  say "cloning into $REPO_DIR"
  run git clone --quiet --branch "$REPO_REF" "$REPO_URL" "$REPO_DIR"
fi

# ---------------------------------------------------------------------------
step "Activate the home-manager config ($HM_TARGET)"

if [ -n "$CHECK" ]; then
  say "would build .#homeConfigurations.\"$HM_TARGET\".activationPackage and run its activate"
  say "would move aside any pre-existing dotfile it wants to own"
  printf '\n\033[1;32mCHECK complete\033[0m -- nothing was changed.\n'
  exit 0
fi

NIX_FLAGS=(--extra-experimental-features "nix-command flakes")

say "building (first run compiles nothing but downloads a lot; several minutes)"
nix "${NIX_FLAGS[@]}" build --no-link \
  "$REPO_DIR#homeConfigurations.\"$HM_TARGET\".activationPackage" \
  || die "build failed -- nothing has been activated, the box is as it was"

ACT="$(nix "${NIX_FLAGS[@]}" eval --raw "$REPO_DIR#homeConfigurations.\"$HM_TARGET\".activationPackage")"

# home-manager refuses to activate when a file it manages already exists as a
# real file, and a stock Debian home has several of exactly those (.bashrc,
# .profile, .bash_logout from /etc/skel). The `home-manager` CLI's -b flag
# handles this, but using the CLI means `nix run home-manager/master`, whose
# version is unrelated to the home-manager this flake pins in flake.lock.
# Enumerating the tree the activation package will link and moving those
# specific files aside keeps the pinned version and needs no CLI at all.
if [ -d "$ACT/home-files" ]; then
  moved=0
  while IFS= read -r rel; do
    target="$HOME/${rel#./}"
    # -L first: home-manager's own symlinks from a previous generation are
    # expected and must not be "backed up" into a pile of dead copies.
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      mv -f "$target" "$target.pre-home-manager"
      say "moved aside ~/${rel#./} -> ~/${rel#./}.pre-home-manager"
      moved=$((moved + 1))
    fi
  done < <(cd "$ACT/home-files" && find . -mindepth 1 \( -type f -o -type l \) -printf '%P\n')
  [ "$moved" -eq 0 ] && say "no pre-existing dotfiles in the way"
fi

say "activating"
"$ACT/activate"

# ---------------------------------------------------------------------------
printf '\n\033[1;32mDone.\033[0m\n\n'
say "login shell: $(getent passwd "$TARGET_USER" | cut -d: -f7)"
say "  (set by the setLoginShell activation in hosts/vxdev/home.nix, which is"
say "   why passwordless sudo had to come first -- it runs 'sudo -n chsh')"
printf '\n'
say "Open a new login shell to land in it. Then, still to do by hand:"
say "  1. claude /login          -- the guest holds its own subscription token"
say "  2. just move-nic          -- on work, if this guest is still on the NAT net"
say "  3. clone vxsuite into ~/code/vxsuite; \`wt\` and 10-vendor-tools.fish assume it"
printf '\n'
