# macOS (nix-darwin) configuration for MacBook
{ config, pkgs, pkgs-unstable, lib, ... }:

{
  imports = [
    ../../modules/darwin/base.nix
    ../../modules/darwin/apple-container.nix
  ];

  # Apple container CLI for running Linux containers as lightweight VMs
  services.apple-container.enable = true;

  networking.hostName = "macbook";

  # Required for user-scoped options (system.defaults, etc.)
  system.primaryUser = "john";

  users.users.john = {
    name = "john";
    home = "/Users/john";
  };

  # Match the GID used by the existing Nix installation
  ids.gids.nixbld = 350;

  # Used for backwards compatibility
  system.stateVersion = 4;
}
