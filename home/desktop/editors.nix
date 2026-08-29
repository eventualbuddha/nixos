{ pkgs, ... }:

{
  # GUI editors, alongside the neovim in home/core/editor.nix rather than
  # instead of it. In home/desktop and not home/core because both are graphical
  # applications: the vxsuite build VM is headless and reached over SSH, where
  # these would be dead weight (and vscode there is better used as a remote
  # target from the host anyway).
  #
  # Plain packages, not `programs.vscode` / `programs.zed-editor` -- both
  # home-manager modules exist, and both are declined for the same reason
  # home/core/editor.nix declines `programs.neovim`: these editors expect to own
  # their own config at runtime. Settings get edited from inside the app,
  # extensions install themselves, and vscode's Settings Sync writes the same
  # files; pointing those paths at read-only store symlinks turns every one of
  # those into a confusing failure. Worth revisiting only if the settings are
  # ever worth pinning more than they are worth editing in place.
  #
  # vscode is unfree -- fine here, hosts/common.nix sets
  # nixpkgs.config.allowUnfree. Use `vscodium` instead if the telemetry and the
  # non-free marketplace terms ever start to matter.
  home.packages = with pkgs; [
    vscode
    zed-editor
  ];
}
