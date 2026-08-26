{
  description = "brian's NixOS config: niri + ghostty + noctalia, with GNOME kept as a fallback session";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    niri.url = "github:sodiboo/niri-flake";

    noctalia = {
      url = "github:noctalia-dev/noctalia";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
      };
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      niri,
      noctalia,
      zen-browser,
      ...
    }@inputs:
    let
      # Add a new machine by dropping a hosts/<name>/{configuration.nix,
      # hardware-configuration.nix} (the latter from `nixos-generate-config`
      # on that machine) and adding one line below: `<name> = mkHost "<name>";`.
      # Everything shared (niri/ghostty/noctalia/home-manager/etc.) comes from
      # hosts/common.nix and home/ automatically.
      mkHost =
        name:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [
            ./hosts/${name}/configuration.nix
            niri.nixosModules.niri
            home-manager.nixosModules.default
          ];
        };
    in
    {
      nixosConfigurations = {
        judy = mkHost "judy";
        work = mkHost "work";
      };
    };
}
