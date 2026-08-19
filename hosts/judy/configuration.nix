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
  environment.systemPackages = [ pkgs.bambu-studio ];
}
