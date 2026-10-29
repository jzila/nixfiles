# Read-only access to Home Assistant for Hermes: nginx on the host (the hermes
# VM), outside the hermes container, holding a token Hermes never sees. Hermes
# reads states, history and the like through it (`ha-get`,
# modules/hermes-service.nix); every change to Home Assistant goes through a PR
# on jzila/home-assistant (the home-assistant-changes skill). Nothing here can
# change Home Assistant live, by design: don't widen it for Hermes.
#
#   - Reach: nginx listens on the host's port for the container's address only
#     (allow/deny below); the host's firewall opens the port on ve-hermes alone
#     (hermesContainer.hostPorts). The container itself still can't reach Home
#     Assistant: its egress rejects the LAN (hermes-container.nix).
#   - Token: a long-lived token of a non-admin Home Assistant user ("Hermes
#     (read-only)"), in /etc/hermes/ha-token on the host (root 0600; never in
#     this repo, never bound into the container). A oneshot renders it into an
#     nginx include in /run/hermes-ha-proxy (root:nginx 0640), so it isn't in
#     the Nix store, and reloads nginx. Without a usable token nginx still
#     starts and answers 503. The proxy sets Authorization itself; whatever
#     the client sent is replaced, and cookies are dropped.
#   - What passes: GET and HEAD (405 otherwise), no Upgrade (a WebSocket on
#     /api/websocket is a GET that can call any service), and only an
#     allowlist of read endpoints, matched on the raw request URI that is
#     passed upstream unchanged (so `..` or encoded slashes can't reach
#     another view). An allowlist, not a denylist: Home Assistant and its
#     integrations register many GET views with side effects or more reach
#     than reading (webhooks, OAuth callbacks, the Supervisor API and add-on
#     ingress under /api/hassio*, /auth/*, camera and media proxies, the
#     event stream), and new ones appear with each release. Not included:
#     POST /api/template (renders templates, can't call services, but isn't
#     a GET and needs an admin user). /api/error_log needs an admin user too,
#     so with the non-admin token it answers 401.
#   - Upstream: Home Assistant's address over HTTPS, its Let's Encrypt
#     certificate verified for its name. An address, not a name, so nginx
#     starts without DNS.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.hermesHaProxy;
  runDir = "/run/hermes-ha-proxy";

  # The read endpoints, as regexes on the raw request URI (path and query).
  # Entity IDs and timestamps are spelled out so a segment can't carry `/`,
  # `..` or an encoded slash.
  entityId = ''[a-z0-9_]+\.[a-z0-9_]+'';
  timestamp = ''([0-9TZ:.+-]|%3[Aa]|%2[Bb])+'';
  query = ''(\?.*)?$'';
  readPaths = [
    "^/api/${query}"
    "^/api/(config|components|states|services|events|error_log|calendars)${query}"
    "^/api/(states|calendars)/${entityId}${query}"
    "^/api/(history/period|logbook)(/${timestamp})?${query}"
  ];

  # Why a request was refused, for whoever reads the answer: Hermes.
  refused = "This proxy is read-only by design: GET of Home Assistant's read endpoints only (home-assistant-changes skill). Change Home Assistant through a PR on jzila/home-assistant; don't ask to widen this proxy.";
  noToken = "Home Assistant read proxy: no token installed on the host (/etc/hermes/ha-token). Tell John; hosts/hermes/README.md has the steps.";

  renderToken = pkgs.writeShellScript "hermes-ha-proxy-token" ''
    set -eu
    out=${runDir}/token.conf
    umask 077
    if [ -s ${cfg.tokenFile} ] && token=$(tr -d '\n' < ${cfg.tokenFile}) \
        && [[ $token =~ ^[A-Za-z0-9._-]+$ ]]; then
      printf 'set $ha_auth "Bearer %s";\n' "$token" > "$out.tmp"
      echo "token from ${cfg.tokenFile} installed"
    else
      # Missing, empty or not a token: the proxy answers 503.
      : > "$out.tmp"
      echo "no usable token in ${cfg.tokenFile}; the proxy answers 503"
    fi
    unset token
    chgrp nginx "$out.tmp"
    chmod 0640 "$out.tmp"
    mv "$out.tmp" "$out"
    # --no-block: this unit is ordered before nginx, so a waiting reload
    # would wait for this unit to finish.
    if systemctl is-active -q nginx; then systemctl reload --no-block nginx; fi
  '';
in
{
  options.services.hermesHaProxy = {
    enable = lib.mkEnableOption "the read-only Home Assistant proxy for the hermes container";
    port = lib.mkOption {
      type = lib.types.port;
      default = 8647;
      description = "Port on the host; open to the container only.";
    };
    clientAddress = lib.mkOption {
      type = lib.types.str;
      description = "The only source nginx serves: the hermes container's address.";
    };
    upstream = lib.mkOption {
      type = lib.types.str;
      example = "https://192.168.1.153";
      description = "Home Assistant, as an address (nginx resolves names only at start).";
    };
    serverName = lib.mkOption {
      type = lib.types.str;
      default = "homeassistant.local.zila.dev";
      description = "Home Assistant's name: the Host header and the certificate's name.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/hermes/ha-token";
      description = "Long-lived token of the non-admin Home Assistant user (root 0600; never in this repo).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${runDir} 0750 root nginx -" ];

    # Renders the token before nginx starts; run again after installing a new
    # one (README.md), which reloads nginx.
    systemd.services.hermes-ha-proxy-token = {
      description = "Render the Home Assistant token for the read-only proxy";
      wantedBy = [ "nginx.service" ];
      before = [ "nginx.service" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      path = [ pkgs.coreutils pkgs.systemd ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = renderToken;
      };
    };

    services.nginx = {
      enable = true;
      appendHttpConfig = ''
        map $request_uri $ha_read_path {
          default 0;
          ${lib.concatMapStrings (r: "\"~${r}\" 1;\n  ") readPaths}
        }
      '';
      virtualHosts.hermes-ha-proxy = {
        listen = [ { addr = "0.0.0.0"; port = cfg.port; } ];
        extraConfig = ''
          allow ${cfg.clientAddress};
          deny all;
          default_type text/plain;

          if ($request_method !~ ^(GET|HEAD)$) {
            return 405 "${refused}\n";
          }
          if ($http_upgrade) {
            return 403 "${refused}\n";
          }
          if ($ha_read_path = 0) {
            return 403 "${refused}\n";
          }

          set $ha_auth "";
          # The token (hermes-ha-proxy-token); a glob, so nginx starts without it.
          include ${runDir}/*.conf;
          if ($ha_auth = "") {
            return 503 "${noToken}\n";
          }
        '';
        # No URI part: the request URI goes upstream exactly as checked above.
        locations."/".extraConfig = ''
          proxy_pass ${cfg.upstream};
          proxy_http_version 1.1;
          proxy_set_header Host ${cfg.serverName};
          proxy_set_header Authorization $ha_auth;
          proxy_set_header Cookie "";
          proxy_set_header Upgrade "";
          proxy_set_header Connection "";
          # Home Assistant refuses forwarded-for headers from proxies it
          # doesn't trust.
          proxy_set_header X-Forwarded-For "";
          proxy_set_header X-Forwarded-Host "";
          proxy_set_header X-Forwarded-Proto "";
          proxy_set_header X-Real-IP "";
          proxy_ssl_server_name on;
          proxy_ssl_name ${cfg.serverName};
          proxy_ssl_verify on;
          proxy_ssl_verify_depth 3;
          proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        '';
      };
    };
  };
}
