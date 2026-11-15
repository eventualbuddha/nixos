# backup -- the backup CLIENT. An aarch64 NixOS VM in UTM on the Mac Mini, which
# sits on the same switch as the NAS and is always on. It reads the NAS (and,
# later, the OpenCloud VM's data) and pushes restic snapshots to planb, the
# offsite Pi.
#
# Why a VM rather than restic on macOS: it's declarative like every other host,
# deployable from judy (`nixos-rebuild --target-host backup --build-host
# backup`), and it doubles as a NATIVE aarch64 builder -- planb's SD image and
# closures build here instead of under binfmt emulation on judy.
#
# The first ~6.4 TB backup runs over the LAN to planb while planb is still at
# home; later incrementals go over Tailscale after it moves. See
# ~/Documents/remote-backup-planning/backup-vm-setup.md.
#
# Like planb, built with `mkServer` and deliberately not on ../common.nix.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Where the NAS's whole volume is mounted (read-only). Bound to a name so the
  # mount, the backup paths/excludes and the mount dependency can't drift.
  nasMount = "/mnt/nas";
in
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "backup";

  # --- Nix / base ------------------------------------------------------------

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Accept closures pushed from judy (`nixos-rebuild --target-host`), and let
    # judy use this VM as a remote aarch64 builder for planb.
    trusted-users = [
      "root"
      "@wheel"
    ];
  };

  nixpkgs.config.allowUnfree = true;

  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "en_US.UTF-8";

  # restic's index for a multi-TB repo lives in RAM; zram gives headroom without
  # a swap file eating the Mac's SSD.
  zramSwap.enable = true;

  systemd.enableEmergencyMode = false;

  # --- Networking ------------------------------------------------------------

  # UTM "Bridged" networking: the VM gets its own address on the home LAN, so
  # it reaches the NAS directly at full gigabit (no NAT hop through macOS).
  networking.useDHCP = lib.mkDefault true;

  services.tailscale.enable = true;
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];

  # --- Users / SSH -----------------------------------------------------------

  users.users.brian = {
    isNormalUser = true;
    description = "Brian Donovan";
    extraGroups = [ "wheel" ];
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      # 1Password key
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINBvZDmCn71NMskaJHNVGxvMHiwRvyF/SjA/hFgCkX2K"
      # judy key
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIEulPeKr/e/wXjt/eyDyOrt0UodGzqndfWexz9Aa4v2JAAAABHNzaDo= brian@judy"
    ];
  };

  users.users.root.openssh.authorizedKeys.keys =
    config.users.users.brian.openssh.authorizedKeys.keys;

  security.sudo.wheelNeedsPassword = false; # access is gated by key-only SSH

  services.openssh.enable = true;
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };

  # --- Guest integration -----------------------------------------------------

  # UTM's QEMU backend: clean shutdown from the UTM window, clipboard/resize.
  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  # --- The NAS, read-only ----------------------------------------------------

  # The ReadyNAS exports its whole volume as the SMB share `data` (every share:
  # Videos, Backups, Documents, Music, Pictures, Disc Images, home). Its NFS
  # exports don't include the data shares, so SMB it is. Measured ~100 MB/s
  # (gigabit line rate) from this VM.
  #
  # READ-ONLY on purpose: this host only ever reads the NAS. A compromised or
  # buggy backup client must not be able to touch the source data.
  #
  # Automount, so boot never blocks on the NAS and a NAS reboot doesn't wedge
  # the VM. Credentials live in /root/nas-smb.cred (mode 600, NOT in the nix
  # store / git): `username=...` and `password=...` lines.
  fileSystems.${nasMount} = {
    device = "//192.168.86.35/data";
    fsType = "cifs";
    options = [
      "ro"
      "credentials=/root/nas-smb.cred"
      "vers=3.0"
      "noperm"
      "noauto"
      "x-systemd.automount"
      # No idle-timeout: when it fired mid-backup (2026-11-15 09:53), systemd
      # stopped restic-backups-nas (RequiresMountsFor) to unmount the share,
      # killing the first run 1h in. The mount just stays up once used.
      "x-systemd.mount-timeout=30s"
      "_netdev"
    ];
  };

  # --- Backups: NAS -> planb -------------------------------------------------

  # Pushes to planb's restic REST server over the tailnet. planb is
  # append-only, so this client can add snapshots but never delete them, and
  # there is deliberately no pruneOpts here (pruning is done on purpose, from a
  # trusted machine -- see planb-setup.md).
  #
  # Secrets (root-only, NOT in the nix store / git; escrow both in 1Password):
  #   /root/restic/mac.pass  repo ENCRYPTION key. Lose it = lose the backup.
  #   /root/restic/mac.env   RESTIC_REST_USERNAME=mac / RESTIC_REST_PASSWORD=...
  #                          (planb's htpasswd credential; gates who may push).
  #
  # The first run moves ~6.4 TB and takes most of a day; start it by hand
  # (`systemctl start restic-backups-nas`) rather than waiting for the timer.
  services.restic.backups.nas = {
    repository = "rest:http://planb:8000/mac/";
    passwordFile = "/root/restic/mac.pass";
    environmentFile = "/root/restic/mac.env";
    initialize = true;
    paths = [ nasMount ];
    exclude = [
      # ReadyNAS-internal folders (app installs, its own recycle-bin purge
      # area), not user data. Everything else on the volume is backed up,
      # including any Time Machine backups in the Backups share.
      "${nasMount}/**/.apps"
      "${nasMount}/**/.purge"
      # Samba follows symlinks server-side, so over SMB they look like real
      # directories. libvirt's test fixtures are fake sysfs trees full of
      # node0 -> ../.. style links, which turn into an endless directory loop
      # (stalled the first run for ~15h on 2026-11-14). Upstream tarball
      # contents; nothing worth backing up.
      "${nasMount}/**/libvirt-*/tests"
      # AerynOS recipe checkouts (where the libvirt tree above lived); no
      # longer used, and recoverable from GitHub anyway.
      "${nasMount}/**/github.com/AerynOS"
    ];
    extraBackupArgs = [
      # SMB inode numbers aren't stable across mounts (and will change outright
      # when the NAS moves to NixOS); compare on mtime+size only, or restic
      # re-reads all 6 TB every run.
      "--ignore-inode"
      "--exclude-caches"
    ];
    timerConfig = {
      OnCalendar = "02:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  systemd.services.restic-backups-nas.unitConfig.RequiresMountsFor = [ nasMount ];

  # --- Tooling ---------------------------------------------------------------

  environment.systemPackages = with pkgs; [
    restic
    cifs-utils
    git # flakes in a checkout here (planb SD image builds)
    pv
    tmux # for watching the multi-hour first backup
  ];

  # First install of this host. Do not bump on upgrades.
  system.stateVersion = "26.05";
}
