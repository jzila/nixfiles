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
{ config, lib, localPkgs, ... }:
let
  inherit (config.services.ollama) port;
  clients = config.services.ollama.allowedClients;
in
{
  # Addresses let through the firewall to ollama by address, whatever
  # openFirewall says: the hermes VM on the TrueNAS box (hosts/hermes/).
  options.services.ollama.allowedClients = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "192.168.1.50" ];
    description = ''
      IPv4 addresses allowed to reach ollama's port through the firewall.
      Ollama has no authentication: anything that reaches the port can use
      it, Ollama Cloud models included.
    '';
  };

  config = {
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

    # nixos-fw is rebuilt on every (re)load, so nothing to undo on stop.
    networking.firewall = lib.mkIf (clients != [ ]) {
      extraCommands = lib.concatMapStrings (a: ''
        iptables -w -I nixos-fw 1 -s ${a} -p tcp --dport ${toString port} -j nixos-fw-accept
      '') clients;
    };
  };
}
