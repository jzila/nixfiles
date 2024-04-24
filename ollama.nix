# Ollama in a container with ROCm support. Set OLLAMA_HOST=addr:port when
# running ollama outside the container to talk to the container instance.
{
  nixpkgs ? <nixos-unstable>  # pass a nixpkgs that includes rocmPackages_6, e.g. unstable
, containerHostAddr ? "192.168.1.33"
, containerGuestAddr ? "192.168.1.111"
, autoStart ? true
, devices ? [ "/dev/dri/card0" "/dev/dri/renderD128" ]
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
    config = { pkgs, ... }: {
      networking.firewall.allowedTCPPorts = [ port ];
      services.ollama = {
        enable = true;
        package = pkgs.ollama.override {
          acceleration = "rocm";
          rocmPackages = pkgs.rocmPackages_6;
        };
        listenAddress = "${containerHostAddr}:${toString port}";
      };
      system.stateVersion = "24.05";
    };
  };
}
