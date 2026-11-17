# Hermes Agent's CLI. By default (hermes.remote) `hermes` talks to the Hermes on the hermes VM through
# its dashboard (hermes-dashboard-proxy.nix), signed in with a passkey by
# `hermes login`. The dashboard API's commands and `hermes kanban` run against
# it; anything else is the TUI attached to it (remote/). With hermes.remote off
# it is a standalone Hermes with its own ~/.hermes.
{ config, lib, pkgs, hermes-agent, ... }:
let
  inherit (config.hermes) remote;
  hermes = hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  imports = [ hermes-agent.homeManagerModules.default ];
  options.hermes.remote = lib.mkEnableOption "the remote CLI instead of a standalone Hermes" // { default = true; };
  config = {
    programs.hermes-agent.enable = !remote;
    home.packages = lib.optional remote (import ./remote { inherit pkgs hermes; }).package;
  };
}
