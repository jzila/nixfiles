# Hermes Agent's CLI. Standalone with its own ~/.hermes, except on argo
# (which imports the container module, now its rollback copy): there `hermes`
# is the TUI attached to the Hermes on the hermes VM, through its dashboard
# (hermes-dashboard-proxy.nix) with a passkey sign-in, `hermes login`
# (hermes-remote.py). Only the TUI attaches remotely; subcommands don't.
{ lib, pkgs, osConfig ? { }, hermes-agent, ... }:
let
  remote = (osConfig.services or { }) ? hermesContainer;
  package = hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
  url = "https://hermes.local.zila.dev";
  hermesRemote = pkgs.writeShellApplication {
    name = "hermes";
    text = ''
      export HERMES_REMOTE_URL=${url}
      export HERMES_REMOTE_STATE=''${XDG_STATE_HOME:-$HOME/.local/state}/hermes-remote
      helper() { ${lib.getExe pkgs.python3} -I ${./hermes-remote.py} "$@"; }
      if [ "''${1:-}" = login ]; then helper login; exit; fi
      ticket=$(helper ticket)
      # Hermes's pinned Node ignores the system store, where the step CA's root is.
      export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
      export HERMES_HOME=$HERMES_REMOTE_STATE/home
      export HERMES_TUI_GATEWAY_URL="wss://${lib.removePrefix "https://" url}/api/ws?ticket=$ticket"
      exec ${lib.getExe' package "hermes"} --tui "$@"
    '';
  };
in
{
  imports = [ hermes-agent.homeManagerModules.default ];
  programs.hermes-agent.enable = !remote;
  home.packages = lib.optional remote hermesRemote;
}
