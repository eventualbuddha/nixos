# Hardware for planb -- Raspberry Pi 4B (aarch64).
#
# Unlike the other hosts, this is NOT a `nixos-generate-config` dump. A Pi's
# hardware is standardized, so we use the Raspberry Pi 4 profile from
# nixos-hardware plus the aarch64 SD-image builder. That pair:
#   - provides the Pi 4 firmware + device tree + U-Boot/extlinux boot path, and
#   - lets us build a flashable SD image with
#     `nix build .#nixosConfigurations.planb.config.system.build.sdImage`
#     (on an aarch64 machine, or on judy with aarch64 binfmt emulation enabled).
#
# The sd-image module defines `/` (the SD root, labelled NIXOS_SD) itself, so
# the only filesystem we declare here is the external archive drive.
#
# VERIFY ON FIRST BOOT: confirm the Pi is really a 4 (not a 5 -- different
# profile) and that it boots. If the SD-image route misbehaves, the fallback is
# the generic aarch64 installer + a real `nixos-generate-config` from the
# running Pi; keep that option in mind, it changes only this file.

{ inputs, ... }:

{
  imports = [
    inputs.nixos-hardware.nixosModules.raspberry-pi-4
    "${inputs.nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
  ];

  # Don't waste minutes compressing the image; we flash it straight away.
  sdImage.compressImage = false;

  # The generic sd-image-aarch64 profile pulls in hardware.enableAllHardware,
  # whose initrd module list names drivers for other ARM boards (e.g. dw-hdmi)
  # that the Raspberry Pi kernel from nixos-hardware doesn't build -- the initrd
  # build then fails with "modprobe: FATAL: Module dw-hdmi not found". Skip the
  # missing ones rather than hand-pruning the list: keeping every module the Pi
  # kernel DOES have is the safer bet for a headless box we can't reach a
  # console on.
  boot.initrd.allowMissingModules = true;

  # Boot chain: Pi GPU firmware -> U-Boot -> extlinux.conf -> NixOS kernel.
  # nixos-hardware's raspberry-pi firmware module now owns the firmware
  # partition (it mkForce-overrides sd-image-aarch64's populateFirmwareCommands)
  # and only installs U-Boot + `kernel=u-boot.bin` when this is on. Without it
  # the image has no kernel for the firmware to load: the Pi sits at solid red +
  # 7 green flashes ("kernel image not found"). Found the hard way 2026-11-14.
  hardware.raspberry-pi.firmware.uboot.enable = true;

  # The USB-attached 16 TB archive drive. Formatted btrfs with filesystem label
  # `planb` (see planb-setup.md). Mounted BY LABEL so swapping the enclosure or
  # moving it to another USB port doesn't break the mount.
  #
  #  - nofail + device-timeout: if the enclosure is slow or absent at boot, the
  #    Pi still comes up (and restic-rest-server stays down -- it RequiresMountsFor
  #    this path -- rather than writing to the SD card). Important for a box we
  #    can only reach remotely.
  fileSystems."/srv/backup" = {
    device = "/dev/disk/by-label/planb";
    fsType = "btrfs";
    options = [
      "noatime"
      "nofail"
      "x-systemd.device-timeout=30s"
      "compress=zstd:1"
    ];
  };

  # No swap partition -- see zramSwap in configuration.nix (SD-card wear).
  swapDevices = [ ];
}
