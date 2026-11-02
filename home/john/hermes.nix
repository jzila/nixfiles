# Hermes Agent's CLI. Standalone with its own ~/.hermes, except on argo
# (which imports the container module, now its rollback copy): there `hermes`
# is Hermes on the hermes VM, through its dashboard (hermes-dashboard-proxy.nix):
# `hermes login` signs in with a passkey, `hermes kanban …`, `hermes cron …` and
# the rest of its API are a CLI generated from its OpenAPI spec, and anything
# else is the TUI attached to it (hermes-remote.py).
{ lib, pkgs, osConfig ? { }, hermes-agent, ... }:
let
  remote = (osConfig.services or { }) ? hermesContainer;
  package = hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
  hermesRemote = pkgs.writeShellApplication {
    name = "hermes";
    text = ''
      export HERMES_REMOTE_URL=https://hermes.local.zila.dev
      export HERMES_REMOTE_STATE=''${XDG_STATE_HOME:-$HOME/.local/state}/hermes-remote
      export HERMES_REMOTE_TUI=${lib.getExe' package "hermes"}
      export HERMES_HOME=$HERMES_REMOTE_STATE/home
      # Hermes's pinned Node ignores the system store, where the step CA's root is.
      export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
      # Hermes's own Python, for its `hermes kanban` parser.
      exec ${package.hermesVenv}/bin/python3 -I ${./hermes-remote.py} "$@"
    '';
  };
in
{
  imports = [ hermes-agent.homeManagerModules.default ];
  programs.hermes-agent.enable = !remote;
  home.packages = lib.optional remote hermesRemote;
}
