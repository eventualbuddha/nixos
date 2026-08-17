# Host-specific config for "judy". Everything shared across machines lives in
# ../common.nix -- this file should only grow hardware quirks specific to this
# box (GPU driver, extra kernel params, etc).

{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../common.nix
  ];

  networking.hostName = "judy";
}
