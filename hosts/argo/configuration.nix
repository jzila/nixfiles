# Framework Desktop (AMD Ryzen AI Max 300 Series) configuration
{ config, pkgs, pkgs-unstable, lib, nixos-hardware, nixpkgs, nixpkgs-unstable, rocm-nightly, ... }:

let
  rocmPkgs = pkgs.rocmPackages or {};
  rocmPackagesList = paths:
    builtins.filter (pkg: pkg != null) (map (path: lib.attrByPath path null rocmPkgs) paths);
  hipRuntime = lib.attrByPath [ "hip-runtime" ] null rocmPkgs;
in
{
  imports = [
    # Framework Desktop hardware support
    nixos-hardware.nixosModules.framework-amd-ai-300-series
    # Shared desktop configuration
    ../../modules/desktop/aliza.nix
    # Overlay ROCm with TheRock nightly build extracted under /opt/rocm-nightly
    (import ../../modules/rocm-nightly.nix {
      inherit config pkgs lib;
      rocmRoot = rocm-nightly;
    })
  ];

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

  # Networking configuration
  networking = {
    hostName = "argo";
    extraHosts = ''
      127.0.0.1 manuscripts.localhost
    '';
  };

  # Ollama container configuration for desktop GPU
  containers = (import ../../modules/ollama.nix {
    inherit nixpkgs lib;
    # Bind directories/devices rather than specific nodes to avoid
    # failures when device numbering differs or nodes are absent.
    containerHostAddr = "0.0.0.0";
    gfxOverride = "11.5.1";
    extraEnvironmentVariables = lib.optionalAttrs (hipRuntime != null) {
      ROCM_PATH = toString hipRuntime;
      ROCM_HOME = toString hipRuntime;
    };
    devices = [
      "/dev/kfd"
      "/dev/dri/card1"
      "/dev/dri/renderD128"
    ];
  }).containers;

  # Graphics configuration for AMD Ryzen AI Max 300 series
  services.xserver.videoDrivers = [ "amdgpu" ];
  
  # Enable hardware graphics acceleration
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages =
    (rocmPackagesList [
      [ "hsa-rocr" ]
      [ "hip-runtime" ]
      [ "rocblas" ]
      [ "rocsparse" ]
      [ "rocfft" ]
      [ "rccl" ]
      [ "miopen" ]
      [ "rpp" ]
      [ "rocminfo" ]
    ])
    ++ [
      pkgs-unstable.amdvlk
      pkgs-unstable.nvtopPackages.amd
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

  environment.systemPackages = rocmPackagesList [
    [ "hsa-rocr" ]
    [ "rocminfo" ]
    [ "hip-runtime" ]
  ];

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
