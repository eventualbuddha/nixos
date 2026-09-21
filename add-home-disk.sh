#!/usr/bin/env bash
# Attach a second virtual disk to the `vxsuite` guest, to become its /home.
# Runs on `work`, as brian. The guest side is `migrate-home-btrfs.sh`, which
# formats this disk as btrfs and moves /home onto it.
#
#   ./add-home-disk.sh
#
# Re-running is safe: every step checks for its own result first and skips.
# Run with CHECK=1 to print what each step *would* do and change nothing.
#
# WHY A SECOND DISK, rather than growing vda1 or converting it in place.
# vda1 is 199G at 97% full, and 141G of that is /home. Growing it is not the
# one-liner it looks like: the extended partition holding swap sits at the very
# end of vda (vda1 ends at sector 417429503, vda2/vda5 own the tail), so
# growing the root means deleting the extended partition, growing vda1,
# resize2fs, and recreating swap -- offline, on the only root filesystem there
# is. `btrfs-convert` on a 97%-full ext4 is worse. Attaching a disk is the same
# power-cycle with none of that, and it is reversible: the old /home stays on
# vda1 until you delete it by hand.
#
# WHY BTRFS ON IT. `ctree` -- the CLI from the clonetree crate, packaged in
# home/core/cli.nix -- copies a directory tree by reflinking rather than
# copying. That needs a CoW filesystem, and reflink requires source and
# destination on the *same* filesystem. `proj` clones from ~/code/vxsuite into
# ~/projects/<project>/<workstream>, so both have to live on the new volume --
# which mounting the whole of /home gets for free. Nothing in vxsuite requires
# ext4: every `ext4` reference in the tree is about formatting and mounting USB
# drives (libs/usb-drive), which is the sdb passthrough and is unaffected. The
# one place that cares about the filesystem under it, libs/fs/src/syscalls.ts,
# lists btrfs as supporting the renameat2 flags it needs.
set -euo pipefail

DOMAIN="${DOMAIN:-vxsuite}"
IMAGES_DIR="${IMAGES_DIR:-/var/lib/libvirt/images}"
IMG="${IMG:-$IMAGES_DIR/$DOMAIN-home.qcow2}"
# /home is 141G today. 500G is virtual size only -- qcow2 is sparse, so this
# costs what the guest actually writes, and `discard='unmap'` below plus
# `discard=async` in the guest mount keeps it that way as files are deleted.
SIZE="${SIZE:-500G}"
TARGET_DEV="${TARGET_DEV:-vdb}"
CHECK="${CHECK:-}"

step_n=0
step() { step_n=$((step_n + 1)); printf '\n\033[1;35m[%d/5]\033[0m %s\n' "$step_n" "$*"; }
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

NIX_FLAGS=(--extra-experimental-features "nix-command flakes")

# chattr and lsattr live in e2fsprogs, which this host has in the store -- the
# system closure pulls it in -- but not on PATH, because it is not in
# environment.systemPackages. Rather than give up on setting and checking
# nodatacow (see step 3 for why it matters), fetch it out of the store.
#
# Sets E2FS_BIN to a directory holding both, or leaves it empty.
find_e2fsprogs() {
  if command -v chattr >/dev/null 2>&1 && command -v lsattr >/dev/null 2>&1; then
    E2FS_BIN="$(dirname "$(command -v chattr)")"
    return 0
  fi

  local p
  # --offline first, and it is not merely a fallback: e2fsprogs is already in
  # the store, so this resolves in well under a second and touches no network.
  # Only if that misses do we allow a fetch.
  p="$(nix "${NIX_FLAGS[@]}" build --offline --no-link \
         --print-out-paths nixpkgs#e2fsprogs.bin 2>/dev/null)" || p=""
  if [ -z "$p" ] || [ ! -x "$p/bin/chattr" ]; then
    p="$(nix "${NIX_FLAGS[@]}" build --no-link \
           --print-out-paths nixpkgs#e2fsprogs.bin 2>/dev/null)" || p=""
  fi
  if [ -n "$p" ] && [ -x "$p/bin/chattr" ] && [ -x "$p/bin/lsattr" ]; then
    E2FS_BIN="$p/bin"
    return 0
  fi

  # For a machine whose nix has no flakes enabled. NIX_PATH here is
  # `nixpkgs=flake:nixpkgs:...`, so this resolves through the registry.
  if p="$(nix-shell -p e2fsprogs --run 'command -v chattr' 2>/dev/null)" \
     && [ -x "$p" ]; then
    E2FS_BIN="$(dirname "$p")"
    return 0
  fi

  E2FS_BIN=""
  return 1
}

# Report whether $IMG actually has nodatacow. Advisory: a missing +C is worth
# knowing about, but it is a performance property, not a correctness one, and
# nothing downstream of here depends on it.
check_nodatacow() {
  [ -n "$E2FS_BIN" ] || return 0
  [ -e "$IMG" ] || return 0
  local attrs
  attrs="$(sudo "$E2FS_BIN/lsattr" -d "$IMG" 2>/dev/null | awk '{print $1}')" || return 0
  case "$attrs" in
    *C*) say "nodatacow confirmed: $attrs" ;;
    *)   warn "$IMG does NOT have +C (attrs: $attrs)."
         warn "Every guest write will be copied by the host's btrfs as well as by the"
         warn "guest's own CoW. To fix it the file must be empty, so this is worth"
         warn "sorting out now rather than after 141G has been written into it."
         ;;
  esac
}

# ---------------------------------------------------------------------------
step "Preflight"

[ "$(id -u)" -ne 0 ] || die "run this as your own user, not root -- it uses sudo where it needs to."

command -v virsh    >/dev/null || die "virsh not found"
command -v qemu-img >/dev/null || die "qemu-img not found"

sudo -v || die "this needs sudo for virsh and for writing into $IMAGES_DIR"

sudo virsh dominfo "$DOMAIN" >/dev/null 2>&1 || die "no libvirt domain named '$DOMAIN'"

E2FS_BIN=""
if find_e2fsprogs; then
  case "$E2FS_BIN" in
    /nix/store/*) say "chattr/lsattr from the store: $E2FS_BIN" ;;
    *)            say "chattr/lsattr on PATH: $E2FS_BIN" ;;
  esac
fi

DOMAIN_STATE="$(sudo virsh domstate "$DOMAIN" 2>/dev/null || echo unknown)"
say "domain $DOMAIN is $DOMAIN_STATE"

# The disk is attached to the *persistent* config only (--config, never --live).
# Hotplugging it would work, but the guest then has a disk that vanishes on the
# next boot unless the persistent config also has it, and half-applied state is
# exactly what makes this kind of change hard to reason about later. So: config
# only, and the guest picks it up on its next cold start.
#
# Note "cold start": a `reboot` inside the guest does not re-read the domain
# XML. It takes `virsh shutdown` followed by `virsh start`.

if sudo virsh domblklist "$DOMAIN" --inactive 2>/dev/null | awk '{print $1}' | grep -qx "$TARGET_DEV"; then
  ATTACHED=1
else
  ATTACHED=""
fi

# ---------------------------------------------------------------------------
step "Space on the host for a $SIZE image"

AVAIL_K="$(df -Pk "$IMAGES_DIR" | awk 'NR==2 {print $4}')"
say "$IMAGES_DIR has $(( AVAIL_K / 1024 / 1024 ))G free"
# The image is sparse, so this is not a hard requirement -- but starting a
# migration that cannot finish is worse than refusing it, and /home is 141G.
[ "$AVAIL_K" -gt $(( 200 * 1024 * 1024 )) ] \
  || warn "under 200G free. The image is sparse, but /home is ~141G and the copy needs all of it."

# ---------------------------------------------------------------------------
step "The qcow2 image"

if [ -z "$E2FS_BIN" ]; then
  warn "no chattr/lsattr available, so nodatacow can be neither set nor checked."
  warn "The image should still inherit +C from $IMAGES_DIR, but this script cannot"
  warn "confirm it. The durable fix is adding e2fsprogs to environment.systemPackages"
  warn "in hosts/work/configuration.nix."
fi

if [ -e "$IMG" ]; then
  skip "$IMG exists ($(sudo du -sh "$IMG" 2>/dev/null | cut -f1) on disk)"
  # Worth checking even on the skip path: an image created some other way, or
  # copied in, silently lacks +C, and the symptom (the guest getting slower as
  # the image ages) never points back here.
  check_nodatacow
else
  # nodatacow on the image matters: without it every guest write is copied by
  # btrfs on the host as well as by the guest's own CoW, and the two compound.
  # hosts/work/hardware-configuration.nix:23 notes that $IMAGES_DIR gets
  # `chattr +C` at install time precisely so new images inherit it -- btrfs
  # applies the attribute to files created in the directory, and it can only be
  # set on a file while it is still empty. Hence: create empty, set, then let
  # qemu-img write the header into it.
  run sudo touch "$IMG"
  if [ -n "$E2FS_BIN" ]; then
    run sudo "$E2FS_BIN/chattr" +C "$IMG"
    [ -n "$CHECK" ] || say "set nodatacow (+C) explicitly"
  fi
  run sudo qemu-img create -f qcow2 "$IMG" "$SIZE"
  [ -n "$CHECK" ] || say "created $IMG ($SIZE virtual, sparse)"
  check_nodatacow
fi

# ---------------------------------------------------------------------------
step "Attach it as $TARGET_DEV"

if [ -n "$ATTACHED" ]; then
  skip "$TARGET_DEV is already in the persistent domain config"
else
  # attach-device with hand-written XML rather than `virsh attach-disk`, because
  # attach-disk has no way to set discard='unmap' -- and without it the guest
  # can free all the space it likes and the host image never shrinks. vda
  # already has it; this matches.
  DISK_XML="$(mktemp)"
  cat > "$DISK_XML" <<XML
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2' discard='unmap'/>
  <source file='$IMG'/>
  <target dev='$TARGET_DEV' bus='virtio'/>
</disk>
XML
  if [ -n "$CHECK" ]; then
    printf '      \033[2mwould attach:\033[0m\n'
    sed 's/^/        /' "$DISK_XML"
  else
    sudo virsh attach-device "$DOMAIN" --file "$DISK_XML" --config \
      || { rm -f "$DISK_XML"; die "attach-device failed -- nothing changed"; }
    say "attached $IMG as $TARGET_DEV (persistent config)"
  fi
  rm -f "$DISK_XML"
fi

# ---------------------------------------------------------------------------
step "What is left"

printf '\n\033[1;32mDone.\033[0m\n\n'
if [ "$DOMAIN_STATE" = "running" ]; then
  say "The guest is running and does NOT see $TARGET_DEV yet. A reboot from inside"
  say "the guest will not pick it up either -- libvirt only re-reads the domain XML"
  say "on a cold start:"
  say ""
  say "    sudo virsh shutdown $DOMAIN && sudo virsh start $DOMAIN"
else
  say "Start the guest:  sudo virsh start $DOMAIN"
fi
say ""
say "Then, in the guest, as root, with nobody logged in as vx:"
say ""
say "    ./migrate-home-btrfs.sh          # CHECK=1 first, to see the plan"
say ""
say "That formats $TARGET_DEV as btrfs, copies /home onto it, and switches"
say "/etc/fstab over. It deliberately does not delete the old /home -- that stays"
say "yours to do once you have booted on the new one and are happy."
printf '\n'
