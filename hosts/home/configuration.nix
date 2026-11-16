# home -- the always-on Intel box in the house. Headless server: summer (the
# finance app), Forgejo (git for brian and madeline), and the Blu-ray drive for
# MakeMKV rips onto the NAS. Replaced a Fedora 44 KDE install in 2026-11; the
# cutover steps and what was carried over live in ./MIGRATION.md.
#
# Built with `mkServer` like backup and planb, so it does NOT pull in
# ../common.nix (the niri desktop). It does pull in home-manager itself, for
# home/core (shell, editor, claude & co.) and for summer's rootless podman
# containers -- see ./home.nix.
#
# The one hard requirement on this host: it must come back by itself after a
# power cut. Every choice below that bears on that is marked "unattended".
#
# Deploy from judy:
#   nixos-rebuild switch --flake ~/nixos#home --target-host home --sudo

{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  # On since 2026-11-15 (keys in /var/lib/sbctl, from `sudo sbctl create-keys`);
  # see "Disk encryption / boot" below and step 6 of ./MIGRATION.md. To undo,
  # set it false to go back to plain systemd-boot.
  secureBoot = true;

  # The NAS's whole volume, read-write (unlike backup's read-only mount): rips
  # land on it. Bound to a name so the mount and the `rip` default can't drift.
  nasMount = "/mnt/nas";

  rip = pkgs.writeShellApplication {
    name = "rip";
    runtimeInputs = with pkgs; [
      makemkv
      coreutils
      gawk
      util-linux # eject
    ];
    runtimeEnv.RIP_DIR_DEFAULT = "${nasMount}/Videos/Rips";
    text = builtins.readFile ./rip.sh;
  };

  # Headless HandBrake: the GUI would pull GTK onto a server. Not in the binary
  # cache this way, so judy builds it (a few minutes) on nixpkgs bumps.
  handbrake = pkgs.handbrake.override { useGtk = false; };

  encode = pkgs.writeShellApplication {
    name = "encode";
    runtimeInputs = [
      handbrake
      pkgs.ffmpeg-headless # ffprobe
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.systemd
      pkgs.openssh # mobile-sync runs its linking on the NAS
    ];
    runtimeEnv = {
      VIDEOS_DEFAULT = "${nasMount}/Videos";
      # With brian's ~/.ssh/readynas_sshfs key (carried over from Fedora, in
      # home.tar; not in Nix).
      NAS_SSH_DEFAULT = "root@192.168.86.35";
    };
    text = builtins.readFile ./encode.sh;
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    inputs.disko.nixosModules.disko
    inputs.home-manager.nixosModules.default
    inputs.lanzaboote.nixosModules.lanzaboote
  ];

  networking.hostName = "home";

  # --- Nix / base ------------------------------------------------------------

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Closures pushed from judy arrive as root (`--target-host root@home`).
    # Not @wheel: a trusted user can add arbitrary store paths and set
    # substituters, which is root by another name and would make sudo's
    # password moot.
    trusted-users = [ "root" ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  nixpkgs.config.allowUnfree = true; # makemkv

  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "en_US.UTF-8";

  zramSwap.enable = true;

  # Unattended: a unit that fails at boot must not drop the box into an
  # emergency shell nobody is watching. Same as backup.
  systemd.enableEmergencyMode = false;

  # --- Disk encryption / boot ------------------------------------------------
  #
  # Root is LUKS2 + btrfs, as on work. Unlock methods are enrolled against the
  # live volume with `systemd-cryptenroll`, not declared here:
  #
  #   - recovery passphrase  (always keep one; set at install)
  #   - TPM2, PCR 7          (unattended: the reason this box can reboot alone)
  #
  # PCR 7 measures the Secure Boot state and the keys that signed the boot
  # chain, so the TPM only releases the key to a kernel signed with OUR keys.
  # That's why Secure Boot comes first: lanzaboote signs every generation with
  # the keys in /var/lib/sbctl, PCR 7 stays put across rebuilds and kernel
  # updates, and only a firmware/Secure Boot change sends the box back to the
  # passphrase. Enrolling TPM2 while Secure Boot is still off would release the
  # key to anything that boots.
  #
  # The LUKS device itself (with `tpm2-device=auto`, which the systemd initrd
  # reads) is declared in ./disko.nix along with the rest of the layout. With no
  # TPM slot enrolled yet, boot just asks for the passphrase on the console.

  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot = {
    enable = lib.mkForce (!secureBoot);
    configurationLimit = 10;
  };
  boot.lanzaboote = lib.mkIf secureBoot {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
    configurationLimit = 10;
    # No kernel-cmdline editing at the boot menu (init=/bin/sh on a box that
    # unlocks itself).
    settings.editor = false;
  };

  # --- Networking ------------------------------------------------------------

  # Wired (I219-V) on DHCP. The Wi-Fi card is left unconfigured.
  networking.useDHCP = lib.mkDefault true;

  # Nothing on a plain NixOS server pulls in network-online.target, but
  # podman's user units (podman-user-wait-network-online) poll for it: without
  # this they spin forever and home-manager-brian.service hangs the boot.
  systemd.targets.network-online.wantedBy = [ "multi-user.target" ];
  # Its activation fetches things (codex/copilot bootstraps).
  systemd.services.home-manager-brian = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
  };

  # tailscaled's state (/var/lib/tailscale) is carried over from Fedora, so the
  # node keeps the name `home` and 100.86.205.11 and needs no `tailscale up`.
  # Tailscale SSH stays OFF (it was on under Fedora, and it is what broke
  # herdr): port 22 on the tailnet belongs to sshd, with keys below.
  # Enforced, not assumed: the carried-over state still had RunSSH on, so
  # `ssh home` was answered by tailscaled (banner SSH-2.0-Tailscale) and none
  # of the sshd settings or authorized keys applied. tailscaled-set.service
  # re-applies this on every switch.
  services.tailscale.enable = true;
  services.tailscale.extraSetFlags = [ "--ssh=false" ];
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];

  # --- Users / SSH -----------------------------------------------------------

  programs.fish.enable = true;

  users.users.brian = {
    isNormalUser = true;
    description = "Brian Donovan";
    # Pinned: the NAS mount and the restic prepare script name it.
    uid = 1000;
    extraGroups = [
      "wheel"
      "cdrom" # /dev/sr0 and its /dev/sg* node, for makemkvcon
    ];
    shell = pkgs.fish;
    # Unattended: start the rootless podman units at boot, not at first login.
    linger = true;
    openssh.authorizedKeys.keys = [
      # 1Password key
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINBvZDmCn71NMskaJHNVGxvMHiwRvyF/SjA/hFgCkX2K"
      # judy key
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIEulPeKr/e/wXjt/eyDyOrt0UodGzqndfWexz9Aa4v2JAAAABHNzaDo= brian@judy"
    ];
  };

  users.users.root.openssh.authorizedKeys.keys =
    config.users.users.brian.openssh.authorizedKeys.keys;

  # sudo asks for brian's password (set by hand with `passwd`; users are
  # mutable). Deploys don't need it: they go in as root@home, whose key-only
  # login above is also the way back in if sudo ever breaks.

  services.openssh.enable = true;
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    users.brian = import ./home.nix;
    backupFileExtension = "backup";
  };

  # --- Containers (summer) ---------------------------------------------------

  # The containers themselves are rootless quadlets declared in ./home.nix.
  # This is only the system half: newuidmap wrappers, policy, storage config.
  virtualisation.podman.enable = true;

  # --- Forgejo ---------------------------------------------------------------
  #
  # Replaced the gitea:latest container. Native, SQLite, built-in SSH server.
  # Both listeners are loopback-only; the tailnet reaches them through the
  # `tailscale-code` sidecar in ./home.nix:
  #   https://code.tail42107.ts.net/
  #   ssh://git@code.tail42107.ts.net:2222/<owner>/<repo>.git
  # (Under Fedora this was gitea.tail42107.ts.net; old remotes need
  # `git remote set-url`.)
  #
  # Repos and users were re-created rather than upgraded in place (Forgejo
  # can't upgrade from Gitea 1.26); see ./MIGRATION.md.
  services.forgejo = {
    enable = true;
    database.type = "sqlite3";
    lfs.enable = true;
    settings = {
      server = {
        PROTOCOL = "http";
        HTTP_ADDR = "127.0.0.1";
        HTTP_PORT = 3300;
        DOMAIN = "code.tail42107.ts.net";
        ROOT_URL = "https://code.tail42107.ts.net/";

        START_SSH_SERVER = true;
        SSH_LISTEN_HOST = "127.0.0.1";
        SSH_LISTEN_PORT = 2222;
        SSH_PORT = 2222; # the port clone URLs advertise
        SSH_DOMAIN = "code.tail42107.ts.net";
        # Clone URLs say git@, as the Gitea container's did. (Default would be
        # the service user, forgejo@.)
        BUILTIN_SSH_SERVER_USER = "git";
      };
      service = {
        DISABLE_REGISTRATION = true;
        REQUIRE_SIGNIN_VIEW = true;
      };
      session.COOKIE_SECURE = true;
      # `git push` to a repo that doesn't exist yet creates it (private, in
      # your own namespace). How the old Gitea repos were carried over.
      repository = {
        ENABLE_PUSH_CREATE_USER = true;
        DEFAULT_PUSH_CREATE_PRIVATE = true;
      };
      # No runner was ever registered on the old Gitea; leave Actions off.
      actions.ENABLED = false;
    };
    # Nightly `forgejo dump` (repos + db + config) into /var/lib/forgejo/dump,
    # which restic below picks up. A dump is consistent; a live copy of the
    # SQLite file isn't guaranteed to be.
    dump = {
      enable = true;
      type = "tar.zst";
      interval = "02:30";
      age = "7d";
    };
  };

  # --- The NAS ---------------------------------------------------------------
  #
  # The ReadyNAS's whole volume over SMB, as on backup, but READ-WRITE: rips go
  # to ${nasMount}/Videos/Rips. Replaces Fedora's sshfs user unit.
  #
  # Unattended: automount, so boot never waits on the NAS (which may be slower
  # back from the same power cut) and a NAS reboot doesn't wedge anything.
  #
  # Credentials live in /root/nas-smb.cred (mode 600, NOT in the store / git),
  # same format as on backup: `username=...` / `password=...` lines.
  fileSystems.${nasMount} = {
    device = "//192.168.86.35/data";
    fsType = "cifs";
    options = [
      "rw"
      "credentials=/root/nas-smb.cred"
      "vers=3.0"
      "uid=${toString config.users.users.brian.uid}"
      "gid=${toString config.users.groups.users.gid}"
      "file_mode=0664"
      "dir_mode=0775"
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=10min"
      "x-systemd.mount-timeout=30s"
      "_netdev"
    ];
  };
  # --- MakeMKV ---------------------------------------------------------------
  #
  # Headless: makemkvcon via `rip` (./rip.sh). For the odd disc that wants the
  # GUI, run it from judy with `waypipe ssh home makemkv`.
  #
  # makemkvcon talks to the drive through SCSI generic, so `sg` has to be loaded
  # (it isn't by default); udev gives the sg node for an optical drive to group
  # cdrom. The beta/purchased key goes in ~/.MakeMKV/settings.conf as
  # `app_Key = "..."` -- not here, it's a secret.
  boot.kernelModules = [ "sg" ];

  # No blkid probe on optical media. udev's 60-persistent-storage.rules runs
  # blkid on every disc change, and on a CSS DVD in the USB BD-RE drive those
  # reads (sector 64, "critical target error") left the drive unable to open
  # the disc until it was ejected -- mid-rip, several times. Known MakeMKV
  # issue on Linux: https://forum.makemkv.com/forum/viewtopic.php?p=205692.
  # systemd's rule honours this flag; it has to be set before 60-, which
  # extraRules (99-local) is too late for. Cost: no ID_FS_LABEL on sr0, which
  # `rip` doesn't use (it takes the name from makemkvcon).
  services.udev.packages = [
    (pkgs.writeTextDir "lib/udev/rules.d/59-no-blkid-optical.rules" ''
      KERNEL=="sr*", ENV{UDEV_DISABLE_PERSISTENT_STORAGE_BLKID_FLAG}="1"
    '')
  ];

  environment.systemPackages = with pkgs; [
    config.services.forgejo.package # `forgejo admin ...` (MIGRATION.md step 4)
    makemkv
    rip
    encode
    handbrake # HandBrakeCLI, for one-offs
    pkgs.mkvtoolnix-cli # mkvinfo / mkvmerge: inspect and trim rips
    pkgs.ffmpeg-headless # ffprobe
    waypipe # server side of `waypipe ssh home makemkv`
    cifs-utils
    sbctl # Secure Boot key management for lanzaboote
    efibootmgr
    restic
    git
    tmux
  ];

  # --- Backups: home -> planb ------------------------------------------------
  #
  # Under Fedora nothing on this box was backed up anywhere -- Forgejo's repos
  # and summer's database existed only here. This pushes them to planb's
  # append-only restic server, as backup does for the NAS.
  #
  # Secrets (root-only, NOT in the store / git; escrow both in 1Password):
  #   /root/restic/home.pass  repo ENCRYPTION key. Lose it = lose the backup.
  #   /root/restic/home.env   RESTIC_REST_USERNAME=home / RESTIC_REST_PASSWORD=...
  #                           (a new `home` entry in planb's .htpasswd).
  services.restic.backups.home = {
    repository = "rest:http://planb:8000/home/";
    passwordFile = "/root/restic/home.pass";
    environmentFile = "/root/restic/home.env";
    initialize = true;
    paths = [
      config.services.forgejo.dump.backupDir
      "/var/backup/summer"
      "/home/brian/notes"
      "/home/brian/code"
    ];
    exclude = [ "/home/brian/code/**/node_modules" ];
    # summer's SurrealDB, exported to a logical dump while it runs. The raw
    # surrealkv files in the volume aren't safe to copy live. The container is
    # rootless, so this runs podman as brian. If the export fails, the whole
    # backup fails -- loudly, in `systemctl --failed` -- rather than quietly
    # skipping summer.
    backupPrepareCommand = ''
      install -d -m 700 /var/backup/summer
      ${pkgs.util-linux}/bin/runuser -u brian -- \
        env XDG_RUNTIME_DIR=/run/user/${toString config.users.users.brian.uid} \
        ${pkgs.podman}/bin/podman exec summer-surrealdb \
          /surreal export --log none --endpoint http://127.0.0.1:8000 \
            --namespace summer --database summer - \
        > /var/backup/summer/summer.surql.tmp
      mv /var/backup/summer/summer.surql.tmp /var/backup/summer/summer.surql
    '';
    timerConfig = {
      OnCalendar = "03:00"; # after the 02:30 forgejo dump
      RandomizedDelaySec = "15m";
      Persistent = true;
    };
  };

  # First install of this host. Do not bump on upgrades.
  system.stateVersion = "26.05";
}
