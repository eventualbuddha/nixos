#!/usr/bin/env bash
# Move the vxsuite guest's /home onto a btrfs volume, so that `ctree` can
# make worktrees by reflinking instead of copying. Runs *in the guest*, as root.
# The host side is `add-home-disk.sh` on `work`, which must have run first.
#
#   ./migrate-home-btrfs.sh
#
# Re-running is safe: every step checks for its own result first and skips, and
# the copy step is an rsync, so a second run is a cheap delta rather than a
# repeat. Run with CHECK=1 to print what each step *would* do and change
# nothing (the copy step runs rsync with -n, so you get the real file list).
#
# WHAT THIS FIXES. vda1 is 195G at 97% full with 6.9G left, and 141G of that is
# /home. Moving /home off it drops the root to ~37G used *and* puts the
# worktrees on a filesystem that can reflink. `proj` keeps worktrees at
# ~/projects/<project>/<workstream>, cloned from ~/code/vxsuite; reflink needs
# source and destination on one filesystem, and moving all of /home is the
# simplest way to guarantee that.
#
# WHAT THIS DOES NOT DO, on purpose:
#
#   - It does not delete the old /home. After a clean boot on the new volume
#     the old copy is still sitting on vda1, invisible under the new mount, and
#     removing it is a one-liner you run when you are ready, which the closing
#     notes print. Until then this whole migration is undoable by commenting
#     out one fstab line.
#
#   - It does not dedupe what it copies. rsync writes every existing worktree
#     out at full size, so ~/projects is 69G before and 69G after. The saving
#     is on worktrees created *from now on*: a reflinked clone of a ~3G
#     workstream costs nearly nothing. To collect it on the trees that already
#     exist, either re-create them with `ctree` once, or run `duperemove -dr
#     ~/projects` afterwards.
#
#   - It does not set `chattr +C` on anything. That is correct on the *host*
#     for the qcow2 images (see add-home-disk.sh) but here it would disable the
#     reflinks this is all for.
set -euo pipefail

DISK="${DISK:-/dev/vdb}"
LABEL="${LABEL:-vxhome}"
SUBVOL="${SUBVOL:-@home}"
MNT="${MNT:-/mnt/newhome}"
# noatime: a build tree is millions of files nobody reads atimes off.
# compress=zstd:1: the host images directory is nodatacow, which also means the
#   host does not compress it, so this is the only compression in the stack.
#   Level 1 because this is build output being written constantly, not an
#   archive. discard=async: returns freed space to the sparse qcow2, which is
#   the other half of discard='unmap' on the host's disk definition.
MOUNT_OPTS="${MOUNT_OPTS:-noatime,compress=zstd:1,discard=async,subvol=$SUBVOL}"
CHECK="${CHECK:-}"
FORCE="${FORCE:-}"

step_n=0
step() { step_n=$((step_n + 1)); printf '\n\033[1;35m[%d/9]\033[0m %s\n' "$step_n" "$*"; }
say()  { printf '      %s\n' "$*"; }
skip() { printf '      \033[2m-- already done: %s\033[0m\n' "$*"; }
warn() { printf '      \033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

run() {
  if [ -n "$CHECK" ]; then
    printf '      \033[2mwould run:\033[0m %s\n' "$*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
step "Preflight"

[ "$(id -u)" -eq 0 ] || die "run this as root. It replaces /home while nothing is using it,
       which a shell whose own \$HOME is under /home cannot do."

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "debian" ] || warn "expected Debian, found '${ID:-unknown}' -- continuing anyway"
fi

for t in blkid findmnt blockdev; do
  command -v "$t" >/dev/null || die "$t not found -- that is util-linux, which should not be missing
       on a Debian this script can run on at all. Something is wrong with the box."
done

# If /home is already its own mount, either this has run before or the layout
# is not what this script was written against. Either way, stop and look.
if findmnt -n /home >/dev/null 2>&1; then
  CURRENT_SRC="$(findmnt -n -o SOURCE /home)"
  CURRENT_FS="$(findmnt -n -o FSTYPE /home)"
  if [ "$CURRENT_FS" = "btrfs" ]; then
    printf '\n\033[1;32mNothing to do.\033[0m\n\n'
    say "/home is already btrfs, on $CURRENT_SRC:"
    btrfs filesystem usage /home 2>/dev/null | sed 's/^/      /' || true
    printf '\n'
    exit 0
  fi
  die "/home is already a separate mount ($CURRENT_SRC, $CURRENT_FS), which is not
       the layout this expects (/home as a directory on the ext4 root). Sort out
       what is there before running this."
fi

HOME_KB="$(du -sxk /home | awk '{print $1}')"
say "/home is $(( HOME_KB / 1024 / 1024 ))G on $(findmnt -n -o SOURCE /)"

# ---------------------------------------------------------------------------
step "Prerequisites from apt"

# btrfs-progs is already here on this guest; rsync is not, and without this step
# that surfaces in the copy step rather than in preflight. Both are cheap, and
# deb.debian.org is allowlisted in the egress filter (see the header of
# bootstrap-vm.sh), so this works on the isolated network too.
APT_OPTS=()
if [ -r /etc/profile.d/vmguard.sh ]; then
  # Same wrinkle bootstrap-vm.sh documents: sudo strips proxy env, and this
  # script runs as root, so apt needs to be told about the proxy explicitly
  # unless guest-setup.sh has already written it its own config.
  # shellcheck disable=SC1091
  . /etc/profile.d/vmguard.sh
  if [ -n "${https_proxy:-}" ] && [ ! -r /etc/apt/apt.conf.d/00-vmguard-proxy ]; then
    APT_OPTS=(-o "Acquire::http::Proxy=$https_proxy" -o "Acquire::https::Proxy=$https_proxy")
    say "passing the vmguard proxy to apt explicitly"
  fi
fi

missing=()
for p in rsync btrfs-progs; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed$" || missing+=("$p")
done
if [ "${#missing[@]}" -eq 0 ]; then
  skip "rsync and btrfs-progs are installed"
else
  say "installing: ${missing[*]}"
  run apt-get "${APT_OPTS[@]}" update -qq
  run DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -y -qq "${missing[@]}"
fi

for t in rsync mkfs.btrfs btrfs; do
  command -v "$t" >/dev/null || [ -n "$CHECK" ] \
    || die "$t still not on PATH after installing ${missing[*]:-nothing}"
done

# ---------------------------------------------------------------------------
step "The new disk"

[ -b "$DISK" ] || die "$DISK is not a block device.
       Run add-home-disk.sh on \`work\` first, then cold-start the guest --
       \`virsh shutdown vxsuite && virsh start vxsuite\`. A reboot from inside the
       guest does not make libvirt re-read the domain XML, so if you rebooted
       rather than power-cycled, that is why this disk is missing."

EXISTING_LABEL="$(blkid -o value -s LABEL "$DISK" 2>/dev/null || true)"
EXISTING_TYPE="$(blkid -o value -s TYPE "$DISK" 2>/dev/null || true)"

if [ -z "$EXISTING_TYPE" ]; then
  say "$DISK is blank, $(blockdev --getsize64 "$DISK" | awk '{printf "%dG", $1/1024/1024/1024}')"
  NEEDS_MKFS=1
elif [ "$EXISTING_TYPE" = "btrfs" ] && [ "$EXISTING_LABEL" = "$LABEL" ]; then
  skip "$DISK is already btrfs labelled '$LABEL' -- resuming"
  NEEDS_MKFS=""
else
  die "$DISK already holds a $EXISTING_TYPE filesystem labelled '${EXISTING_LABEL:-<none>}'.
       Refusing to overwrite it. If it really is scratch: wipefs -a $DISK"
fi

DISK_KB="$(( $(blockdev --getsize64 "$DISK") / 1024 ))"
# Not an exact science -- btrfs metadata and zstd pull in opposite directions --
# but a disk smaller than the data is worth catching before the copy, not during.
[ "$DISK_KB" -gt "$HOME_KB" ] \
  || die "$DISK is smaller than /home. Grow the image on the host (qemu-img resize)
       before going further."

# ---------------------------------------------------------------------------
step "Nothing may be using /home"

# rsync of a tree that is being written underneath it produces a copy that is
# subtly not the tree -- a half-written build, a database mid-transaction. The
# check is advisory (FORCE=1 overrides) because the list is never quite
# complete, but it catches the case that actually happens: a forgotten shell,
# or an editor, still open as vx.
busy=()
for procdir in /proc/[0-9]*; do
  pid="${procdir#/proc/}"
  [ "$pid" = "$$" ] && continue
  for link in "$procdir/cwd" "$procdir/exe" "$procdir/root" "$procdir"/fd/*; do
    target="$(readlink "$link" 2>/dev/null)" || continue
    case "$target" in
      /home/*)
        busy+=("$pid $(tr -d '\0' < "$procdir/comm" 2>/dev/null) -> $target")
        break
        ;;
    esac
  done
done

if [ "${#busy[@]}" -eq 0 ]; then
  say "no process has anything under /home open"
else
  say "these processes are using /home:"
  printf '        %s\n' "${busy[@]}" | head -20
  [ "${#busy[@]}" -gt 20 ] && say "        ... and $(( ${#busy[@]} - 20 )) more"
  if [ -n "$FORCE" ]; then
    warn "FORCE=1 set -- continuing anyway. The copy may be inconsistent."
  else
    die "log out every vx session (including editors, language servers, and
       anything claude or vscode left running) and try again, or set FORCE=1 if
       you are sure none of them are writing.
       From the host:  virsh console vxsuite   gets you a root tty with no vx
       session attached."
  fi
fi

# ---------------------------------------------------------------------------
step "Filesystem and subvolume"

if [ -n "$NEEDS_MKFS" ]; then
  run mkfs.btrfs -L "$LABEL" "$DISK"
  [ -n "$CHECK" ] || say "made a btrfs filesystem labelled '$LABEL'"
else
  skip "filesystem exists"
fi

# The top level of a btrfs filesystem is mountable, but putting /home in a
# subvolume rather than at the root keeps snapshots available later: you can
# snapshot @home without the snapshots themselves living inside what you are
# snapshotting.
if [ -n "$CHECK" ] && [ -n "$NEEDS_MKFS" ]; then
  say "would create subvolume $SUBVOL"
else
  run mkdir -p "$MNT"
  TOP="$(mktemp -d)"
  run mount "$DISK" "$TOP"
  if [ -n "$CHECK" ]; then
    say "would create subvolume $SUBVOL"
  elif btrfs subvolume show "$TOP/$SUBVOL" >/dev/null 2>&1; then
    skip "subvolume $SUBVOL exists"
  else
    btrfs subvolume create "$TOP/$SUBVOL"
    say "created subvolume $SUBVOL"
  fi
  run umount "$TOP"
  rmdir "$TOP" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
step "Mount it at $MNT"

run mkdir -p "$MNT"
if findmnt -n "$MNT" >/dev/null 2>&1; then
  skip "$MNT is mounted"
else
  run mount -o "$MOUNT_OPTS" "$DISK" "$MNT"
  say "mount options: $MOUNT_OPTS"
fi

if [ -z "$CHECK" ]; then
  AVAIL_KB="$(df -Pk "$MNT" | awk 'NR==2 {print $4}')"
  say "$(( AVAIL_KB / 1024 / 1024 ))G available for a $(( HOME_KB / 1024 / 1024 ))G copy"
fi

# ---------------------------------------------------------------------------
step "Copy /home across"

# -H is the flag that matters and the one it is fatal to forget. pnpm's store
# at ~/.local/share/pnpm/store/v10 is hardlinked into every node_modules in
# every worktree; all node_modules across the whole box come to 7.4G because of
# it. Without -H rsync writes each link as its own file and that 7.4G becomes
# tens of gigabytes, which is how a migration meant to save space runs the new
# disk out of it.
# -A -X: ACLs and xattrs. -x: stay on the root filesystem, so the virtiofs
# mounts under /vx and anything else mounted later are not swept in.
# --delete so that a re-run after a partial copy converges rather than
# accumulating; safe because $MNT is only ever written by this script.
RSYNC_ARGS=(-aHAXx --delete --info=progress2 --human-readable /home/ "$MNT/")
if [ -n "$CHECK" ]; then
  say "would run: rsync ${RSYNC_ARGS[*]}"
  # Only worth showing the real file list if the destination is actually there.
  # Under CHECK the mount above was printed rather than performed, so on a first
  # run it is not -- and an rsync -n against a path that does not exist fails
  # with an error that reads like a bug in this script rather than the expected
  # result of asking it to change nothing.
  if findmnt -n "$MNT" >/dev/null 2>&1; then
    say "running it with -n instead, to show what it would transfer:"
    rsync -aHAXxn --delete --stats /home/ "$MNT/" | tail -20 | sed 's/^/        /'
  else
    say "($MNT is not mounted yet, so there is nothing to diff against --"
    say " re-run CHECK=1 once a real run has mounted it to see the delta)"
  fi
else
  say "copying $(( HOME_KB / 1024 / 1024 ))G -- this takes a while"
  rsync "${RSYNC_ARGS[@]}" || die "rsync failed. Nothing outside $MNT has changed;
       fix the cause and re-run -- rsync picks up where it left off."
fi

# ---------------------------------------------------------------------------
step "Verify the copy"

if [ -n "$CHECK" ]; then
  say "would re-run rsync with -n and require it to find nothing left to do"
  say "would compare hardlink counts between /home and $MNT"
else
  say "checking for anything rsync would still transfer..."
  remaining="$(rsync -aHAXxn --delete --itemize-changes /home/ "$MNT/" | wc -l)"
  if [ "$remaining" -eq 0 ]; then
    say "clean -- $MNT matches /home"
  else
    warn "$remaining path(s) still differ. If a vx session was running during the"
    warn "copy that is the reason. Re-run this script; the second pass is quick."
  fi

  # The specific failure worth naming, because it is silent: -H dropped, every
  # hardlink written as a separate copy, everything apparently fine until the
  # disk fills. Counting linked files on both sides catches it immediately.
  say "comparing hardlink counts (a minute or two)..."
  src_links="$(find /home -xdev -type f -links +1 2>/dev/null | wc -l)"
  dst_links="$(find "$MNT" -xdev -type f -links +1 2>/dev/null | wc -l)"
  say "hardlinked files: $src_links in /home, $dst_links in $MNT"
  if [ "$dst_links" -lt $(( src_links * 9 / 10 )) ]; then
    die "the copy lost hardlinks -- $dst_links against $src_links.
       Do not switch /home over. Check that the rsync above really had -H."
  fi
  say "hardlinks preserved"

  if command -v compsize >/dev/null; then
    compsize "$MNT" 2>/dev/null | sed 's/^/      /' || true
  fi
fi

# ---------------------------------------------------------------------------
step "Switch /etc/fstab over"

UUID="$(blkid -o value -s UUID "$DISK" 2>/dev/null || true)"
[ -n "$UUID" ] || [ -n "$CHECK" ] || die "could not read a UUID from $DISK"

FSTAB_LINE="UUID=$UUID /home btrfs $MOUNT_OPTS 0 0"

if grep -qE '^[^#]*[[:space:]]/home[[:space:]]' /etc/fstab 2>/dev/null; then
  skip "/etc/fstab already has a /home entry"
  say "it reads: $(grep -E '^[^#]*[[:space:]]/home[[:space:]]' /etc/fstab)"
else
  if [ -n "$CHECK" ]; then
    say "would append to /etc/fstab:"
    say "  UUID=<$DISK's uuid> /home btrfs $MOUNT_OPTS 0 0"
  else
    cp -a /etc/fstab "/etc/fstab.pre-btrfs-home"
    printf '\n# /home moved onto %s (btrfs) -- see migrate-home-btrfs.sh\n%s\n' \
      "$DISK" "$FSTAB_LINE" >> /etc/fstab
    say "backed up /etc/fstab to /etc/fstab.pre-btrfs-home"
    say "appended: $FSTAB_LINE"
    # An fstab that does not parse leaves the guest in an emergency shell on a
    # machine whose only console is `virsh console`. Cheap to check, expensive
    # to skip.
    systemctl daemon-reload || warn "systemctl daemon-reload failed -- check /etc/fstab by hand before rebooting"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n\033[1;32mDone.\033[0m\n\n'
say "The copy is on $DISK and /etc/fstab points /home at it. The live /home is"
say "still the old one on vda1 -- the switch happens on the next boot."
say ""
say "  1. umount $MNT && reboot"
say "  2. check you are on the new one:   findmnt /home"
say "     and that vx's world came with it: worktrees, ~/.local/share/pnpm, ssh keys"
say ""
say "  3. only then, reclaim the old /home. It is hidden under the new mount, so"
say "     reach it through the root filesystem directly:"
say ""
say "       mkdir -p /mnt/oldroot && mount --bind / /mnt/oldroot"
say "       du -sh /mnt/oldroot/home          # should be the ~141G you expect"
say "       rm -rf /mnt/oldroot/home/*"
say "       umount /mnt/oldroot && fstrim -av"
say ""
say "     fstrim is what actually hands the space back to the host's qcow2."
say ""
say "Then point your reflink worktree tool at it. Worth knowing: the trees"
say "copied here were written out full-size, so nothing shrank yet. New"
say "worktrees reflink and cost almost nothing; to collect the saving on the"
say "~22 workstreams already in ~/projects, either re-create them or run"
say "\`duperemove -dr ~/projects\` once (it ships via home/core/cli.nix)."
say ""
say "df now lies on /home -- btrfs keeps its accounting elsewhere. Use:"
say "  btrfs filesystem usage /home"
printf '\n'
