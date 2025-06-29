{
  description = "John's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    
    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
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

    # Special version needed for ollama
    nixpkgs-ollama.url = "github:nixos/nixpkgs/f173d0881eff3b21ebb29a2ef8bedbc106c86ea5";

    # MicroVM support
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, home-manager, nix-vscode-extensions, plasma-manager, nixpkgs-ollama, microvm, ... }@inputs:
    let
      system = "x86_64-linux";
      
      # Configure pkgs instances
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        config.rocmSupport = true;
      };

      pkgs-unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
        config.rocmSupport = true;
      };

      pkgs-ollama = import nixpkgs-ollama {
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
          inherit pkgs-unstable;
        };
        home-manager.users.john = import ./home/john/home.nix;
      };

      # Dynamic host loading helper
      mkHost = hostPath: extraModules: lib.nixosSystem {
        inherit system;
        specialArgs = inputs // {
          inherit pkgs-unstable pkgs-ollama;
        };
        modules = [
          hostPath
          microvm.nixosModules.host
        ] ++ extraModules;
      };

    in {
      nixosConfigurations = {
        # Main system configuration with Home Manager
        venator = mkHost ./hosts/venator/configuration.nix [ homeManagerModule ];
        
        # ASUS installation ISO (no Home Manager needed)
        asus-iso = mkHost ./hosts/asus-iso.nix [ ];
      };
    };
}