{
  pkgs,
  lib,
  config,
  ...
}:

let
  signingData = import ./signing-keys.nix;
in
{
  programs.git = {
    enable = true;
    settings.user = {
      name = "Brian Donovan";
      # mkDefault so a host can commit under a different address without
      # having to mkForce past this -- hosts/work does exactly that.
      email = lib.mkDefault "brian@donovans.cc";
    };

    # What `gh auth login` tries to write for itself on its last step, and
    # cannot here: ~/.config/git/config is a home-manager symlink into the
    # store, so it fails with "could not lock config file ... Read-only file
    # system". The login itself still succeeds -- the token goes to the
    # keyring and ~/.config/gh stays writable -- so the only casualty is this
    # helper, which leaves HTTPS pushes prompting for a password that GitHub
    # no longer accepts. Declaring it is strictly better than letting gh
    # write it anyway: it applies on a fresh machine before `gh auth login`
    # has ever run.
    #
    # Full store path rather than a bare `gh`: git runs credential helpers
    # through a shell whose PATH is not necessarily the interactive one.
    settings.credential = {
      "https://github.com".helper = lib.mkDefault "!${pkgs.gh}/bin/gh auth git-credential";
      "https://gist.github.com".helper = lib.mkDefault "!${pkgs.gh}/bin/gh auth git-credential";
    };

    # SSH-format signing (git natively supports this since 2.34, GitHub
    # verifies it since 2022) -- reuses ssh-keygen instead of standing up a
    # separate GPG keyring. Dedicated YubiKey key, kept distinct from the
    # id_ed25519_sk auth key from setup-ssh-yubikey.sh: GitHub treats
    # "Authentication Key" and "Signing Key" as distinct roles, and a
    # signing key alone can't be used to log in anywhere, so keeping it
    # separate limits what a compromised/rotated key affects. Generate it
    # once, manually (touch required, not something Nix can do):
    #   ssh-keygen -t ed25519-sk -f ~/.ssh/id_ed25519_sign_sk \
    #     -C "brian@donovans.cc (git signing)"
    # then add the .pub as a *Signing Key* (not Authentication Key) at
    # https://github.com/settings/keys.
    #
    # Deliberately NOT -O resident, and the same goes for the auth key. A
    # resident credential is identified by (application, username), which
    # ssh-keygen defaults to "ssh:" and an empty username -- so generating
    # either key evicted the other, silently, and this key was destroyed
    # twice that way before both were made non-resident. The cost of
    # non-resident is that ~/.ssh/id_ed25519_sign_sk is the only copy of the
    # key handle: back it up, because `ssh-keygen -K` cannot re-download it
    # (that needs a FIDO PIN, which this touch-only setup does not set).
    #
    # mkDefault on both: a machine with no YubiKey attached (the vxsuite build
    # VM) cannot use an sk- key at all and points these at a plain ed25519
    # key instead. Without mkDefault that override needs mkForce.
    signing = {
      key = lib.mkDefault "${config.home.homeDirectory}/.ssh/id_ed25519_sign_sk.pub";
      format = "ssh";
      signByDefault = lib.mkDefault true;
    };

    # Lets `git log --show-signature` verify locally instead of only
    # trusting GitHub's "Verified" badge. Can't just point this at the
    # .pub file above -- the allowed_signers format needs a principal
    # (email) prefixed onto each line, which a plain .pub file doesn't
    # have. The key material itself is public (it's the same string
    # you'd paste into GitHub as a Signing Key), so it's fine as literal
    # text checked into the flake rather than read from disk at eval time.
    settings.gpg.ssh.allowedSignersFile = "${config.home.homeDirectory}/.config/git/allowed_signers";
  };

  # mkDefault so a machine with a different key set (the vxsuite build VM)
  # can render its own without mkForce -- see hosts/vxdev/home.nix.
  xdg.configFile."git/allowed_signers".text = lib.mkDefault (
    signingData.render lib signingData.keys
  );
}
