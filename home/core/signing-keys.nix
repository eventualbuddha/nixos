# Public halves of the git signing keys, one per machine, plus the renderer for
# OpenSSH's allowed_signers format.
#
# Kept as plain data (not a module) so that a machine which needs a different
# set -- the vxsuite build VM has no YubiKey and signs with a plain ed25519 key
# -- can import this, add its own entry, and render the same file without
# either duplicating these literals or forcing its key onto judy and work.
#
# On judy and work these are non-resident sk- keys: the private handle lives
# only in ~/.ssh/id_ed25519_sign_sk on the machine that generated it and cannot
# be re-downloaded from the token, so each machine gets its own rather than
# trying to share one file around. Every machine trusts all of them, which is
# what makes `git log --show-signature` verify the other machine's commits.
# Adding a machine means generating a key there (see `signing` in git.nix) and
# appending its .pub line here.
#
# Public key material, so it belongs in the flake as literal text -- it is the
# same string you would paste into GitHub as a Signing Key.
{
  keys = {
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

  # lib is passed in rather than captured so this stays a plain data file with
  # no import of nixpkgs.
  render =
    lib: keys:
    lib.concatMapStrings (
      entry: "${lib.concatStringsSep "," entry.principals} ${entry.key}\n"
    ) (lib.attrValues keys);
}
