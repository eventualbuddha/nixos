{
  description = "brian's NixOS config: niri + ghostty + noctalia";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    niri.url = "github:sodiboo/niri-flake";

    # LazyVim starter, seeded into ~/.config/nvim by home/editor.nix. Not a
    # flake -- just a source tree to copy from, pinned so the bootstrap is
    # reproducible and needs no network at activation time.
    lazyvim-starter = {
      url = "github:LazyVim/starter";
      flake = false;
    };

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
      # Plain nixpkgs instance for the outputs that are not a nixosSystem
      # (standalone home-manager): there is no NixOS around to inherit
      # `nixpkgs.config` from, so allowUnfree has to be set here.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

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

      # Standalone home-manager, for machines that are not NixOS. `vx` is the
      # Debian 12 VM vxsuite is built in -- Debian on purpose, since that is
      # what VotingWorks ships on and parts of the repo assume it. It gets
      # home/core (the portable half) and none of home/desktop.
      #
      #   nix run home-manager/master -- switch --flake ~/nixos#vx@vxdev
      homeConfigurations."vx@vxdev" = home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsFor "x86_64-linux";
        extraSpecialArgs = { inherit inputs; };
        modules = [ ./hosts/vxdev/home.nix ];
      };
    };
}
