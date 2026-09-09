{
  description = "John's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-jzila.url = "github:jzila/nixpkgs/jzila/orca-slicer";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager-unstable = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    nix-vscode-extensions = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    plasma-manager = {
      url = "github:pjones/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    beads = {
      url = "github:steveyegge/beads/v0.49.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    wifitui = {
      url = "github:shazow/wifitui";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    jzila-derivations = {
      url = "github:jzila/nix-derivations";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    devenv = {
      url = "github:cachix/devenv/latest";
    };

    mac-app-util = {
      url = "github:hraban/mac-app-util";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixpkgs-jzila, home-manager, home-manager-unstable, nix-darwin, ... }@inputs:
    let
      # Helper to create pkgs for a given system
      mkPkgs = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        # Only enable ROCm on Linux (AMD GPU support)
        config.rocmSupport = system == "x86_64-linux";
      };

      mkPkgsUnstable = system: import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
        config.rocmSupport = system == "x86_64-linux";
      };

      mkPkgsJzila = system: import nixpkgs-jzila {
        inherit system;
        config.allowUnfree = true;
        config.rocmSupport = system == "x86_64-linux";
      };

      # Override beads package with correct vendorHash (upstream hash is outdated)
      mkBeadsFixed = system: inputs.beads.packages.${system}.default.overrideAttrs (old: {
        vendorHash = "sha256-YU+bRLVlWtHzJ1QPzcKJ70f+ynp8lMoIeFlm+29BNPE=";
      });

      lib = nixpkgs.lib;

      # Build standalone NixVim package from shared config
      mkNvim = system: inputs.nixvim.legacyPackages.${system}.makeNixvimWithModule {
        inherit system;
        module = import ./nixvim/config;
      };

      # Packages built from vendored release archives under ./pkgs, rather than
      # taken from nixpkgs. Defined once here so both the `packages` flake
      # output and Home Manager (via the `localPkgs` specialArg below) build
      # the exact same derivations instead of each calling callPackage on its
      # own copy of these paths.
      mkLocalPackages = pkgs-unstable: {
        # opencode from the official release archive. nixpkgs has to re-pin a
        # bun dependency FOD on every bump, so pkgs.opencode trails the
        # upstream tag.
        opencode-bin = pkgs-unstable.callPackage ./pkgs/opencode-bin { };
        # roborev from the official release archive. Upstream dropped the
        # flake it used to ship, and there is no nixpkgs package.
        roborev-bin = pkgs-unstable.callPackage ./pkgs/roborev-bin { };
        # agentsview from the official release archive, for the same reason:
        # no flake upstream and no nixpkgs package.
        agentsview-bin = pkgs-unstable.callPackage ./pkgs/agentsview-bin { };
        # kata from the official release archive, same story.
        kata-bin = pkgs-unstable.callPackage ./pkgs/kata-bin { };
      } // lib.optionalAttrs (lib.hasSuffix "darwin" pkgs-unstable.stdenv.hostPlatform.system) {
        # Zed from the official signed release .dmg. nixpkgs builds it from
        # source and Hydra's aarch64-darwin queue lags the channel, so
        # pkgs.zed-editor here means compiling the whole Rust workspace
        # locally on every bump. Zed only publishes release builds for macOS;
        # Linux uses pkgs.zed-editor.
        zed-editor-bin = pkgs-unstable.callPackage ./pkgs/zed-editor-bin { };
      };

      # Common Home Manager configuration for NixOS
      homeManagerModule = system: let
        pkgs-unstable = mkPkgsUnstable system;
        pkgs-jzila = mkPkgsJzila system;
        beads-fixed = mkBeadsFixed system;
        nvim = mkNvim system;
        localPkgs = mkLocalPackages pkgs-unstable;
        isLinux = true;
        isDarwin = false;
      in {
        imports = [ home-manager.nixosModules.home-manager ];
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.extraSpecialArgs = inputs // {
          inherit pkgs-unstable pkgs-jzila beads-fixed nvim isLinux isDarwin localPkgs;
        };
        home-manager.users.john = import ./home/john/home.nix;
      };

      # Home Manager configuration for nix-darwin
      homeManagerDarwinModule = system: let
        pkgs-unstable = mkPkgsUnstable system;
        nvim = mkNvim system;
        localPkgs = mkLocalPackages pkgs-unstable;
        isLinux = false;
        isDarwin = true;
      in {
        imports = [ home-manager-unstable.darwinModules.home-manager ];
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.sharedModules = [
          inputs.mac-app-util.homeManagerModules.default
        ];
        home-manager.extraSpecialArgs = inputs // {
          inherit pkgs-unstable nvim isLinux isDarwin localPkgs;
          # Linux-only inputs are not available on darwin
          pkgs-jzila = null;
          beads-fixed = null;
        };
        home-manager.users.john = import ./home/john/home.nix;
      };

      # Public generator: build a NixOS system from provided modules
      mkSystem = args@{ hostPath, extraModules ? [ ], specialArgs ? { }, ... }:
        let
          sys = args.system or "x86_64-linux";
          pkgs-unstable = mkPkgsUnstable sys;
        in lib.nixosSystem {
          system = sys;
          specialArgs = inputs // { inherit pkgs-unstable; } // specialArgs;
          modules = [ hostPath ] ++ extraModules;
        };

      # Public generator: build a nix-darwin system
      mkDarwin = args@{ hostPath, extraModules ? [ ], specialArgs ? { }, ... }:
        let
          sys = args.system or "aarch64-darwin";
          pkgs-unstable = mkPkgsUnstable sys;
        in nix-darwin.lib.darwinSystem {
          system = sys;
          specialArgs = inputs // { inherit pkgs-unstable; } // specialArgs;
          modules = [ hostPath ] ++ extraModules;
        };

    in {
      lib.mkSystem = mkSystem;
      lib.mkDarwin = mkDarwin;
      lib.homeManagerModule = homeManagerModule;
      lib.homeManagerDarwinModule = homeManagerDarwinModule;

      # Custom packages, exposed so they can be built and tested directly:
      #   nix build .#opencode-bin
      packages = lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ]
        (system: mkLocalPackages (mkPkgsUnstable system));

      nixosConfigurations = {
        # Main system configuration with Home Manager (include repo hardware config)
        venator = mkSystem {
          hostPath = ./hosts/venator/configuration.nix;
          extraModules = [ ./hosts/venator/hardware-configuration.nix (homeManagerModule "x86_64-linux") ];
        };

        # Framework Desktop configuration with Home Manager
        argo = mkSystem {
          hostPath = ./hosts/argo/configuration.nix;
          extraModules = [ ./hosts/argo/hardware-configuration.nix (homeManagerModule "x86_64-linux") ];
        };

        # Generic netboot installer (no Home Manager needed)
        installer-netboot = mkSystem { hostPath = ./hosts/installer-netboot/configuration.nix; };

        # ASUS installation ISO (no Home Manager needed)
        asus-iso = mkSystem { hostPath = ./hosts/asus-iso.nix; };
      };

      darwinConfigurations = {
        # MacBook (Apple Silicon) with Home Manager
        macbook = mkDarwin {
          system = "aarch64-darwin";
          hostPath = ./hosts/macbook/configuration.nix;
          extraModules = [
            inputs.mac-app-util.darwinModules.default
            (homeManagerDarwinModule "aarch64-darwin")
          ];
        };
      };

      templates.nixos-device = {
        path = ./templates/nixos-device;
        description = "Per-device flake using nixfiles.lib.mkSystem with hardware-configuration.nix";
      };
    };
}
