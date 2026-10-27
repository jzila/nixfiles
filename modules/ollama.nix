# Ollama with ROCm as a host service, reachable from the LAN (Home Assistant
# and other clients).
#
# This used to run in a NixOS container. The host module covers what the
# container was for: it runs under a DynamicUser with the usual systemd
# sandboxing, and already allows the GPU device classes (char-drm, char-kfd)
# plus the render group that ROCm needs.
#
# Hosts set environment variables and models through services.ollama
# directly; see hosts/argo/configuration.nix.
{ lib, localPkgs, ... }:
{
  services.ollama = {
    enable = true;
    # Upstream release build; nixpkgs' ollama-rocm trails too far behind to
    # pull current models. See pkgs/ollama-rocm-bin.
    package = lib.mkDefault localPkgs.ollama-rocm-bin;
    # All interfaces, so Home Assistant can reach it. Ollama has no
    # authentication of its own; anything that can reach the port can use it.
    host = lib.mkDefault "0.0.0.0";
    openFirewall = lib.mkDefault true;
  };
}
