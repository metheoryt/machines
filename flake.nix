{
  description = "Personal NixOS Configuration with Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.05";

    home-manager = {
      # Track master to match nixos-unstable's version string (currently 26.11).
      # release-26.05 lags behind unstable and trips the version-mismatch warning.
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Claude Code — updated hourly (nixpkgs lags behind the rapid release cadence)
    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-stable,
    home-manager,
    nixos-hardware,
    ...
  } @ inputs: let
    system = "x86_64-linux";

    stableOverlay = final: prev: {
      stable = import nixpkgs-stable {
        inherit system;
        config.allowUnfree = true;
      };
    };

    overlays = [
      stableOverlay
      inputs.claude-code-nix.overlays.default
    ];

    nixpkgsConfig = {
      inherit system;
      config = {
        allowUnfree = true;
        allowBroken = false;
        allowUnsupportedSystem = false;
      };
      overlays = overlays;
    };

    specialArgs = {
      inherit inputs system nixpkgs-stable;
    };

    mkHost = hostname: extraModules:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = specialArgs // { inherit hostname; };
        modules =
          [
            ./hosts/${hostname}/configuration.nix
            ./hosts/${hostname}/hardware-configuration.nix
            home-manager.nixosModules.default
            ({...}: { nixpkgs = nixpkgsConfig; })
          ]
          ++ extraModules;
      };

    mkHome = hostname:
      home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs nixpkgsConfig;
        extraSpecialArgs = specialArgs // { inherit hostname; };
        modules = [ ./modules/home/me.nix ];
      };
  in {
    nixosConfigurations = {
      g16 = mkHost "g16" [
        nixos-hardware.nixosModules.common-cpu-intel
        nixos-hardware.nixosModules.common-pc-laptop
        nixos-hardware.nixosModules.common-pc-laptop-ssd
      ];

      latitude5520 = mkHost "latitude5520" [
        nixos-hardware.nixosModules.dell-latitude-5520
      ];
    };

    homeConfigurations = {
      "me@g16" = mkHome "g16";
      "me@latitude5520" = mkHome "latitude5520";
    };

    devShells.${system}.default = nixpkgs.legacyPackages.${system}.mkShell {
      name = "nixos-config-shell";
      packages = with nixpkgs.legacyPackages.${system}; [
        nixfmt-classic
        nil
        nixd
        alejandra
        git
        just
        direnv
        wget
        curl
        jq
        yq
      ];
    };

    formatter.${system} = nixpkgs.legacyPackages.${system}.alejandra;

    checks.${system} = {
      nixos-g16 = self.nixosConfigurations.g16.config.system.build.toplevel;
      nixos-latitude5520 = self.nixosConfigurations.latitude5520.config.system.build.toplevel;
      home-g16 = self.homeConfigurations."me@g16".activationPackage;
      home-latitude5520 = self.homeConfigurations."me@latitude5520".activationPackage;
    };
  };
}
