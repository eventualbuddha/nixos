# Host-specific config for "work" -- Framework Desktop, AMD Ryzen AI Max+ 395
# ("Strix Halo") with a Radeon 8060S iGPU, 128 GB unified memory, 2x 2TB NVMe.
# Everything shared across machines lives in ../common.nix.

{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../common.nix
    ./vmguard.nix
  ];

  networking.hostName = "work";

  # --- Disk encryption -------------------------------------------------------
  #
  # Root is a LUKS2 container holding the btrfs volume; only the ESP is
  # cleartext. Unlock methods are enrolled with `systemd-cryptenroll` against
  # the live volume rather than declared here, so adding or revoking one never
  # needs a rebuild:
  #
  #   - recovery passphrase  (always keep one; nothing else can rescue you)
  #   - YubiKey FIDO2        (`--fido2-device=auto`, requires a touch)
  #   - TPM2                 (added only *after* Secure Boot is on -- PCR 7
  #                           measures Secure Boot state, so enrolling while
  #                           it is off would silently invalidate the slot the
  #                           moment it is switched on)
  #
  # systemd in the initrd is what makes FIDO2/TPM2 unlock possible at all; the
  # scripted initrd cannot talk to either. Passphrase entry still works as a
  # fallback whenever no token is present.
  boot.initrd.systemd.enable = true;
  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-partlabel/cryptroot";
    # Pass TRIM through to the SSD. This leaks which blocks are unused to an
    # attacker with repeated physical access -- an accepted trade for not
    # letting a 2TB NVMe degrade into its worst-case write-amplification.
    allowDiscards = true;
    crypttabExtraOpts = [ "fido2-device=auto" ];
  };

  # The ESP is 2 GiB and systemd-boot keeps a kernel + initrd per generation
  # there, so cap how many it retains. Older generations stay in the store and
  # remain switchable with `nixos-rebuild switch --rollback`; they just drop off
  # the boot menu.
  boot.loader.systemd-boot.configurationLimit = 10;

  # --- Hardware --------------------------------------------------------------

  # amdgpu needs redistributable firmware blobs. not-detected.nix already
  # defaults this on, but it is load-bearing enough on this box to be explicit.
  hardware.enableRedistributableFirmware = true;

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  hardware.bluetooth.enable = true;

  # 125 GiB of RAM and no swap partition. zram gives the kernel somewhere to
  # page under pressure -- mostly insurance for heavy from-source rebuilds and
  # for the vxsuite guest's 64 GiB reservation.
  zramSwap.enable = true;

  # --- Containers ------------------------------------------------------------
  #
  # Docker, for the VotingWorks CI images (votingworks/cimg-debian12-*).
  # Deliberately *not* adding brian to the "docker" group: membership in it is
  # effectively passwordless root, and the Fedora install this replaces used
  # `sudo docker` too. Keep that.
  virtualisation.docker.enable = true;

  # --- The vxsuite VM --------------------------------------------------------
  #
  # This is the machine the VM actually runs on, so `ssh vx` needs nothing
  # host-specific here: the `Host vx` block in ../common.nix points straight at
  # the guest's address on the local `vmguard` bridge. Other hosts are the ones
  # that have to add a ProxyJump to reach it.
  #
  # The guest is defined in libvirt's own state (`virsh dumpxml vxsuite`), not
  # here -- NixOS has no declarative option for libvirt domains.

  # --- User identity ---------------------------------------------------------
  #
  # NixOS's isNormalUser default puts brian in the shared "users" group (gid
  # 100). Keep a user-private group instead, as Fedora and most distributions
  # do: with a shared primary group, every group-readable file in the home
  # directory is readable by any other member of "users", which is a strictly
  # worse default even on a single-user machine.
  #
  # Host-scoped deliberately: judy is an existing install whose files already
  # use the NixOS default, and changing it there would orphan their ownership.
  users.groups.brian.gid = 1000;
  users.users.brian = {
    group = "brian";
    extraGroups = [ "users" ]; # keep the membership isNormalUser would have granted
  };

  # --- The old Fedora install, for reference ---------------------------------
  #
  # The second NVMe still holds the Fedora 44 system this replaced. Nothing was
  # copied out of its home directory on purpose -- dotfiles written against
  # /usr/bin paths do not belong on a system where home-manager owns that
  # config -- so this mount is how to go and fetch a specific file when needed.
  #
  # ro:                it is the rollback target; nothing here should ever write to it.
  # noauto+automount:  mounted on first access to /mnt/fedora, not at boot.
  # nofail:            when this disk is eventually wiped and reused, its
  #                    disappearance must not wedge the boot.
  fileSystems."/mnt/fedora" = {
    device = "/dev/disk/by-uuid/584cb26e-03fc-4d73-b2eb-1a24544133f8";
    fsType = "btrfs";
    options = [
      "subvol=/" # top level, so both the root and home subvolumes are visible
      "ro"
      "nofail"
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=60"
    ];
  };

  boot.initrd.systemd.emergencyAccess = true;

  # --- Git identity ----------------------------------------------------------
  #
  # This is the work machine, so commits made here carry the work address
  # instead of the personal one home/dev.nix defaults to for judy. The signing
  # key generated on this host is listed under both principals in
  # home/dev.nix, so commits from either address still verify everywhere.
  home-manager.users.brian.programs.git.settings.user.email = "brian@voting.works";

  # --- moshi-hook ------------------------------------------------------------
  #
  # Wanted on this machine and on the vxsuite guest, but not on judy, so it is
  # imported here rather than from home/ (which is judy+work) or home/core
  # (every machine). See home/moshi.nix for why it is bootstrapped rather than
  # packaged.
  home-manager.users.brian.imports = [ ../../home/moshi.nix ];
}
