# planb -- the offsite backup target. A Raspberry Pi 4 (aarch64) with a USB
# 16 TB btrfs drive, living at a remote site and reached over Tailscale. It runs
# a restic REST server in APPEND-ONLY mode: clients (judy, the Mac Mini, ...)
# push restic repositories to it, each already encrypted client-side, so planb
# only ever stores opaque encrypted blobs and holds no key that can read them.
#
# Deliberately NOT built on ../common.nix: that file is the desktop (niri,
# GNOME, Flatpak, libvirt, 1Password GUI, pipewire), none of which belongs on a
# headless ARM server. planb restates the handful of things it shares with the
# other hosts (Tailscale, keys-only SSH, Brian's authorized keys, flakes) and
# nothing else. It is wired into the flake with `mkServer`, not `mkHost`.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Where the 16 TB drive is mounted (see hardware-configuration.nix) and where
  # the restic REST server keeps its per-client repositories. Bound to names so
  # the mount ordering, the service dataDir and the btrbk source can't drift
  # apart.
  backupMount = "/srv/backup";
  resticData = "${backupMount}/restic";
in
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "planb";

  # --- Nix / base ------------------------------------------------------------

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # So `nixos-rebuild --target-host root@planb` (pushing a closure built on
    # judy) is accepted without a signature.
    trusted-users = [
      "root"
      "@wheel"
    ];
  };

  nixpkgs.config.allowUnfree = true;

  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "en_US.UTF-8";

  # The SD card is the root device; a swap partition on it would wear it out.
  # zram gives the kernel somewhere to page under pressure instead (the Pi has
  # limited RAM and restic's server side is light, but btrfs scrub + Tailscale
  # together can spike).
  zramSwap.enable = true;

  # A headless server: boot straight to multi-user, never wait on a display.
  systemd.enableEmergencyMode = false;

  # --- Networking ------------------------------------------------------------

  networking.networkmanager.enable = true;

  # Tailscale is the only way in at the remote site -- no port-forwarding on the
  # sister's router, nothing for her to configure. Same pattern as common.nix:
  # trust the tailnet interface and open the UDP port for direct (non-DERP)
  # connections. Authenticating the node (`sudo tailscale up`) is a one-time
  # manual step done before it leaves the house -- see planb-setup.md.
  services.tailscale.enable = true;
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];

  # The restic REST server listens on :8000. It is NOT in allowedTCPPorts, so
  # the firewall drops it on every interface EXCEPT tailscale0 (trusted above).
  # That is the whole access-control story for the backup port: reachable only
  # from the tailnet, never from the sister's LAN or the internet.

  networking.nameservers = [
    "1.1.1.1"
    "1.0.0.1"
  ];

  # --- Users / SSH -----------------------------------------------------------

  users.users.brian = {
    isNormalUser = true;
    description = "Brian Donovan";
    extraGroups = [ "wheel" ];
    shell = pkgs.bashInteractive; # no home-manager on planb; bash is fine
    openssh.authorizedKeys.keys = [
      # 1Password key
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINBvZDmCn71NMskaJHNVGxvMHiwRvyF/SjA/hFgCkX2K"
      # judy key
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIEulPeKr/e/wXjt/eyDyOrt0UodGzqndfWexz9Aa4v2JAAAABHNzaDo= brian@judy"
    ];
  };

  # root login over SSH by the same keys, so `nixos-rebuild --target-host
  # root@planb` works for remote deploys from judy. Password login is off (see
  # services.openssh.settings), so this is key-only like everywhere else.
  users.users.root.openssh.authorizedKeys.keys =
    config.users.users.brian.openssh.authorizedKeys.keys;

  security.sudo.wheelNeedsPassword = false; # headless; access is already gated by key-only SSH

  services.openssh.enable = true;
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };

  # --- The backup service ----------------------------------------------------

  # restic REST server. Clients push with `rest:https?://planb:8000/<user>/`.
  #
  # appendOnly:   clients can create and read, but NEVER delete or overwrite.
  #               A compromised or ransomwared client cannot destroy history
  #               here. Pruning is done deliberately, from a trusted machine,
  #               with the server temporarily taken out of append-only mode (or
  #               via a separate non-append-only mount) -- see planb-setup.md.
  # privateRepos: each client authenticates (htpasswd) and is confined to its
  #               own /<user>/ subtree -- judy can't see the Mac's repo, etc.
  #
  # The server stores only client-side-encrypted data; the repo passwords live
  # on the clients. planb cannot decrypt anything it holds. That is the point.
  services.restic.server = {
    enable = true;
    # Bare port -- the module uses systemd socket activation and asserts on a
    # host:port form. The firewall (not a bind address) is what confines this to
    # the tailnet: :8000 is open only on tailscale0.
    listenAddress = "8000";
    dataDir = resticData;
    appendOnly = true;
    privateRepos = true;
    prometheus = false;
  };

  # Don't start the server until the 16 TB drive is actually mounted -- its
  # dataDir lives on it. Without this, a boot where the USB enclosure is slow to
  # appear would have the server create an empty repo dir on the SD card's root
  # instead, and clients would silently push into the void.
  systemd.services.restic-rest-server = {
    after = [ "srv-backup.mount" ];
    requires = [ "srv-backup.mount" ];
    unitConfig.RequiresMountsFor = [ backupMount ];
  };

  # `htpasswd` (to create/append client credentials in <dataDir>/.htpasswd) and
  # `restic` itself (for occasional server-side `restic check`/prune runs over
  # the local repo). smartmontools for drive health.
  environment.systemPackages = with pkgs; [
    apacheHttpd # provides htpasswd
    restic
    smartmontools
    btrfs-progs
  ];

  # --- Local btrfs snapshots of the repo (second safety net) -----------------
  #
  # append-only already stops a client from deleting history. btrbk adds
  # point-in-time local snapshots of the repo subvolume, so a server-side bug,
  # an accidental prune, or logical corruption is still recoverable. Snapshots
  # only (no send/receive target): this is purely local rollback.
  #
  # Requires `restic` to be its own btrfs subvolume under the drive, with a
  # `.snapshots` dir -- created at format time in planb-setup.md.
  services.btrbk.instances.planb = {
    onCalendar = "daily";
    settings = {
      snapshot_preserve_min = "2d";
      snapshot_preserve = "14d 8w 6m";
      volume.${backupMount} = {
        subvolume = "restic";
        snapshot_dir = ".snapshots";
      };
    };
  };

  # --- Health monitoring -----------------------------------------------------

  # SMART monitoring of the archive drive. Alerting needs an MTA or a script;
  # for now this logs to the journal and marks the drive FAILED there. Wire a
  # healthchecks.io ping or ntfy push in planb-setup.md once the node is up.
  services.smartd = {
    enable = true;
    autodetect = true;
  };

  # Monthly btrfs scrub: catches bit-rot on the archive drive (checksummed data,
  # so a scrub actually detects silent corruption rather than just reading it
  # back). A real dead-man's-switch for "did a backup even run" belongs on the
  # CLIENTS (ping healthchecks.io after a successful restic run) -- see
  # planb-setup.md -- because planb is a passive target and can't know a client
  # was supposed to call.
  systemd.services.btrfs-scrub-backup = {
    description = "Scrub the backup btrfs filesystem";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.btrfs-progs}/bin/btrfs scrub start -B ${backupMount}";
    };
    unitConfig.RequiresMountsFor = [ backupMount ];
  };
  systemd.timers.btrfs-scrub-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly";
      Persistent = true;
    };
  };

  # First install of this host. Leave it pinned to the release planb was first
  # built from; do not bump it on upgrades.
  system.stateVersion = "25.05";
}
