{ config, lib, pkgs, ... }:

{
  imports = [
    ./base.nix
    ./network.nix
    ./cli.nix
    ./devenv.nix
    ./examples.nix
  ];
  
  # Module metadata
  meta = {
    maintainers = [ ];
    doc = ./README.md;
  };
}