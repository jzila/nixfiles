# Ollama in a container with ROCm support. Set OLLAMA_HOST=addr:port when
# running ollama outside the container to talk to the container instance.
{
  nixpkgs # pass a nixpkgs that includes rocmPackages_6, e.g. unstable
, lib
, containerHostAddr ? "127.0.0.1"
, autoStart ? true
, gfxOverride ? null # e.g. set to "11.5.0" for Strix Halo (RDNA 3.5) until ROCm ships native support
, hipUsePrecompiledKernels ? false # newer GPUs often need HIP to JIT compile kernels
, rocrVisibleDevices ? null # optionally restrict the device list (e.g. "0" for the first GPU)
, extraEnvironmentVariables ? {}
, devices ? [
    "/dev/kfd"
    "/dev/dri" # bind the whole directory; contains card*/renderD*
  ]
, port ? 11434
, ...
}:
{
  containers.ollama = {
    inherit nixpkgs autoStart;
    privateNetwork = false;
    hostAddress = containerHostAddr;
    # Allow access to the specified device nodes inside the container.
    allowedDevices = let
      deviceDescr = node: { inherit node; modifier = "rw"; };
    in map deviceDescr devices;
    bindMounts = (lib.genAttrs devices (name: {})) // {
      "/sys/module".isReadOnly = true;
    };
    config = { pkgs, lib, ... }: {
      # Persist logs so early boot messages are available via machinectl/journalctl -M
      services.journald.extraConfig = "Storage=persistent";
      networking.firewall.allowedTCPPorts = [ port ];
      networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
      services.ollama = {
        package = pkgs.ollama-rocm;
        enable = true;
        acceleration = "rocm";
        host = containerHostAddr;
        port = port;
        environmentVariables =
          lib.optionalAttrs (gfxOverride != null) {
            HSA_OVERRIDE_GFX_VERSION = gfxOverride;
          }
          // lib.optionalAttrs (!hipUsePrecompiledKernels) {
            HIP_USE_PRECOMPILED_KERNELS = "0";
          }
          // lib.optionalAttrs (rocrVisibleDevices != null) {
            ROCR_VISIBLE_DEVICES = rocrVisibleDevices;
          }
          // extraEnvironmentVariables;
      };
      system.stateVersion = "24.05";
    };
  };
}
