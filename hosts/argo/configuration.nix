# Framework Desktop (AMD Ryzen AI Max 300 Series) configuration
{ config, pkgs, pkgs-unstable, lib, nixos-hardware, ... }:
{
  imports = [
    # Framework Desktop hardware support
    nixos-hardware.nixosModules.framework-amd-ai-300-series
    # Shared desktop configuration
    ../../modules/desktop/aliza.nix
    ../../modules/ollama.nix
    ../../modules/hermes-container.nix
    ../../modules/ha-gitops.nix
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
      # Slots per model; each reserves its full context up front (~5.6 GiB
      # per gemma4 slot at 262144). qwen3.6 (qwen35moe) is held to 1 slot by
      # ollama regardless ("architecture does not currently support parallel
      # requests"), so opencode's qwen agent runs its subagents on gemma4 (see
      # home/john/opencode.nix); 6 gemma4 slots leave room for those next to
      # Hermes and Home Assistant. Measured with both loaded at 262144 context
      # and 4 gemma4 slots: 73.5 GiB of the 120 GiB the GPU may map (see
      # boot.kernelParams); 6 slots add ~11 GiB.
      OLLAMA_NUM_PARALLEL = "6";
      # Default context for clients that can't set num_ctx (the OpenAI /v1
      # API, used by Hermes Agent). Keep Home Assistant's context window at
      # the same value: ollama reloads a model whenever a request needs a
      # different context size.
      OLLAMA_CONTEXT_LENGTH = "262144";
      # Ollama passes LLAMA_ARG_* through to its llama-server runners but
      # neither sets nor counts their host-RAM caches (ollama#18264), which at
      # llama.cpp's defaults grew gemma4's runner to ~21 GiB of system RAM:
      #   - prompt cache: copies of idle slots, kept to restore conversations
      #     that lost their slot (default 8192 MiB, shared by all slots);
      #   - context checkpoints: 200 MiB snapshots of gemma4's sliding-window
      #     layers that let a slot rewind (default 32 per slot).
      # Hermes and Home Assistant each hold one conversation, which stays in
      # its slot; recent checkpoints cover the usual rewind to the last turn.
      LLAMA_ARG_CACHE_RAM = "2048";
      LLAMA_ARG_CTX_CHECKPOINTS = "4";
      # Unload idle models after 10 minutes. A loaded qwen3.6 holds the GPU
      # at 100% busy and full clock even when idle, which squeezes the CPU's
      # share of the SoC power budget and lags the desktop. gemma4 is pinned
      # instead; see ollama-pin-gemma below.
      OLLAMA_KEEP_ALIVE = "10m";
    };
    # Pulled on rebuild if missing. qwen3.6 is the general/agent model,
    # gemma4 serves Home Assistant's Assist.
    loadModels = [
      "qwen3.6:35b-a3b"
      "gemma4:26b-a4b"
    ];
  };

  # Keep gemma4 loaded for Home Assistant and Hermes. Ollama has no
  # per-model keep-alive, and every request resets a model's expiry to the
  # request's keep_alive or OLLAMA_KEEP_ALIVE (Hermes' /v1 requests can't set
  # one), so re-pin it more often than the 10-minute default expires.
  systemd.services.ollama-pin-gemma = {
    description = "Keep gemma4 loaded in ollama";
    after = [ "ollama.service" "ollama-model-loader.service" ];
    requires = [ "ollama.service" ];
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
    };
    script = ''
      ${pkgs.curl}/bin/curl -fsS --retry 10 --retry-connrefused --retry-delay 5 \
        http://127.0.0.1:11434/api/generate \
        -d '{"model":"gemma4:26b-a4b","keep_alive":-1}' >/dev/null
    '';
  };
  systemd.timers.ollama-pin-gemma = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };

  # Enable ROCm support for AMD graphics
  nixpkgs.config.rocmSupport = true;

  # Boot configuration
  boot = {
    # GPU memory is allocated dynamically from system RAM (GTT), as AMD
    # recommends for Strix Halo: the BIOS reserves only the minimum (0.5 GB)
    # for the GPU, and these cap how much RAM the GPU may map at 120 GiB of
    # the 128, leaving 8 GiB it can never take from the OS. Ollama also
    # assumes an integrated GPU's memory comes out of system RAM; a large BIOS
    # reservation shrinks the RAM it checks against and keeps a second model
    # from loading.
    kernelParams = [
      "amd_iommu=off"
      "amdgpu.gttsize=122880" # MiB
      "ttm.pages_limit=31457280" # 4 KiB pages
    ];
    # Framework Desktop specific kernel modules config if needed
    extraModprobeConfig = ''
      # Add any Framework Desktop specific modprobe options here
    '';
  };

  # The Dell U3225QE's built-in Thunderbolt 4 hub (Goshen Ridge PCIe bridges)
  # has nothing downstream, so runtime PM suspends and resumes it several
  # times a second. That churn parks kworkers in D state on the pm
  # workqueue and made input lag over the same USB4 link that carries the
  # display. Keep the bridges awake.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x0b26", ATTR{power/control}="on"
  '';

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

  # The family dataset on the TrueNAS box, over NFS. The export is limited
  # to argo's wired IP (192.168.1.237; keep it fixed with a DHCP
  # reservation) and maps every request to one TrueNAS user (mapall), since
  # sec=sys can't verify argo's uids anyway. Automounted so boot doesn't hang
  # if the NAS is down.
  fileSystems."/mnt/zila-family" = {
    device = "truenas.local.zila.dev:/mnt/data/zila-family";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      # Several TCP connections per mount, so one client can use more than
      # one stream's worth of the NAS's 10GbE.
      "nconnect=4"
      "rsize=1048576"
      "wsize=1048576"
      "noauto"
      "x-systemd.automount"
      "x-systemd.mount-timeout=30"
      "_netdev"
    ];
  };

  # The backup dataset on the same box, exported and mounted the same way
  # (argo-only, mapall).
  fileSystems."/mnt/john-backup" = {
    device = "truenas.local.zila.dev:/mnt/data/john-backup";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      "nconnect=4"
      "rsize=1048576"
      "wsize=1048576"
      "noauto"
      "x-systemd.automount"
      "x-systemd.mount-timeout=30"
      "_netdev"
    ];
  };

  # Google Drive, synced both ways with drive/ on that dataset. argo runs it
  # because it's always on; no other machine keeps a copy. Needs the
  # `gdrive` rclone remote set up once (see modules/gdrive.nix).
  home-manager.users.john.services.gdrive.bisync = {
    enable = true;
    target = "/mnt/zila-family/drive";
    # Push argo's own writes there within seconds. (Other clients' writes
    # over SMB/NFS are invisible to inotify here and wait for the timer.)
    watch.enable = true;
    # Up to 100 files in flight. Most of Drive is 1-5 MB photos, where
    # per-file request latency, not bandwidth, sets the pace at rclone's
    # default of 4. (The drive backend's own API pacer, ~10 calls/s by
    # default, still caps how fast new small files start.)
    extraArgs = [ "--transfers" "100" ];
  };

  # NixOS state version
  system.stateVersion = "23.11";
}
