{
  description = "John's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    
    home-manager = {
      url = "github:nix-community/home-manager/release-23.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    nix-vscode-extensions = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Special version needed for ollama
    nixpkgs-ollama.url = "github:nixos/nixpkgs/f173d0881eff3b21ebb29a2ef8bedbc106c86ea5";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, home-manager, nix-vscode-extensions, nixpkgs-ollama, ... }@inputs:
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
    in {
      nixosConfigurations = {
        # Main system configuration
        venator = lib.nixosSystem {
          inherit system;
          specialArgs = { 
            inherit pkgs-unstable pkgs-ollama nix-vscode-extensions nixos-hardware;
          };
          modules = [
            ./hosts/venator/configuration.nix
            
            # Home Manager module
            home-manager.nixosModules.home-manager {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { 
                inherit pkgs-unstable nix-vscode-extensions;
              };
              home-manager.users.john = import ./home/john/home.nix;
            }
          ];
        };
        
        # ASUS installation ISO
        asus-iso = lib.nixosSystem {
          inherit system;
          specialArgs = { 
            inherit pkgs-unstable nixos-hardware;
          };
          modules = [
            ./hosts/asus-iso.nix
          ];
        };
      };
    };
}