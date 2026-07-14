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

    # Pre-commit hooks (alejandra/deadnix/statix/shellcheck/hygiene), Nix-pinned.
    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
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

    stableOverlay = _: _: {
      stable = import nixpkgs-stable {
        inherit system;
        config.allowUnfree = true;
      };
    };

    # python-lsp-server 1.14.0 crashes in pylsp_definitions on builtin/compiled
    # definitions (d.line is None), which gortex hits constantly driving pylsp
    # for Python resolution. Build from our fork commit carrying the upstream fix
    # (PR https://github.com/python-lsp/python-lsp-server/pull/715, fixes
    # #623/#624). The fix is in-tree, so we override src only and keep nixpkgs'
    # own patches (jedi-compat test fix). Revert to plain nixpkgs once the PR
    # merges and ships in a release.
    pylspFixOverlay = final: prev: {
      pythonPackagesExtensions =
        prev.pythonPackagesExtensions
        ++ [
          (_: pyprev: {
            python-lsp-server = pyprev.python-lsp-server.overrideAttrs (_: {
              version = "1.14.1.dev0+pr715";
              src = final.fetchFromGitHub {
                owner = "metheoryt";
                repo = "python-lsp-server";
                rev = "e4ee21862ba0b2abdfde43f583b0a709d2f9bfb9";
                hash = "sha256-F0mqDcjBT9DvTiJhDMWEKfDODdqDB+cY25mG5ZbcFAA=";
              };
            });
          })
        ];
    };

    overlays = [
      stableOverlay
      pylspFixOverlay
      inputs.claude-code-nix.overlays.default
    ];

    nixpkgsConfig = {
      inherit system;
      config = {
        allowUnfree = true;
        allowBroken = false;
        allowUnsupportedSystem = false;
      };
      inherit overlays;
    };

    specialArgs = {
      inherit inputs system nixpkgs-stable;
    };

    mkHost = hostname: extraModules:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = specialArgs // {inherit hostname;};
        modules =
          [
            ./hosts/${hostname}/nixos/configuration.nix
            ./hosts/${hostname}/nixos/hardware-configuration.nix
            home-manager.nixosModules.default
            (_: {nixpkgs = nixpkgsConfig;})
          ]
          ++ extraModules;
      };

    mkHome = hostname:
      home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs nixpkgsConfig;
        extraSpecialArgs = specialArgs // {inherit hostname;};
        modules = [./modules/home/me.nix];
      };

    # Pre-commit hooks. Installs .git/hooks/pre-commit on `nix develop`, and is
    # also surfaced as a flake check so `just check` / `nix flake check` enforce
    # the same hooks. deadnix/statix start blocking — loosen if too noisy.
    pre-commit-check = inputs.git-hooks-nix.lib.${system}.run {
      src = ./.;
      hooks = {
        alejandra.enable = true;
        # hardware-configuration.nix is auto-generated (never hand-edited), so
        # keep the Nix linters off it.
        deadnix = {
          enable = true;
          excludes = ["hardware-configuration\\.nix"];
        };
        # repeated_keys is disabled via ./statix.toml: collision-style
        # `services.x = …; services.y = …;` is idiomatic NixOS, not a smell.
        statix = {
          enable = true;
          excludes = ["hardware-configuration\\.nix"];
        };
        # Only fail on warnings/errors; the hand-tuned scripts carry intentional
        # info-level style (SC2059/SC2016/SC1091).
        shellcheck = {
          enable = true;
          args = ["--severity=warning"];
        };
        trim-trailing-whitespace.enable = true;
        end-of-file-fixer.enable = true;
        check-merge-conflicts.enable = true;
        check-added-large-files.enable = true;
      };
    };
  in {
    nixosConfigurations = {
      latitude = mkHost "latitude" [
        nixos-hardware.nixosModules.dell-latitude-5520
      ];
    };

    homeConfigurations = {
      "me@latitude" = mkHome "latitude";
    };

    devShells.${system}.default = nixpkgs.legacyPackages.${system}.mkShell {
      name = "nixos-config-shell";
      # Installs the git pre-commit hook on shell entry.
      inherit (pre-commit-check) shellHook;
      buildInputs = pre-commit-check.enabledPackages;
      packages = with nixpkgs.legacyPackages.${system}; [
        nixfmt
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
      nixos-latitude = self.nixosConfigurations.latitude.config.system.build.toplevel;
      home-latitude = self.homeConfigurations."me@latitude".activationPackage;
      pre-commit = pre-commit-check;
    };
  };
}
