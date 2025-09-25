{
  description = "John's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-jzila = {
      url = "github:jzila/nixpkgs/jzila/ollama-0-12-1";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
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

    codex = {
      url = "github:jzila/codex/add-github-action-for-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    wifitui = {
      url = "github:shazow/wifitui";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixpkgs-jzila, home-manager, ... }@inputs:
    let
      system = "x86_64-linux";

      # Configure ollama release override; set values to track a Github release
      ollamaRelease = {
        version = "0.12.1";
        srcHash = "sha256-+kdKXHhv1q16CK1PubgadrBM5YMYTBaPB2Et7hSmUWk=";
      };

      # Configure pkgs instances
      pkgs-unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
        config.rocmSupport = true;
      };

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        config.rocmSupport = true;
      };

      pkgs-jzila = import nixpkgs-jzila {
        inherit system;
        config.allowUnfree = true;
        config.rocmSupport = true;
      };

      lib = nixpkgs.lib;

      # Common Home Manager configuration
      homeManagerModule = {
        imports = [ home-manager.nixosModules.home-manager ];
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.extraSpecialArgs = inputs // {
          inherit pkgs-unstable pkgs-jzila;
        };
        home-manager.users.john = import ./home/john/home.nix;
      };

      # Public generator: build a NixOS system from provided modules
      # Accepts extra keys (e.g., legacy 'system') and prefers a provided system if present
      mkSystem = args@{ hostPath, extraModules ? [ ], specialArgs ? { }, ... }:
        let
          sys = if args ? system then args.system else system;
        in lib.nixosSystem {
          system = sys;
          specialArgs = inputs // { inherit pkgs-unstable; } // specialArgs;
          modules = [ hostPath ] ++ extraModules;
        };

    in {
      lib.mkSystem = mkSystem;
      lib.homeManagerModule = homeManagerModule;
      nixosConfigurations = {
        # Main system configuration with Home Manager (include repo hardware config)
        venator = mkSystem {
          hostPath = ./hosts/venator/configuration.nix;
          extraModules = [ ./hosts/venator/hardware-configuration.nix homeManagerModule ];
        };
        
        # Framework Desktop configuration with Home Manager
        argo = mkSystem {
          hostPath = ./hosts/argo/configuration.nix;
          extraModules = [ ./hosts/argo/hardware-configuration.nix homeManagerModule ];
        };
        
        # Generic netboot installer (no Home Manager needed)
        installer-netboot = mkSystem { hostPath = ./hosts/installer-netboot/configuration.nix; };
        
        # ASUS installation ISO (no Home Manager needed)
        asus-iso = mkSystem { hostPath = ./hosts/asus-iso.nix; };
      };
      templates.nixos-device = {
        path = ./templates/nixos-device;
        description = "Per-device flake using nixfiles.lib.mkSystem with hardware-configuration.nix";
      };
    };
}
