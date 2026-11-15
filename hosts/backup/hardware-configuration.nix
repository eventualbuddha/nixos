# Hardware for backup -- a UTM (QEMU, Apple Hypervisor) aarch64 VM on the Mac Mini.
#
# Hand-written rather than a `nixos-generate-config` dump: the "hardware" is
# QEMU's virt machine, so it's just virtio + UEFI. Filesystems are mounted BY
# LABEL (`nixos`, `boot`, created at install time -- see
# ~/Documents/remote-backup-planning/backup-vm-setup.md), so this file never
# needs disk UUIDs.
#
# No USB storage here on purpose: passing the 16 TB drive through UTM's USB
# redirection was tried and abandoned (UAS and plain usb-storage both stalled
# with device resets). The drive lives on planb; this VM reaches it over the
# network via planb's restic REST server.

{ modulesPath, lib, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "xhci_pci"
    "usbhid"
  ];

  # UTM boots via UEFI (EDK2); systemd-boot is the simplest fit. Note UTM's
  # firmware puts any attached ISO (it's a USB "disk") ahead of this in the boot
  # order -- remove the installer ISO drive from the VM settings after install.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
