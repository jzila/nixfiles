# Hermes Agent's CLI. Standalone with its own ~/.hermes, except with
# hermes.remote: there `hermes` is the TUI attached to the Hermes on the
# hermes VM, through its dashboard (hermes-dashboard-proxy.nix) with a passkey
# sign-in, `hermes login` (hermes-remote.py). Only the TUI attaches remotely;
# subcommands don't.
{ config, lib, pkgs, hermes-agent, ... }:
let
  inherit (config.hermes) remote;
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
  options.hermes.remote = lib.mkEnableOption "the remote TUI instead of a standalone Hermes";
  config = {
    programs.hermes-agent.enable = !remote;
    home.packages = lib.optional remote hermesRemote;
  };
}
