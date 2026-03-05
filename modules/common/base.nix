# Cross-platform base configuration module
# Shared settings between NixOS and nix-darwin
{ config, pkgs, pkgs-unstable, devenv, lib, ... }:

{
  nix.settings.trusted-users = [
    "root"
    "john"
  ];

  # Enable flakes and nix command
  nix.settings.experimental-features = "nix-command flakes";
  nix.settings.extra-substituters = [ "https://devenv.cachix.org" ];
  nix.settings.extra-trusted-public-keys = [ "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];

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
    # From cachix/devenv flake
    devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv
  ];
}
