# Hermes Agent's CLI. The gateway (Signal) runs in the hermes container on
# argo (modules/hermes-container.nix), which owns the configuration; the CLI
# runs as john, unsandboxed, and shares that state through HERMES_HOME.
#
# The tools work in the directory `hermes` is started from: the shared
# config.yaml sets terminal.cwd to ".", which resolves against the launch
# directory here and against the gateway's own directory in the container.
{ lib, osConfig ? { }, hermes-agent, ... }:
{
  imports = [ hermes-agent.homeManagerModules.default ];

  # Puts `hermes` on PATH and exports HERMES_HOME. services.hermes-agent stays
  # disabled: no user services, and no second config.yaml writer.
  programs.hermes-agent.enable = true;
  # Only argo hosts the shared state; elsewhere the CLI keeps ~/.hermes.
  services.hermes-agent.hermesHome = lib.mkIf (
    (osConfig.containers or { }) ? hermes
  ) "/var/lib/hermes/.hermes";
}
