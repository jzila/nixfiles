# Framework Desktop (AMD Ryzen AI Max 300 Series) configuration
{ config, pkgs, pkgs-unstable, lib, nixos-hardware, nixpkgs, nixpkgs-unstable, ... }:

{
  imports = [
    # Framework Desktop hardware support
    nixos-hardware.nixosModules.framework-amd-ai-300-series
    # Hardware scan results
    ./hardware-configuration.nix
    # Shared desktop configuration
    ../../modules/desktop/aliza.nix
  ];

  # System identification
  networking.hostName = "argo";

  # Enable ROCm support for AMD graphics
  nixpkgs.config.rocmSupport = true;

  # Boot configuration
  boot = {
    kernelParams = [];
    # Framework Desktop specific kernel modules config if needed
    extraModprobeConfig = ''
      # Add any Framework Desktop specific modprobe options here
    '';
  };

  # Graphics configuration for AMD Ryzen AI Max 300 series
  services.xserver.videoDrivers = [ "amdgpu" ];
  
  # Enable hardware graphics acceleration
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages = [
    pkgs-unstable.amdvlk
    pkgs.rocmPackages.clr.icd
  ];
  hardware.graphics.extraPackages32 = [
    pkgs-unstable.driversi686Linux.amdvlk
  ];

  # Power management - use power-profiles-daemon for desktop (not TLP)
  services.power-profiles-daemon.enable = true;

  # Ollama container configuration for desktop GPU
  containers = (import ../../modules/ollama.nix {
    inherit nixpkgs lib;
    devices = [
      "/dev/kfd"
      "/dev/dri/card0"      # Integrated GPU (Radeon 8060S)
      "/dev/dri/renderD128" # Integrated GPU render node
    ];
  }).containers;

  # Desktop-specific user configuration
  users.users.john = {
    isNormalUser = true;
    description = "John Zila";
    extraGroups = [
      "networkmanager"
      "wheel"
      "plugdev"
      "scanner"
      "lp"
      "dialout"
    ];
    packages = with pkgs; [
      firefox
      bitwarden
      yubioath-flutter
      alacritty
    ];
    useDefaultShell = true;
  };

  # Keybase security wrapper ownership
  security.wrappers.keybase-redirector.owner = "john";
  security.wrappers.keybase-redirector.group = "users";

  # Tailscale operator assignment
  services.tailscale.extraUpFlags = [
    "--operator=john"
  ];

  # Framework Desktop specific networking (if any)
  networking.extraHosts = ''
    127.0.0.1 manuscripts.localhost
  '';

  # NixOS state version
  system.stateVersion = "23.11";
}