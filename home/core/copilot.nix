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
  # GitHub Copilot CLI, bootstrapped like ./codex.nix: the standalone build
  # auto-updates itself, so nixpkgs' `github-copilot-cli` would freeze and
  # shadow it. The installer is fetched from raw.githubusercontent.com rather
  # than the documented gh.io short link, which vmguard does not allowlist;
  # the release tarball it downloads is already readable through vmguard.
  #
  # binDir leads PATH so the installer finds `copilot` on it and skips its
  # interactive "add to your shell rc?" prompt.
  home.activation.bootstrapCopilot = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -e "${binDir}/copilot" ]; then
      run ${pkgs.curl}/bin/curl -fsSL --create-dirs -o "$HOME/.cache/copilot-install.sh" \
        https://raw.githubusercontent.com/github/copilot-cli/main/install.sh \
        && PATH="${binDir}:${
          lib.makeBinPath [
            pkgs.coreutils # uname, mktemp, sha256sum, id, mkdir, chmod, basename
            pkgs.gnutar
            pkgs.gzip
            pkgs.curl
          ]
        }:$PATH" \
           PREFIX="${config.home.homeDirectory}/.local" \
           run ${pkgs.bash}/bin/bash "$HOME/.cache/copilot-install.sh" \
        || true
    fi
  '';
}
