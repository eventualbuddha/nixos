{
  pkgs,
  lib,
  config,
  ...
}:

{
  # moshi-hook: the daemon and CLI that installs AI-agent hooks, serves a local
  # Unix socket bridge, and holds a WebSocket to Moshi for approval round-trips.
  #
  # Not in nixpkgs, and deliberately not packaged here even though it is a
  # static Go binary that would package trivially. It ships its own updater
  # (`moshi-hook update`, which checks cdn.getmoshi.app/hook/latest/version.txt)
  # and a store path cannot self-update -- the same argument as
  # home/core/claude-code.nix, and the same resolution: nix bootstraps it once
  # and then gets out of the way.
  #
  # This machine is a good illustration of why that matters: the hand-installed
  # copy had drifted to 0.3.0 against a current v0.3.12.
  #
  # Unlike claude-code there is no nixpkgs package to bootstrap from, so this
  # uses upstream's documented installer. That works here specifically because
  # vmguard already allowlists `getmoshi.app` and `cdn.getmoshi.app` for install
  # (NOTES 42) -- it is the reverse of the claude case, where claude.ai is not
  # listed and the `claude install` subcommand had to be used instead.
  #
  # Note `moshi-hook install` is NOT the binary installer -- it writes agent
  # hook configs. Getting the binary is the shell installer below; keeping it
  # current is `moshi-hook update`.
  #
  # Fetched to a file and then run, rather than piped straight into a shell:
  # activation should not execute a stream it cannot re-read, and if the
  # download half fails there is something on disk to look at. INSTALL_DIR is
  # set explicitly even though ~/.local/bin is the installer's own default, so
  # this does not silently move if upstream changes it.
  #
  # Guarded on the binary already existing, so the steady state does no network
  # I/O -- and `|| true` because activation aborts at its first failing step
  # (see the comment on installLazyVim in home/core/editor.nix for what that
  # cost once).
  # home-manager runs activation with a restricted PATH, which has none of the
  # commands this installer needs -- it failed first on "error: tar is required"
  # and then, past that, on `awk: command not found` while parsing checksums.txt.
  # Only the first of those is one of the script's own `command -v` guards, so
  # scanning for those is not enough; the rest fail mid-run. Combined with
  # `|| true` that would have been a near-silent no-op on a fresh machine, so
  # everything it reaches for is supplied from the store rather than the host.
  home.activation.bootstrapMoshiHook = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -e "${config.home.homeDirectory}/.local/bin/moshi-hook" ]; then
      run ${pkgs.curl}/bin/curl -fsSL -o "$HOME/.cache/moshi-install.sh" \
        https://getmoshi.app/install.sh \
        && PATH="${
          lib.makeBinPath [
            pkgs.coreutils # uname, mktemp, chmod, mv, mkdir, ln, tr, sha256sum
            pkgs.gnutar
            pkgs.gzip
            pkgs.curl
            pkgs.gawk # checksum field extraction
            pkgs.gnugrep
          ]
        }:$PATH" \
           INSTALL_DIR="${config.home.homeDirectory}/.local/bin" \
           run ${pkgs.bash}/bin/bash "$HOME/.cache/moshi-install.sh" \
        || true
    fi
  '';
}
