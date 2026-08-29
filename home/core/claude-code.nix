{
  pkgs,
  lib,
  config,
  ...
}:

let
  # Which release channel a fresh machine starts on. The native build
  # self-updates within its channel afterwards, so this only decides the
  # starting point -- and, since it is a channel rather than a pin, which track
  # it keeps following.
  #
  # "latest" rather than the installer's own "stable" default: stable trails
  # noticeably (2.1.236 vs 2.1.251 on 2026-08-28), and a machine bootstrapped
  # onto stable would then keep self-updating along stable, staying behind the
  # machines that were set up by hand. Valid targets are "stable", "latest", or
  # an exact version.
  channel = "latest";
in
{
  # Claude Code is deliberately NOT in home.packages, even though nixpkgs has a
  # `claude-code`. It ships its own updater and uses it: this VM's install had
  # walked itself to 2.1.251 while the pinned nixpkgs had 2.1.234. A store path
  # cannot self-update, so putting it on the profile both freezes the version
  # until the next `nix flake update` and silently shadows the newer install
  # already on the machine.
  #
  # So nix bootstraps it and then gets out of the way. `claude install` is the
  # native installer's own entry point -- the same thing the documented
  # `claude.ai/install.sh` one-liner ends up invoking -- and it leaves a
  # self-updating build in ~/.local/bin.
  #
  # pkgs.claude-code is referenced by full store path rather than installed,
  # the same trick home/core/git.nix uses for gh: it is a dependency of the
  # bootstrap, not something that should sit on PATH competing with the result.
  #
  # Why the subcommand and not `curl -fsSL https://claude.ai/install.sh | bash`:
  # on the vxsuite build VM, vmguard's egress filter does not allowlist
  # claude.ai -- the request comes back 403 "host not on allowlist" -- while
  # storage.googleapis.com, where the release binaries actually live and where
  # `claude install` fetches from, is already in READ_ONLY_HOSTS. The
  # subcommand works on every machine; the curl one-liner does not.
  #
  # Why an activation script and not a systemd unit: this mirrors
  # installLazyVim in home/core/editor.nix, and like it is guarded on the
  # artifact already existing, so the steady state does no network I/O at all
  # -- only a machine with no claude yet reaches out. The `|| true` is the
  # lesson from that same file: activation aborts at its first failing step,
  # and a network fetch at boot (before DNS is up) once took out every step
  # after it, linkGeneration included. A failed bootstrap here just means
  # claude is missing until the next switch, which is recoverable.
  home.activation.bootstrapClaudeCode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -e "$HOME/.local/bin/claude" ]; then
      run ${pkgs.claude-code}/bin/claude install ${channel} || true
    fi
  '';

  # Where `claude install` puts it. On NixOS there is otherwise no ~/.local/bin
  # on PATH at all -- home-manager's packages live in
  # /etc/profiles/per-user/$USER/bin -- so without this the bootstrap would
  # install something nothing could find. (The vxsuite VM already has it via a
  # hand-written ~/.config/fish/conf.d/local-bin.fish; this makes it declarative
  # and machine-independent.)
  home.sessionPath = [ "${config.home.homeDirectory}/.local/bin" ];
}
