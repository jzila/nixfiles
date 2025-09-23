# Ollama in a container with ROCm support. Set OLLAMA_HOST=addr:port when
# running ollama outside the container to talk to the container instance.
{
  nixpkgs # pass a nixpkgs that includes rocmPackages_6, e.g. unstable
, lib
, # Set to "" for dual-stack or "0.0.0.0" to wildcard IPv4 only.
  listenHost ? "127.0.0.1"
, port ? 11434
, openFirewallOnHost ? false
, autoStart ? true
, gfxOverride ? "10.3.0"
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
        host = listenHost;
        port = port;
        environmentVariables = {
          HSA_OVERRIDE_GFX_VERSION = gfxOverride;
        } // extraEnvironment;
      };
      system.stateVersion = "24.05";
    };
  };
} // lib.mkIf openFirewallOnHost {
  networking.firewall.allowedTCPPorts = [ port ];
}
