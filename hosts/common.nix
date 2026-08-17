# Shared system configuration, imported by every host in hosts/<name>/configuration.nix.
# Host files should only contain what's actually specific to that machine:
# ./hardware-configuration.nix, networking.hostName, and any hardware quirks
# (GPU driver, extra kernel params, etc).

{ config, pkgs, inputs, ... }:

{
  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

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
    LC_TIME = "en_US.UTF-8";
  };

  # Enable the X11 windowing system.
  services.xserver.enable = true;

  # Enable the GNOME Desktop Environment. Kept enabled as a fallback session
  # alongside niri -- GDM will offer both at the login screen.
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # niri, added alongside GNOME. This also wires up desktop portals/polkit
  # and registers a Wayland session entry that GDM will list.
  #
  # Using nixpkgs' own `niri` package (not niri-flake's niri-stable/cache build):
  # niri-flake's pinned build wants an older libdisplay-info that's been removed
  # from the nixpkgs revision we're on, so we build from the same nixpkgs tree as
  # everything else instead of niri-flake's separately-pinned one.
  programs.niri.enable = true;
  programs.niri.package = pkgs.niri;

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
    extraGroups = [ "networkmanager" "wheel" ];
    shell = pkgs.fish;
    packages = with pkgs; [
      #  thunderbird
    ];
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    users."brian" = import ../home;
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
    settings.cue = true;
  };
  security.pam.services.sudo.u2f.enable = true;
  security.pam.services.polkit-1.u2f.enable = true;

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

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
