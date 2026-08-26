# Hardware config for "work" (Framework Desktop, AMD Ryzen AI Max+ 395 "Strix Halo").
#
# The module/microcode lines below came from `nixos-generate-config` run on the
# real machine from Fedora. The fileSystems block is hand-written to match the
# layout created at install time:
#
#   nvme0n1p1  vfat  label NIXBOOT   -> /boot   (ESP, systemd-boot)
#   nvme0n1p2  LUKS2 partlabel cryptroot
#     └─ btrfs label nixos, subvolumes @root @home @nix @libvirt
#
# Everything is addressed by label rather than UUID so this file stays valid if
# the volume is ever recreated.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  # Shared btrfs mount options. Mirrors what Fedora was using on this hardware.
  # NB: /var/lib/libvirt/images gets `chattr +C` at install time instead of a
  # mount option -- btrfs applies compression/datacow per-filesystem, not
  # per-subvolume, so the qcow2 images opt out via the inode attribute (which
  # also implies nocompress) rather than via a differing mount line here.
  btrfsOpts = [
    "compress=zstd:1"
    "noatime"
    "ssd"
    "discard=async"
    "space_cache=v2"
  ];
in
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "thunderbolt"
    "usbhid"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "btrfs";
    options = btrfsOpts ++ [ "subvol=@root" ];
  };

  fileSystems."/home" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "btrfs";
    options = btrfsOpts ++ [ "subvol=@home" ];
  };

  fileSystems."/nix" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "btrfs";
    options = btrfsOpts ++ [ "subvol=@nix" ];
  };

  # Separate subvolume so VM images stay out of any root snapshot.
  fileSystems."/var/lib/libvirt" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "btrfs";
    options = btrfsOpts ++ [ "subvol=@libvirt" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXBOOT";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  # No swap partition: 125 GiB of RAM, and zram (enabled in configuration.nix)
  # covers pressure spikes. Leaving swap off also keeps the encrypted-swap and
  # hibernation-resume complications out of the LUKS setup entirely.
  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
