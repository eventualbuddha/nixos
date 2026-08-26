{
  pkgs,
  lib,
  config,
  ...
}:

let
  # Public halves of the YubiKey-backed git signing keys, one per machine.
  # These are non-resident sk- keys: the private handle lives only in
  # ~/.ssh/id_ed25519_sign_sk on the machine that generated it and cannot be
  # re-downloaded from the token, so each machine gets its own rather than
  # trying to share one file around. Every machine trusts all of them, which
  # is what makes `git log --show-signature` verify the other machine's
  # commits. Adding a machine means generating a key there (see the comment on
  # `signing` below) and appending its .pub line here.
  #
  # Public key material, so it belongs in the flake as literal text -- it is
  # the same string you would paste into GitHub as a Signing Key.
  signingKeys = {
    judy = {
      principals = [ "brian@donovans.cc" ];
      key = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIHnmvv0Kzy7ESc0ghCgBngWIuVw0V+VAFFzfxEXNuebFAAAABHNzaDo=";
    };
    # Commits made on work carry the work email (see hosts/work), so this key
    # is trusted for both principals: the personal one for anything committed
    # here before that override landed, and the work one for everything after.
    work = {
      principals = [
        "brian@donovans.cc"
        "brian@voting.works"
      ];
      key = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIC6fscqgOvUDeta3U1/jTipzwfS0B3KrA7VYwbR9hGWgAAAABHNzaDo=";
    };
  };

  # herdr isn't in nixpkgs. Building it from source isn't practical: it
  # vendors Ghostty's libghostty-vt (a Zig library) and pulls in Ghostty's
  # own Zig dependency-fetching machinery to build it -- nixpkgs' own
  # `ghostty` package already solves that problem, but it's substantial
  # machinery not worth re-deriving just for this. Its GitHub release
  # binaries are fully static (`file` reports "static-pie linked", no
  # `.interp` section) though, so no autoPatchelfHook/dynamic-linking dance
  # is needed -- just fetch and drop it in $out/bin. Bump `version` and
  # `hash` (via `nix store prefetch-file --json <release-url>`) to update.
  herdr =
    let
      version = "0.8.2";
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "herdr";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://github.com/herdrdev/herdr/releases/download/v${version}/herdr-linux-x86_64";
        hash = "sha256-l2FQoU1JDJSyQ+ouGn6y37Z/EuNrGC25CTb2co5q7PQ=";
      };
      dontUnpack = true;
      installPhase = ''
        runHook preInstall
        install -Dm755 $src $out/bin/herdr
        runHook postInstall
      '';
      meta = {
        description = "Terminal workspace manager for AI coding agents";
        homepage = "https://herdr.dev";
        license = pkgs.lib.licenses.asl20;
        platforms = [ "x86_64-linux" ];
        mainProgram = "herdr";
      };
    };
in
{
  home = {
    packages = with pkgs; [
      rustup
      nodejs_22
      lazygit
      gcc
      git
      claude-code
      uv # python project/venv/interpreter management (pip/poetry/pyenv replacement)
      herdr
    ];

    # `npm install -g` can't write into the Nix store (where nodejs_22 lives), so
    # point npm's global prefix at a writable directory in $HOME instead -- this
    # makes `npm install -g <pkg>` work exactly like it would anywhere else.
    sessionVariables.NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/.npm-global";
    sessionPath = [ "${config.home.homeDirectory}/.npm-global/bin" ];
  };

  programs = {
    # Per-project toolchain pinning (the NixOS-native analog to mise/proto/volta):
    # a project's own flake.nix/shell.nix + direnv gives fully reproducible,
    # per-directory tool versions via the Nix store. `devenv` (cachix/devenv) is a
    # popular friendlier layer on top of this if you want more mise-like ergonomics
    # later -- not installed here, easy to add.
    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    git = {
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
        "https://github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";
        "https://gist.github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";
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
      signing = {
        key = "${config.home.homeDirectory}/.ssh/id_ed25519_sign_sk.pub";
        format = "ssh";
        signByDefault = true;
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
  };

  xdg.configFile."git/allowed_signers".text = lib.concatMapStrings (
    entry: "${lib.concatStringsSep "," entry.principals} ${entry.key}\n"
  ) (lib.attrValues signingKeys);
}
