{
  description = "John's NixVim configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixvim, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems f;

      nixvimModule = system: {
        inherit system;
        module = import ./config;
      };
    in
    {
      packages = forAllSystems (system: {
        default = nixvim.legacyPackages.${system}.makeNixvimWithModule (nixvimModule system);
      });

      checks = forAllSystems (system: {
        default = nixvim.lib.${system}.check.mkTestDerivationFromNixvimModule (nixvimModule system);
      });
    };
}
