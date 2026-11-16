# home's disk layout, declared for disko -- which is what nixos-anywhere runs to
# partition the box remotely, and which also generates the matching
# fileSystems / boot.initrd.luks entries, so those are NOT repeated in
# hardware-configuration.nix.
#
# Same shape as work's hand-made layout:
#
#   nvme0n1p1  ESP, vfat, partlabel + fs label NIXBOOT, 1 GiB  -> /boot
#   nvme0n1p2  LUKS2, partlabel cryptroot, opened as /dev/mapper/cryptroot
#     └─ btrfs label nixos: @root -> /, @home -> /home, @nix -> /nix
#
# The initial passphrase comes from /tmp/luks.key on the target, which
# nixos-anywhere puts there (`--disk-encryption-keys /tmp/luks.key <local file>`).
# It is only read at format time; TPM2 is enrolled later (MIGRATION.md step 7).
{
  disko.devices.disk.main = {
    type = "disk";
    # By serial, so a USB stick enumerating first can never be the target.
    device = "/dev/disk/by-id/nvme-SKHynix_HFS256GDE9X081N_FSB7N462210207716";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          label = "NIXBOOT";
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            extraArgs = [
              "-F32"
              "-n"
              "NIXBOOT"
            ];
            mountpoint = "/boot";
            mountOptions = [
              "fmask=0077"
              "dmask=0077"
            ];
          };
        };
        cryptroot = {
          label = "cryptroot";
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            passwordFile = "/tmp/luks.key";
            settings = {
              # TRIM through to the SSD; same trade as work.
              allowDiscards = true;
              # Read by the systemd initrd. Harmless until a TPM2 slot exists.
              crypttabExtraOpts = [ "tpm2-device=auto" ];
            };
            content = {
              type = "btrfs";
              extraArgs = [
                "-L"
                "nixos"
              ];
              subvolumes =
                let
                  opts = [
                    "compress=zstd:1"
                    "noatime"
                    "ssd"
                    "discard=async"
                    "space_cache=v2"
                  ];
                in
                {
                  "@root" = {
                    mountpoint = "/";
                    mountOptions = opts;
                  };
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = opts;
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = opts;
                  };
                };
            };
          };
        };
      };
    };
  };
}
