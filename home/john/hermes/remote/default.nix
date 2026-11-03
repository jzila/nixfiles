# The remote `hermes` (client.py), with its commands generated from the pinned Hermes's own
# OpenAPI spec at build time, so they follow the hermes-agent input; `check` tests it.
{ pkgs, hermes }:
let
  inherit (pkgs) lib;
  url = "https://hermes.local.zila.dev";
  python = "${hermes.hermesVenv}/bin/python";
  share = "${hermes}/share/hermes-agent";
  spec = pkgs.runCommand "hermes-openapi.json" { } ''
    export HOME=$TMPDIR HERMES_HOME=$(mktemp -d) HERMES_BUNDLED_PLUGINS=${share}/plugins \
      HERMES_INSTALL_ROOT=${share} HERMES_WEB_DIST=${share}/web_dist
    ${python} -I -c '
    import contextlib, json, os, sys
    with open(os.devnull, "w") as quiet, contextlib.redirect_stdout(quiet), contextlib.redirect_stderr(quiet):
        from hermes_cli.web_server import app, _discover_dashboard_plugins, _mount_plugin_api_routes
        _discover_dashboard_plugins(); _mount_plugin_api_routes(); app.openapi_schema = None
        spec = app.openapi()
    json.dump(spec, sys.stdout, sort_keys=True)' > $out
  '';
  gen = "${lib.getExe pkgs.python3} -I ${./gen.py} < ${spec}";
  lib' = pkgs.runCommand "hermes-remote-lib" { } ''
    mkdir $out
    cp ${./client.py} $out/client.py
    cp ${./kanban.py} $out/kanban.py
    ${gen} > $out/hermes_api.py
  '';
in
{
  package = pkgs.writeShellApplication {
    name = "hermes";
    text = ''
      export HERMES_REMOTE_URL=${url} HERMES_REMOTE_TUI=${lib.getExe' hermes "hermes"}
      export HERMES_REMOTE_STATE=''${XDG_STATE_HOME:-$HOME/.local/state}/hermes-remote
      exec ${python} -E -s ${lib'}/client.py "$@"
    '';
  };
  check = pkgs.runCommand "hermes-remote-test" { } ''
    ${gen} | cmp - ${lib'}/hermes_api.py
    cp ${lib'}/* . && cp ${./test_client.py} test_client.py
    HERMES_HOME=$(mktemp -d) PYTHONDONTWRITEBYTECODE=1 ${python} -E -s -m unittest test_client && touch $out
  '';
}
