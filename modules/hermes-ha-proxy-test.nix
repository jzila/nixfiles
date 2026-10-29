# nix build .#checks.x86_64-linux.hermes-ha-proxy: the read-only Home
# Assistant proxy (hermes-ha-proxy.nix) in a VM, in front of a stub that
# answers every request with the method, URI and Authorization it received.
{ pkgs }:
let
  stub = pkgs.writeText "ha-stub.py" ''
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Echo(BaseHTTPRequestHandler):
        def answer(self):
            body = f"{self.command} {self.path} auth={self.headers.get('Authorization')}\n".encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        do_GET = do_HEAD = do_POST = answer

    HTTPServer(("127.0.0.1", 8080), Echo).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "hermes-ha-proxy";
  nodes.machine = {
    imports = [ ./hermes-ha-proxy.nix ];
    services.hermesHaProxy = {
      enable = true;
      clientAddress = "127.0.0.1";
      upstream = "http://127.0.0.1:8080";
    };
    systemd.services.ha-stub = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${stub}";
    };
    environment.systemPackages = [ pkgs.curl ];
  };
  testScript = ''
    def get(path, args=""):
        # The body, then the status code.
        return machine.succeed(f"curl -sS --path-as-is -w '%{{http_code}}' {args} 'http://127.0.0.1:8647{path}'")

    machine.wait_for_unit("nginx.service")
    machine.wait_for_open_port(8080)

    with subtest("no token: nginx runs, the proxy answers 503"):
        out = get("/api/states")
        assert out.startswith("Home Assistant read proxy: no token") and out.endswith("503"), out

    machine.succeed("mkdir -m 0700 /etc/hermes && install -m 0600 /dev/stdin /etc/hermes/ha-token <<< tok.en-1_X")
    machine.succeed("systemctl start hermes-ha-proxy-token")
    # The reload is queued, not waited for.
    machine.wait_until_succeeds("curl -sf http://127.0.0.1:8647/api/")
    machine.succeed("[ $(stat -c %a:%G /run/hermes-ha-proxy/token.conf) = 640:nginx ]")

    with subtest("reads pass, with the token"):
        for path in ["/api/states", "/api/history/period/2026-10-29T00:00:00%2B00:00?filter_entity_id=sun.sun"]:
            out = get(path)
            assert out == f"GET {path} auth=Bearer tok.en-1_X\n200", out

    with subtest("the client's Authorization is replaced"):
        out = get("/api/states/sun.sun", "-H 'Authorization: Bearer evil'")
        assert out == "GET /api/states/sun.sun auth=Bearer tok.en-1_X\n200", out

    with subtest("refused: other methods, upgrades, other paths"):
        for path, args, code in [
            ("/api/services/light/turn_on", "-X POST", "405"),
            # A read path, but POST sets the state.
            ("/api/states/sun.sun", "-X POST -d '{\"state\": \"x\"}'", "405"),
            ("/api/states", "-H 'Connection: Upgrade' -H 'Upgrade: websocket'", "403"),
            ("/api/websocket", "", "403"),
            ("/api/hassio/addons", "", "403"),
            ("/auth/providers", "", "403"),
            ("/api/webhook/some-id", "", "403"),
            # Checked as sent, not as nginx normalises them (/api/states, /api/hassio).
            ("/api/hassio/../states", "", "403"),
            ("/api/states/a.b%2F..%2F..%2Fhassio", "", "403"),
        ]:
            out = get(path, args)
            assert "read-only by design" in out and out.endswith(code), f"{args} {path}: {out}"

    with subtest("refused: any client but the container"):
        ip = machine.succeed("ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1").strip()
        out = machine.succeed(f"curl -sS -o /dev/null -w '%{{http_code}}' http://{ip}:8647/api/states")
        assert out == "403", out
  '';
}
