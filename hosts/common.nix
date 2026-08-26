# Shared system configuration, imported by every host in hosts/<name>/configuration.nix.
# Host files should only contain what's actually specific to that machine:
# ./hardware-configuration.nix, networking.hostName, and any hardware quirks
# (GPU driver, extra kernel params, etc).

{
  config,
  pkgs,
  inputs,
  ...
}:

{
  # Bootloader.
  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;

    # Use latest kernel.
    kernelPackages = pkgs.linuxPackages_latest;
  };

  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "America/Los_Angeles";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
  };

  i18n.supportedLocales = [
    "en_US.UTF-8/UTF-8"
  ];

  # Enable the X11 windowing system.
  services.xserver.enable = true;

  # Enable the GNOME Desktop Environment. Kept enabled as a fallback session
  # alongside niri -- GDM will offer both at the login screen.
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # GNOME's keyring provides an SSH agent, and gcr loads ~/.ssh keys into it on
  # demand. It advertises FIDO/"sk" keys but cannot sign with them -- there is
  # no security-key provider behind it -- so once it picks up
  # id_ed25519_sign_sk, signing dies with "agent refused operation". That is a
  # hard failure, not a slow path: `ssh-keygen -Y sign` uses the agent whenever
  # the agent claims the key, with no fallback to reading the file. It is also
  # an intermittent-looking one, since the key is only loaded on first use --
  # commits sign fine right up until something touches the agent.
  #
  # Every key on these machines is an sk key, so the gcr agent has nothing it
  # can usefully hold. OpenSSH's own agent does support them.
  services.gnome.gcr-ssh-agent.enable = false;
  programs.ssh.startAgent = true;

  # niri, added alongside GNOME. This also wires up desktop portals/polkit
  # and registers a Wayland session entry that GDM will list.
  #
  # Using nixpkgs' own `niri` package (not niri-flake's niri-stable/cache build):
  # niri-flake's pinned build wants an older libdisplay-info that's been removed
  # from the nixpkgs revision we're on, so we build from the same nixpkgs tree as
  # everything else instead of niri-flake's separately-pinned one.
  programs.niri.enable = true;
  programs.niri.package = pkgs.niri;

  # Flatpak, for apps not in nixpkgs (e.g. Fastmail's Flathub build). A
  # second, non-declarative package manager living alongside everything
  # else here -- used only for the handful of things that need it.
  services.flatpak.enable = true;

  # virt-manager (libvirt/QEMU-KVM), for local VMs. OVMF (UEFI guest firmware)
  # ships by default now, no separate opt-in needed.
  virtualisation.libvirtd.enable = true;
  programs.virt-manager.enable = true;

  # Tailscale. `trustedInterfaces` skips the firewall for anything already
  # on the tailnet; the UDP port is opened so peers can connect directly
  # instead of relaying through a DERP server. Authenticating this machine
  # (`sudo tailscale up`, opens a browser login) is a one-time manual step --
  # not something to script.
  services.tailscale.enable = true;
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];

  # 1Password (CLI + GUI, with polkit/browser-integration wrappers).
  programs._1password.enable = true;
  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "brian" ];
  };

  # Lets dynamically-linked binaries (e.g. Mason-installed LSP servers used by
  # LazyVim) run on NixOS.
  programs.nix-ld.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Shells.
  programs.fish.enable = true;

  # Define a user account. Don't forget to set a password with `passwd`.
  users.users."brian" = {
    isNormalUser = true;
    description = "Brian Donovan";
    extraGroups = [
      "networkmanager"
      "wheel"
      "libvirtd"
    ];
    shell = pkgs.fish;
    packages = with pkgs; [
      #  thunderbird
    ];
  };

  programs.ssh = {
    extraConfig = ''
      # VotingWorks VM (Tailscale)
      # ControlMaster/ControlPersist: keeps home/tunnels.nix's per-connection
      # `ssh -W` forwards to vx.ts from renegotiating a full handshake every
      # time a browser tab (re)connects to localhost:3000 -- the first one
      # opens the real connection, later ones multiplex over it, and it's
      # dropped after 10 minutes with no channels using it.
      Host vx.ts
        HostName 100.79.161.93
        Port 2222
        User vx
        ControlMaster auto
        ControlPath ~/.ssh/cm-%r@%h:%p
        ControlPersist 10m

      # VotingWorks Desktop (Tailscale)
      Host vx-host.ts
        HostName 100.79.161.93
        User brian
    '';
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    users."brian" = import ../home;
    # Pre-existing dotfiles (e.g. ~/.config/fish/config.fish) get backed up
    # with this suffix instead of making activation fail outright.
    backupFileExtension = "backup";
  };

  # Install firefox.
  programs.firefox.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Fonts: Nerd Font (ghostty/noctalia glyphs) + broad Unicode/emoji coverage.
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts
    noto-fonts-color-emoji
  ];

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    wget
    curl
    neovim
    git
    pam_u2f # provides `pamu2fcfg`, used to enroll a YubiKey below
  ];

  # YubiKey for sudo + GUI polkit prompts only (not GDM login).
  # control = "sufficient" (this is NixOS's own default -- restated here so it's
  # obvious that password auth always still works, key or no key).
  security.pam.u2f = {
    enable = false; # keep the global default off; opt in per-service below
    control = "sufficient";
    # cue=false: with it on, the password fell back to *visibly echoing* on
    # screen every time the key wasn't touched (reliably reproducible) --
    # the "touch your device" reminder writes to the tty outside PAM's
    # normal conversation flow, and something in that path was leaving
    # echo in the wrong state by the time pam_unix's password prompt ran.
    # Auth itself was never affected, only the on-screen echo.
    settings.cue = false;
  };
  security.pam.services.sudo.u2f.enable = true;
  security.pam.services.polkit-1.u2f.enable = true;

  # On-screen "your YubiKey wants a touch" notification, for both machines.
  # Every touch-gated operation here is silent by default -- sudo and polkit
  # via pam_u2f, git signing and ssh via the sk- keys -- and the only feedback
  # is the key itself blinking, wherever it happens to be plugged in. pam_u2f's
  # own `cue` is not the answer: it is disabled deliberately (see the echo bug
  # noted on security.pam.u2f above), and it would only ever cover the tty
  # case, never a polkit dialog or a `git commit` from an editor.
  #
  # This detects touch requests by listening on /dev/hidraw* for them as per
  # the FIDO spec, so one mechanism covers all of the above rather than just
  # one path. It runs as a systemd user service and reads the device through
  # the uaccess ACL systemd already grants the logged-in user, so it needs no
  # privileges of its own. Verified against a real signing request: the U2F
  # watcher fires the moment the key is asked for a touch.
  #
  # It also ships GPG and ssh-agent watchers, which will log that they are
  # disabled -- there is no gpg-agent here and nothing uses the OpenPGP
  # applet. Harmless; the U2F watcher is the one that matters.
  #
  # Notifications go out over org.freedesktop.Notifications, served by
  # noctalia under niri and by gnome-shell under GNOME.
  programs.yubikey-touch-detector.enable = true;

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "26.05"; # Did you read the comment?

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}
