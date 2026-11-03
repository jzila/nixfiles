# Hermes Agent's CLI. Standalone with its own ~/.hermes, except with
# hermes.remote: there `hermes` talks to the Hermes on the hermes VM through
# its dashboard (hermes-dashboard-proxy.nix), signed in with a passkey by
# `hermes login`. The dashboard API's commands and `hermes kanban` run against
# it; anything else is the TUI attached to it (remote/).
{ config, lib, pkgs, hermes-agent, ... }:
let
  inherit (config.hermes) remote;
  hermes = hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  imports = [ hermes-agent.homeManagerModules.default ];
  options.hermes.remote = lib.mkEnableOption "the remote CLI instead of a standalone Hermes";
  config = {
    programs.hermes-agent.enable = !remote;
    home.packages = lib.optional remote (import ./remote { inherit pkgs hermes; }).package;
  };
}
