{
  description = "John's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
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
      url = "github:openai/codex/b3f958c24e4c4350c06220bbafd9982de13e3acb";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    wifitui = {
      url = "github:shazow/wifitui";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, ... }@inputs:
    let
      system = "x86_64-linux";
      
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
          inherit pkgs-unstable;
        };
        modules = [
          hostPath
        ] ++ extraModules;
      };

    in {
      nixosConfigurations = {
        # Main system configuration with Home Manager
        venator = mkHost ./hosts/venator/configuration.nix [ homeManagerModule ];
        
        # Framework Desktop configuration with Home Manager
        argo = mkHost ./hosts/argo/configuration.nix [ homeManagerModule ];
        
        # Generic netboot installer (no Home Manager needed)
        installer-netboot = mkHost ./hosts/installer-netboot/configuration.nix [ ];
        
        # ASUS installation ISO (no Home Manager needed)
        asus-iso = mkHost ./hosts/asus-iso.nix [ ];
      };
    };
}
