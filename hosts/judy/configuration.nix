# Host-specific config for "judy". Everything shared across machines lives in
# ../common.nix -- this file should only grow hardware quirks specific to this
# box (GPU driver, extra kernel params, etc).

{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../common.nix
  ];

  networking.hostName = "judy";

  # judy has 16G RAM and no swap, which meant a heavy from-source build (e.g.
  # bambu-studio's CGAL/OpenCASCADE/wxWidgets dependency tree) could blow past
  # physical memory and get OOM-killed instead of paging out. zram gives the
  # kernel somewhere to page under pressure without needing a swap partition.
  zramSwap.enable = true;

  # Bambu Studio: only judy has a Bambu printer, so keep this off other hosts.
  #
  # Wrapped to force LC_ALL=en_US.UTF-8: common.nix sets LC_TIME=en_DK.UTF-8
  # (the ISO-date trick), but en_DK.UTF-8 never actually got compiled into
  # this system's locale archive (`locale -a` doesn't list it) even though
  # it's in i18n.supportedLocales -- root cause still unclear. Most programs
  # just silently fall back to C when a locale can't be resolved, but
  # bambu-studio's std::locale("") construction throws instead, aborting on
  # startup. Overriding just this program's env sidesteps that without
  # touching the (already-broken, but silently so) system-wide setting.
  environment.systemPackages = [
    (pkgs.symlinkJoin {
      name = "bambu-studio-wrapped";
      paths = [ pkgs.bambu-studio ];
      buildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        rm $out/bin/bambu-studio
        makeWrapper ${pkgs.bambu-studio}/bin/bambu-studio $out/bin/bambu-studio \
          --set LC_ALL en_US.UTF-8
      '';
    })
  ];
}
