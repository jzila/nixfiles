# Framework Desktop (AMD Ryzen AI Max 300 Series) configuration
{ config, pkgs, pkgs-unstable, lib, nixos-hardware, ... }:
{
  imports = [
    # Framework Desktop hardware support
    nixos-hardware.nixosModules.framework-amd-ai-300-series
    # Shared desktop configuration
    ../../modules/desktop/aliza.nix
    ../../modules/ollama.nix
  ];

  # Networking configuration
  networking = {
    hostName = "argo";
    extraHosts = ''
      127.0.0.1 manuscripts.localhost
    '';
  };

  # Strix Halo is gfx1151, which ROCm builds kernels for natively, so no
  # rocmOverrideGfx is needed.
  services.ollama = {
    environmentVariables = {
      OLLAMA_FLASH_ATTENTION = "1";
      OLLAMA_DEBUG = "1";
      # Slots per model; each reserves its full context up front. At 4 slots
      # and 262144 context: gemma4 ~41 GiB, qwen3.6 ~43 GiB, together ~84 GiB.
      # Sized for the BIOS reserving 96 GB of the 128 GB for the GPU.
      OLLAMA_NUM_PARALLEL = "4";
      # Default context for clients that can't set num_ctx (the OpenAI /v1
      # API, used by Hermes Agent). Keep Home Assistant's context window at
      # the same value: ollama reloads a model whenever a request needs a
      # different context size.
      OLLAMA_CONTEXT_LENGTH = "262144";
    };
    # Pulled on rebuild if missing. qwen3.6 is the general/agent model,
    # gemma4 serves Home Assistant's Assist.
    loadModels = [
      "qwen3.6:35b-a3b"
      "gemma4:26b-a4b"
    ];
  };

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

  # Speech-to-text for Home Assistant's Assist over the Wyoming protocol. With
  # language "en", wyoming-faster-whisper runs NVIDIA Parakeet TDT 0.6B v2
  # (int8, via sherpa-onnx) instead of Whisper: much faster on CPU, and better
  # on English. The model downloads into the service's state dir on first
  # start. In HA: Settings > Devices & services > Add > Wyoming Protocol,
  # host argo.local.zila.dev, port 10300.
  services.wyoming.faster-whisper.servers.parakeet = {
    enable = true;
    uri = "tcp://0.0.0.0:10300";
    language = "en";
    sttLibrary = "sherpa";
  };

  # Text-to-speech for Assist over the Wyoming protocol. Piper streams audio
  # sentence by sentence by default, so speech starts before the reply is
  # fully generated. The "high" lessac voice trades a little speed for
  # quality, which the CPU here has to spare. The voice downloads into the
  # service's state dir on first start. In HA: Wyoming Protocol, port 10200.
  services.wyoming.piper.servers.lessac = {
    enable = true;
    uri = "tcp://0.0.0.0:10200";
    voice = "en_US-lessac-high";
  };

  networking.firewall.allowedTCPPorts = [
    10200 # wyoming-piper
    10300 # wyoming-faster-whisper (Parakeet)
  ];

  # NixOS state version
  system.stateVersion = "23.11";
}
