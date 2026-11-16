# Hardware for home -- the small Intel box in the house (i5-10400T, 32 GB,
# 256 GB SK hynix NVMe, BD-RE BU50N optical drive). It was Fedora 44 until the
# 2026-11 migration; see ./MIGRATION.md.
#
# Partitions, LUKS and filesystems are NOT here: ./disko.nix declares them and
# disko generates the matching fileSystems and boot.initrd.luks entries.
#
# The kernel-module list is what `nixos-generate-config` gives for this
# chipset (Comet Lake PCH: AHCI, xHCI, NVMe).
{
  config,
  lib,
  modulesPath,
  ...
}:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "sr_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  # zram only (configuration.nix); no swap partition inside or outside LUKS.
  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
