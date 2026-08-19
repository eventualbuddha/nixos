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

  # Bambu Studio: only judy has a Bambu printer, so keep this off other hosts.
  environment.systemPackages = [ pkgs.bambu-studio ];
}
