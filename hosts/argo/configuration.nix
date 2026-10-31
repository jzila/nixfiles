# Framework Desktop (AMD Ryzen AI Max 300 Series) configuration
{ config, pkgs, pkgs-unstable, lib, nixos-hardware, ... }:
{
  imports = [
    # Framework Desktop hardware support
    nixos-hardware.nixosModules.framework-amd-ai-300-series
    # Shared desktop configuration
    ../../modules/desktop/aliza.nix
    ../../modules/ollama.nix
    ./ollama-models.nix
    ../../modules/hermes-container.nix
  ];

  # Hermes moved to the hermes VM on the TrueNAS box (hosts/hermes/). Kept
  # imported, off, for a rollback (hosts/hermes/README.md, "Rollback"); its
  # state stays in /var/lib. The Home Assistant runners moved too; they only
  # run in containers now.
  services.hermesContainer.enable = false;

  # Networking configuration
  networking = {
    hostName = "argo";
    extraHosts = ''
      127.0.0.1 manuscripts.localhost
    '';
    # The onboard NIC holds the DHCP reservation (192.168.1.237) that the NAS
    # export allows. Bind its profile to the NIC (named by PCI slot): an
    # unbound wired profile can be claimed by a USB NIC that wins the race at
    # boot.
    networkmanager.ensureProfiles.profiles.lan-onboard = {
      connection = {
        id = "LAN onboard";
        type = "ethernet";
        interface-name = "enp191s0";
        autoconnect = true;
        autoconnect-priority = 100;
      };
      ipv4.method = "auto";
      ipv6 = {
        method = "auto";
        addr-gen-mode = "stable-privacy";
      };
    };
  };

  # Strix Halo is gfx1151, which ROCm builds kernels for natively, so no
  # rocmOverrideGfx is needed.
  services.ollama = {
    environmentVariables = {
      OLLAMA_FLASH_ATTENTION = "1";
      OLLAMA_DEBUG = "1";
      # One slot per model. ollama has no per-model setting (ollama#4894),
      # and this is what lets Qwen3.8 and gemma4 stay loaded together (see
      # ./ollama-models.nix). Hermes and opencode share Qwen's slot; Home
      # Assistant has gemma4's to itself.
      OLLAMA_NUM_PARALLEL = "1";
      OLLAMA_KV_CACHE_TYPE = "q8_0";
      # Default context for clients that don't set num_ctx (the OpenAI /v1
      # API). Qwen3.8's own num_ctx (131072) overrides it. Keep Home
      # Assistant's context window at the same value: ollama reloads a model
      # whenever a request needs a different context size, and with two
      # models loaded a reload can evict the other one.
      OLLAMA_CONTEXT_LENGTH = "65536";
      # Read Qwen3.8's ~27 GiB per-layer embedding table from disk as needed
      # instead of loading it into memory.
      LLAMA_ARG_LAZY_MODE = "on";
      # Ollama passes LLAMA_ARG_* through to its llama-server runners but
      # neither sets nor counts their host-RAM caches (ollama#18264), which at
      # llama.cpp's defaults grew gemma4's runner to ~21 GiB of system RAM:
      #   - prompt cache: copies of idle slots, kept to restore conversations
      #     that lost their slot (default 8192 MiB, shared by all slots);
      #   - context checkpoints: 200 MiB snapshots of gemma4's sliding-window
      #     layers that let a slot rewind (default 32 per slot).
      # Off by default; ./ollama-models.nix turns the prompt cache back on
      # for Qwen3.8 alone. Recent checkpoints cover the usual rewind to the
      # last turn.
      LLAMA_ARG_CACHE_RAM = "0";
      LLAMA_ARG_CTX_CHECKPOINTS = "4";
      # With two ROCm processes resident (one runner per loaded model), the
      # GPU sits at 100% busy and full clock while idle, ~25 W, until a
      # kernel fix expected in 7.4 (ROCm/TheRock#7578, #9141). One hardware
      # queue per process avoids it, with no measured change in speed. Drop
      # once argo runs 7.4.
      GPU_MAX_HW_QUEUES = "1";
      # Unload idle models after 10 minutes; Qwen3.8 and gemma4 are pinned
      # instead (ollama-pin-models in ./ollama-models.nix). Loading any other
      # model evicts one of them.
      OLLAMA_KEEP_ALIVE = "10m";
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

  # The firewall as one nftables ruleset, replaced atomically on a switch:
  # a module that's turned off leaves no rules behind (its table is
  # deleted), and a ruleset that fails to load leaves the old one in place.
  # Podman's netavark follows (its own table); tailscaled writes its rules
  # as its own tables too, which the reload leaves alone.
  networking.nftables.enable = true;
  systemd.services.tailscaled.environment.TS_DEBUG_FIREWALL_MODE = "nftables";

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
