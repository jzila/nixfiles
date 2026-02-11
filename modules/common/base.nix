# Cross-platform base configuration module
# Shared settings between NixOS and nix-darwin
{ config, pkgs, pkgs-unstable, lib, ... }:

{
  nix.settings.trusted-users = [
    "root"
    "john"
  ];

  # Enable flakes and nix command
  nix.settings.experimental-features = "nix-command flakes";

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Shell Configuration
  programs.zsh.enable = true;
  programs.direnv.enable = true;

  # Cross-platform system packages
  environment.systemPackages = with pkgs; [
    # Shell utilities
    bat
    neovim
    wget
    curl
    git
    htop
    dig

    # Build utilities
    cmake
    gnumake
  ] ++ [
    # Unstable packages
    pkgs-unstable.devenv
  ];
}
