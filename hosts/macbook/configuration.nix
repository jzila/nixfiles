# macOS (nix-darwin) configuration for MacBook
{ config, pkgs, pkgs-unstable, lib, ... }:

{
  imports = [ ../../modules/darwin/base.nix ];

  networking.hostName = "macbook";

  # Required for user-scoped options (homebrew, system.defaults, etc.)
  system.primaryUser = "john";

  users.users.john = {
    name = "john";
    home = "/Users/john";
  };

  # Additional homebrew casks for this machine
  homebrew.casks = [
    "visual-studio-code"
    "kitty"
    "alacritty"
  ];

  # Used for backwards compatibility
  system.stateVersion = 4;
}
