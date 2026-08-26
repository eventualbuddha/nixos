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

  # --- User identity ---------------------------------------------------------
  #
  # Fedora gave brian a user-private group (brian:1000). NixOS's isNormalUser
  # default would instead drop brian into the shared "users" group (gid 100).
  # That would mean remapping ~39 GB of copied files, and -- more importantly --
  # every group-readable file in the home directory would become readable by any
  # other member of "users" rather than by brian alone. Pinning the private
  # group preserves the permission model the data was written under.
  #
  # Host-scoped deliberately: judy is an existing install whose files already
  # use the NixOS default, so this must NOT move into common.nix.
  users.groups.brian.gid = 1000;
  users.users.brian = {
    group = "brian";
    extraGroups = [ "users" ]; # keep the membership isNormalUser would have granted
  };

  # --- Rescue access ---------------------------------------------------------
  #
  # Without this, a failed unlock lands in initrd emergency mode with
  # "Cannot open access to console, the root account is locked" and there is no
  # way in at all -- found by booting this install in a VM before cutting over.
  #
  # The initrd has no access to the real root's /etc/shadow, which is why this is
  # a separate knob from root's password. `true` means a passwordless root shell
  # if (and only if) the initrd fails. At that point the root filesystem is still
  # encrypted, so there is nothing there to read.
  #
  # REVISIT BEFORE ENROLLING TPM2 (phase 7): once the TPM unlocks the disk
  # automatically, PCRs match during a normal boot, so anyone who can provoke an
  # initrd failure gets a root shell that can then ask the TPM for the key.
  # Secure Boot + lanzaboote mitigates this (the kernel command line is part of
  # the signed UKI, so emergency mode cannot simply be requested), but this
  # should become a hashed password at that point. It is deliberately not one
  # today because this flake is a public repo.
  boot.initrd.systemd.emergencyAccess = true;
}
