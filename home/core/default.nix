_:

{
  # Portable home config: everything here works on any Linux, with or without
  # NixOS, and with or without a graphical session. This is the set a
  # standalone home-manager install on a Debian box imports (see
  # hosts/vxdev/home.nix); NixOS machines get it via home/default.nix
  # alongside home/desktop.
  #
  # The rule for what belongs here: no NixOS modules, no `osConfig`, no
  # Wayland/GTK/compositor assumptions, and no language toolchains (those are
  # per-project -- see home/toolchains.nix).
  imports = [
    ./shell.nix
    ./cli.nix
    ./editor.nix
    ./git.nix
  ];
}
