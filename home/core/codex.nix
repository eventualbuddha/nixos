{
  pkgs,
  lib,
  config,
  ...
}:

let
  binDir = "${config.home.homeDirectory}/.local/bin";
in
{
  # Codex (OpenAI's coding agent CLI) gets the same treatment as Claude Code
  # in ./claude-code.nix: nix bootstraps a self-updating native install into
  # ~/.local/bin once, then gets out of the way. nixpkgs does have `codex`, but
  # the standalone build keeps itself current (the installer records an
  # auto-update channel under ~/.codex/packages/standalone), and a store path
  # on the profile would both freeze it and shadow that install. (On
  # 2026-09-22 the installer fetched 0.156.0 against nixpkgs' 0.147.0.)
  #
  # Unlike `claude install`, the nixpkgs build has no subcommand that lays down
  # the standalone install -- `codex update` only updates whatever is running --
  # so this uses upstream's documented installer, the way home/moshi.nix does.
  # Fetched to a file and run rather than piped into a shell, for the same
  # reasons given there.
  #
  # The installer's environment is pinned down so that it does exactly one
  # thing:
  #   - binDir is prepended to PATH. The installer appends an `export PATH`
  #     block to ~/.bashrc / ~/.profile when it does not see its install dir on
  #     PATH, and activation's PATH never has it. Those files are home-manager
  #     symlinks into the store; home.sessionPath (./claude-code.nix) already
  #     covers PATH declaratively.
  #   - CODEX_NON_INTERACTIVE skips its "Start Codex now?" prompt.
  #   - CODEX_INSTALL_DIR is set even though it is the default, so this does
  #     not silently move if upstream changes it.
  #   - Everything it shells out to comes from the store: activation's PATH is
  #     restricted, and a missing tool mid-run plus `|| true` would be a
  #     near-silent no-op (the lesson recorded in home/moshi.nix).
  #
  # Guarded on the binary already existing so the steady state does no network
  # I/O, and `|| true` because activation aborts at its first failing step (see
  # installLazyVim in home/core/editor.nix).
  #
  # On the vxsuite build VM this is currently a no-op: vmguard's egress filter
  # does not allowlist chatgpt.com (the installer), releases.openai.com (the
  # binaries), or any OpenAI inference host, so codex would not work there
  # even if installed.
  home.activation.bootstrapCodex = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -e "${binDir}/codex" ]; then
      run ${pkgs.curl}/bin/curl -fsSL --create-dirs -o "$HOME/.cache/codex-install.sh" \
        https://chatgpt.com/codex/install.sh \
        && PATH="${binDir}:${
          lib.makeBinPath [
            pkgs.coreutils # mktemp, uname, sha256sum, readlink, ln, mv, ...
            pkgs.gnutar
            pkgs.gzip
            pkgs.curl
            pkgs.gawk # release-metadata JSON parsing
            pkgs.gnused
            pkgs.gnugrep
            pkgs.findutils
            pkgs.procps # ps, for its updater-parent check
            pkgs.util-linux # flock, for its install lock
          ]
        }:$PATH" \
           CODEX_INSTALL_DIR="${binDir}" \
           CODEX_NON_INTERACTIVE=1 \
           run ${pkgs.bash}/bin/sh "$HOME/.cache/codex-install.sh" \
        || true
    fi
  '';
}
