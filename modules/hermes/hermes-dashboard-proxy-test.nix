{ pkgs }:
let
  certs = pkgs.runCommand "test-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out && cd $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj /CN=ca -keyout ca.key -out ca.crt
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj /CN=hermes -keyout server.key -out server.csr
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt \
      -extfile <(echo subjectAltName=DNS:hermes)
  '';

  # Echoes the headers the dashboard would see; upgrades WebSockets.
  backend = pkgs.writeText "backend.py" ''
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Backend(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            h = self.headers
            if h.get("Upgrade") == "websocket":
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.end_headers()
                return
            body = f"host={h['Host']} xff={h['X-Forwarded-For']} proto={h['X-Forwarded-Proto']} xfh={h['X-Forwarded-Host']}".encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    HTTPServer(("127.0.0.1", 9120), Backend).serve_forever()
  '';

  client = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.curl ];
    environment.etc."ca.crt".source = "${certs}/ca.crt";
  };
in
pkgs.testers.runNixOSTest {
  name = "hermes-dashboard-proxy";
  nodes = {
    hermes = { nodes, lib, ... }: {
      imports = [ ./hermes-dashboard-proxy.nix client ];
      virtualisation.vlans = [ 1 2 ];
      networking.interfaces.eth2.ipv4.addresses = lib.mkForce [ { address = "100.64.0.1"; prefixLength = 24; } ];
      networking.nftables.enable = true;
      services.hermesDashboardProxy = {
        enable = true;
        upstream = "http://127.0.0.1:9120";
        serverName = "hermes.example";
        allowedAddresses = [ nodes.argo.networking.primaryIPAddress ];
        tailnetInterface = "eth2";
      };
      systemd.services.backend = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${backend}";
      };
    };
    argo = client;
    # Its eth1 stands in for tailscale0.
    tailnet = { lib, ... }: {
      imports = [ client ];
      virtualisation.vlans = [ 2 ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ { address = "100.64.0.2"; prefixLength = 24; } ];
    };
  };
  testScript = { nodes, ... }: ''
    lan = "${nodes.hermes.networking.primaryIPAddress}"
    argo_ip = "${nodes.argo.networking.primaryIPAddress}"

    def request(node, src, dst, scheme="https", port=443, ws=False):
        """(curl exit code, HTTP status, body, redirect target), from source address src."""
        headers = "-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='" if ws else ""
        out = node.succeed(
            f"c=0; curl -sS --http1.1 --max-time {2 if ws else 5} --cacert /etc/ca.crt --interface {src} --resolve hermes:{port}:{dst} "
            "-H 'X-Forwarded-For: 6.6.6.6' -H 'X-Forwarded-Host: evil' -H 'Host: evil' "
            f"{headers} -w '\\n%{{http_code}} %{{redirect_url}}' '{scheme}://hermes:{port}/api/ws?ticket=secret' 2>/dev/null || c=$?; echo \" $c\""
        )
        body, _, tail = out.rstrip("\n").rpartition("\n")
        status, *location, code = tail.split()
        return int(code), status, body, "".join(location)

    start_all()
    hermes.wait_for_open_port(443)
    hermes.wait_for_open_port(9120)
    argo.succeed("ip addr add 192.168.1.99/24 dev eth1")
    tailnet.succeed("ip addr add 10.9.0.2/24 dev eth1")
    hermes.succeed("ip addr add 10.9.0.1/24 dev eth2")
    argo.wait_until_succeeds(f"ping -c1 -W1 {lan}")
    tailnet.wait_until_succeeds("ping -c1 -W1 100.64.0.1")

    with subtest("no certificate yet: nginx is up, the handshake fails"):
        assert request(argo, argo_ip, lan)[0] == 35

    hermes.succeed("install -D -m 0640 -g nginx ${certs}/server.{crt,key} -t /etc/hermes-tls")

    def outcome(node, src, dst, **kw):
        code, status, _, location = request(node, src, dst, **kw)
        return "refused" if code in (7, 28) else f"{status} {location}".strip()

    with subtest("who gets through, on 443 and 80"):
        redirect = "301 https://hermes.example/api/ws?ticket=secret"
        for name, node, src, dst, https, http in [
            ("argo", argo, argo_ip, lan, "200", redirect),
            ("tailnet", tailnet, "100.64.0.2", "100.64.0.1", "200", redirect),
            ("other LAN address", argo, "192.168.1.99", lan, "refused", "refused"),
            ("tailnet interface, outside its range", tailnet, "10.9.0.2", "10.9.0.1", "refused", "refused"),
            ("past the firewall, not allowed by nginx", hermes, "127.0.0.1", "127.0.0.1", "403", redirect),
        ]:
            got = outcome(node, src, dst), outcome(node, src, dst, scheme="http", port=80)
            assert got == (https, http), f"{name}: {got}"
            if https == "200":
                body = request(node, src, dst)[2]
                assert body == f"host=hermes.example xff={src} proto=https xfh=None", f"{name}: {body}"
                assert request(node, src, dst, ws=True)[1] == "101", f"{name}: no WebSocket upgrade"

    with subtest("query strings stay out of the access log"):
        hermes.succeed("grep -q 'GET /api/ws\" 101' /var/log/nginx/access.log")
        hermes.fail("grep -q secret /var/log/nginx/access.log")
  '';
}
