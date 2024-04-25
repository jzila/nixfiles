# Ollama in a container with ROCm support. Set OLLAMA_HOST=addr:port when
# running ollama outside the container to talk to the container instance.
{
  nixpkgs # pass a nixpkgs that includes rocmPackages_6, e.g. unstable
, lib
, containerHostAddr ? "192.168.1.178"
, containerGuestAddr ? "192.168.1.111"
, autoStart ? true
, devices ? [
    "/dev/kfd"
    "/dev/dri/card0"
    "/dev/dri/renderD128"
  ]
, port ? 11434
, ...
}:
{
  containers.ollama = {
    inherit nixpkgs autoStart;
    privateNetwork = false;
    hostAddress = containerHostAddr;
    localAddress = containerGuestAddr;
    allowedDevices = let
      deviceDescr = node: { inherit node; modifier = "rw"; };
    in map deviceDescr devices;
    bindMounts = (lib.genAttrs devices (name: {})) // {
      "/sys/module".isReadOnly = true;
    };
    config = { pkgs, lib, ... }: {
      networking.firewall.allowedTCPPorts = [ port ];
      services.ollama = {
        enable = true;
        acceleration = "rocm";
        listenAddress = "${containerHostAddr}:${toString port}";
        environmentVariables = {
          HSA_OVERRIDE_GFX_VERSION = "10.3.0";
        };
      };
      system.stateVersion = "24.05";
    };
  };
}
