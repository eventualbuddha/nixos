# Host-specific config for "work" -- Framework Desktop, AMD Ryzen AI Max+ 395
# ("Strix Halo") with a Radeon 8060S iGPU, 128 GB unified memory, 2x 2TB NVMe.
# Everything shared across machines lives in ../common.nix.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  # The guest's address on the `vmguard` bridge: a static DHCP reservation
  # keyed on the guest's MAC in the network definition, so it doesn't drift
  # (hosts/work/vmguard/NOTES.md item 7).
  #
  # Bound to a name because two separate things need it and must not drift
  # apart: the `Host vx` block below, and the relay's proxy target.
  guestAddr = "192.168.124.179";
in
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
  # This is the machine the VM actually runs on, so `ssh vx` is a direct hop
  # across the bridge. Everything else about the alias -- user, agent
  # forwarding, connection multiplexing -- comes from the `Host vx` block in
  # ../common.nix; only the address is host-specific.
  #
  # The guest is defined in libvirt's own state (`virsh dumpxml vxsuite`), not
  # here -- NixOS has no declarative option for libvirt domains.
  programs.ssh.extraConfig = ''
    Host vx
      HostName ${guestAddr}
  '';

  # --- Inbound SSH to the guest, for clients that can't take two hops --------
  #
  # A TCP listener on work that relays to the guest's sshd, so reaching the
  # guest is one connection rather than a ProxyJump. That exists for two
  # reasons: an iOS SSH client that will not do ProxyJump with a 1Password key
  # (which is what a phone has), and judy, where two hops means two YubiKey
  # touches because the key there is touch-only by design.
  #
  # This does NOT weaken the guest's isolation. vmguard blocks guest->internet;
  # this is host->guest, inbound. The guest still has no route off its own
  # subnet and the egress proxy is still its only way out -- the same point
  # NOTES.md item 7 made about the Fedora-era forward that this restores.
  #
  # `systemd-socket-proxyd`, NOT a DNAT rule, and the distinction is the whole
  # reason this is back. libvirt gives an isolated network a pair of
  # `LIBVIRT_FWI/FWO ... -j REJECT` rules, which drop a DNAT'd packet after it
  # has been rewritten -- so a nat-table forward really is unworkable here
  # without an ACCEPT ordered ahead of rules libvirt reinstalls on every network
  # reload. But those are FORWARD-chain rules, and a userspace relay never
  # produces forwarded traffic: it accepts on the host and opens its own
  # connection to the guest, which is locally-originated OUTPUT traffic the
  # REJECT pair never sees. That is why the Fedora forward worked for years
  # while a DNAT attempt did not. Two mechanisms, one name; the failure of the
  # second says nothing about the first.
  #
  # A dumb TCP relay is also what makes this safe to publish. The client's SSH
  # session terminates at the *guest* and verifies the guest's host key; work
  # carries ciphertext and holds no credential for the guest. A ProxyJump, by
  # contrast, makes work an authenticated hop, and an `ssh -W` relay would make
  # it one too.
  #
  # No `networking.firewall.allowedTCPPorts` entry, on purpose: the firewall
  # default-denies inbound and ../common.nix already lists tailscale0 in
  # `trustedInterfaces`, so binding all interfaces here yields a listener the
  # tailnet can reach and the LAN cannot. That is strictly tighter than the
  # Fedora original, which sat on 0.0.0.0:2222 with nothing in front of it.
  systemd.sockets.vx-ssh-forward = {
    description = "Listen for SSH connections bound for the vxsuite guest";
    wantedBy = [ "sockets.target" ];
    socketConfig.ListenStream = "2222";
  };

  systemd.services.vx-ssh-forward = {
    description = "Relay :2222 to the vxsuite guest's sshd";
    # Started by the socket, so no `wantedBy`. `requires` rather than `wants`:
    # without the passed-in listening fd this process has nothing to serve.
    requires = [ "vx-ssh-forward.socket" ];
    after = [ "vx-ssh-forward.socket" ];
    serviceConfig = {
      # Deliberately no `--exit-idle-time`. It would let the relay stop between
      # sessions and be socket-activated again, which is the tidier shape and
      # the one home/desktop/tunnels.nix uses -- but the clients this exists for
      # are a phone and a laptop holding long, mostly-silent sessions, and an
      # idle process is a much cheaper thing to be wrong about than a dropped
      # connection from the couch.
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${guestAddr}:22";
      Restart = "on-failure";
      RestartSec = 2;

      # It moves bytes between two sockets and needs nothing else.
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
    };
  };

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
  # instead of the personal one home/core/git.nix defaults to. The signing
  # key generated on this host is listed under both principals in
  # home/core/signing-keys.nix, so commits from either address still verify
  # everywhere.
  home-manager.users.brian.programs.git.settings.user.email = "brian@voting.works";

  # --- moshi-hook ------------------------------------------------------------
  #
  # Wanted on this machine and on the vxsuite guest, but not on judy, so it is
  # imported here rather than from home/ (which is judy+work) or home/core
  # (every machine). See home/moshi.nix for why it is bootstrapped rather than
  # packaged.
  home-manager.users.brian.imports = [ ../../home/moshi.nix ];
}
