# Ollama in a container with ROCm support. Set OLLAMA_HOST=addr:port when
# running ollama outside the container to talk to the container instance.
{
  nixpkgs # path or flake providing nixpkgs for the container (fork, unstable, etc.)
, lib
, # Set to "" for dual-stack or "0.0.0.0" to wildcard IPv4 only.
  listenHost ? "127.0.0.1"
, ollamaPort ? 11434
, openWebUIPort ? 8081
, openFirewallOnHost ? false
, autoStart ? true
, # HSA_OVERRIDE_GFX_VERSION, for GPUs the ROCm build has no kernels for
  # (e.g. "10.3.0" for RDNA2 parts other than gfx1030). null = use the GPU's
  # own target.
  gfxOverride ? null
, # ollama package to run; null = the container nixpkgs' ollama-rocm.
  package ? null
, extraEnvironment ? {}
, devices ? [
    "/dev/kfd"
    "/dev/dri" # bind the whole directory; contains card*/renderD*
  ]
, ...
}:
{
  containers.ollama = {
    inherit nixpkgs autoStart;
    # Obviates the need for a hostAddress parameter
    privateNetwork = false;
    # The container runs with DevicePolicy=closed, so every device node ROCm
    # opens has to be allowed here. DeviceAllow only matches device nodes or
    # classes, never directories: an entry for /dev/dri silently allows
    # nothing, and ROCm then finds no GPU and ollama falls back to CPU. Allow
    # the whole DRM class instead so card/render node numbering doesn't matter.
    allowedDevices = map (node: { inherit node; modifier = "rw"; }) [
      "/dev/kfd"
      "char-drm"
    ];
    bindMounts = (lib.genAttrs devices (name: { isReadOnly = false; })) // {
      "/sys/module".isReadOnly = true;
    };
    config = { pkgs, lib, ... }: {
      nixpkgs.config.allowUnfree = true;
      nixpkgs.config.rocmSupport = true;
      # Persist logs so early boot messages are available via machinectl/journalctl -M
      services.journald.extraConfig = "Storage=persistent";
      networking.firewall.allowedTCPPorts = [
        ollamaPort
        openWebUIPort
      ];
      networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
      services.ollama = {
        # ollama-rocm is what selects the ROCm build; the separate
        # services.ollama.acceleration option that used to do it is gone.
        package = if package != null then package else pkgs.ollama-rocm;
        enable = true;
        rocmOverrideGfx = gfxOverride;
        host = listenHost;
        port = ollamaPort;
        environmentVariables = extraEnvironment;
      };
      services.open-webui = {
        enable = true;
        host = listenHost;
        port = openWebUIPort;
      };
      system.stateVersion = "24.05";
    };
  };
} // lib.mkIf openFirewallOnHost {
  networking.firewall.allowedTCPPorts = [
    ollamaPort
    openWebUIPort
  ];
}
