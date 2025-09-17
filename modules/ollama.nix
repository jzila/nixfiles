# Ollama in a container with ROCm support. Set OLLAMA_HOST=addr:port when
# running ollama outside the container to talk to the container instance.
{
  nixpkgs # pass a nixpkgs that includes rocmPackages_6, e.g. unstable
, lib
, containerHostAddr ? "127.0.0.1"
, autoStart ? true
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
      deviceDescr = node: { inherit node; modifier = "rwm"; };
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
        environmentVariables = {
          HSA_OVERRIDE_GFX_VERSION = "10.3.0";
        };
      };
      system.stateVersion = "24.05";
    };
  };
}
