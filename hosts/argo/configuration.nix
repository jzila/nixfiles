# Framework Desktop (AMD Ryzen AI Max 300 Series) configuration
{ config, pkgs, pkgs-unstable, lib, nixos-hardware, nixpkgs, nixpkgs-jzila, ... }:
let
  ollama = import ../../modules/ollama.nix {
    inherit lib;
    nixpkgs = nixpkgs-jzila;
    listenHost = "0.0.0.0";
    openFirewallOnHost = true;
    gfxOverride = "11.5.1";
    # devices = [
    #   "/dev/kfd"
    #   "/dev/dri/card1"
    #   "/dev/dri/renderD128"
    # ];
    extraEnvironment = {
      OLLAMA_FLASH_ATTENTION = "1";
      # OLLAMA_ACCELERATE = "1";
      # OLLAMA_NUM_GPU_LAYERS = "9999";
      OLLAMA_DEBUG = "2";
      OLLAMA_NUM_PARALLEL = "8";
    };
  };
in
{
  imports = [
    # Framework Desktop hardware support
    nixos-hardware.nixosModules.framework-amd-ai-300-series
    # Shared desktop configuration
    ../../modules/desktop/aliza.nix
    ollama
  ];

  # Networking configuration
  networking = {
    hostName = "argo";
    extraHosts = ''
      127.0.0.1 manuscripts.localhost
    '';
  };
  containers = ollama.containers;

  # Enable ROCm support for AMD graphics
  nixpkgs.config.rocmSupport = true;

  # Boot configuration
  boot = {
    kernelParams = [
      "amd_iommu=off"
      "amdgpu.gttsize=131072"
      "ttm.pages_limit=33554432"
    ];
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

  # NixOS state version
  system.stateVersion = "23.11";
}
