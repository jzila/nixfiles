# Framework Desktop (AMD Ryzen AI Max 300 Series) configuration
{ config, pkgs, pkgs-unstable, localPkgs, lib, nixos-hardware, nixpkgs, ... }:
let
  ollama = import ../../modules/ollama.nix {
    inherit lib nixpkgs;
    # Upstream release build; nixpkgs' ollama-rocm is too old for current models.
    package = localPkgs.ollama-rocm-bin;
    listenHost = "0.0.0.0";
    openFirewallOnHost = true;
    # Strix Halo is gfx1151, which ROCm builds kernels for natively, so no
    # gfxOverride is needed.
    extraEnvironment = {
      OLLAMA_FLASH_ATTENTION = "1";
      # OLLAMA_ACCELERATE = "1";
      # OLLAMA_NUM_GPU_LAYERS = "9999";
      OLLAMA_DEBUG = "1";
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
    pkgs.rocmPackages.clr.icd
  ];

  # GPU diagnostics: rocminfo lists the agents ROCm sees, nvtop shows GPU load
  environment.systemPackages = [
    pkgs.rocmPackages.rocminfo
    pkgs.nvtopPackages.amd
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
      bitwarden-desktop
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
