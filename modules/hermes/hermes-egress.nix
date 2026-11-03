# Holds LAN credentials Hermes mustn't: HA tokens can't be scoped, so this allowlist is the scope.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.hermesEgress;
  runDir = "/run/hermes-egress";

  # Raw URI, forwarded unchanged: `..` or %2F can't reach another view.
  entityId = ''[a-z0-9_]+\.[a-z0-9_]+'';
  timestamp = ''([0-9TZ:.+-]|%3[Aa]|%2[Bb])+'';
  query = ''(\?.*)?$'';
  allowed = map (r: "^(GET|HEAD) /api/${r}") [
    query
    "(config|components|states|services|events|error_log|calendars)${query}"
    "(states|calendars)/${entityId}${query}"
    "(history/period|logbook)(/${timestamp})?${query}"
  ] ++ lib.mapAttrsToList (domain: services:
    "^POST /api/services/${domain}/(${lib.concatStringsSep "|" services})(\\?return_response)?$") cfg.services;
  approved = lib.concatStringsSep ", " (lib.concatLists (lib.mapAttrsToList
    (domain: map (s: "${domain}.${s}")) cfg.services));

  refused = "Refused by Hermes's egress gateway: only GET of Home Assistant's read endpoints (ha-get) and POST of the approved services (ha-call: ${approved}). Change anything else through a PR on jzila/home-assistant (home-assistant-changes skill).";
  noToken = "Home Assistant egress gateway: no token installed on the host (${cfg.tokenFile}). Tell John; hosts/hermes/README.md has the steps.";

  renderToken = pkgs.writeShellScript "hermes-egress-token" ''
    set -eu
    out=${runDir}/token.conf
    umask 077
    if [ -s ${cfg.tokenFile} ] && token=$(tr -d '\n' < ${cfg.tokenFile}) \
        && [[ $token =~ ^[A-Za-z0-9._-]+$ ]]; then
      printf 'set $ha_auth "Bearer %s";\n' "$token" > "$out.tmp"
    else
      : > "$out.tmp"
      echo "no usable token in ${cfg.tokenFile}"
    fi
    unset token
    chgrp nginx "$out.tmp"
    chmod 0640 "$out.tmp"
    mv "$out.tmp" "$out"
    # Ordered before nginx: a blocking reload deadlocks.
    if systemctl is-active -q nginx; then systemctl reload --no-block nginx; fi
  '';
in
{
  options.services.hermesEgress = {
    enable = lib.mkEnableOption "Hermes's egress gateway to Home Assistant";
    port = lib.mkOption {
      type = lib.types.port;
      default = 8647;
    };
    clientAddress = lib.mkOption {
      type = lib.types.str;
      description = "The hermes container's address, the only client.";
    };
    upstream = lib.mkOption {
      type = lib.types.str;
      example = "https://192.168.1.153";
      description = "An address, not a name: nginx resolves names only at start.";
    };
    serverName = lib.mkOption {
      type = lib.types.str;
      default = "homeassistant.local.zila.dev";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/hermes/ha-token";
      description = "Long-lived token of a non-admin Home Assistant user.";
    };
    services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf (lib.types.strMatching "[a-z_]+"));
      default.todo = [ "get_items" "add_item" "update_item" "remove_item" "remove_completed_items" ];
      description = "Home Assistant services Hermes may call, by domain, for every entity.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${runDir} 0750 root nginx -" ];

    systemd.services.hermes-egress-token = {
      description = "Render the Home Assistant token for Hermes's egress gateway";
      wantedBy = [ "multi-user.target" "nginx.service" ];
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
        map "$request_method $request_uri" $ha_allowed {
          default 0;
          ${lib.concatMapStrings (r: "\"~${r}\" 1;\n  ") allowed}
        }
      '';
      virtualHosts.hermes-egress = {
        listen = [ { addr = "0.0.0.0"; port = cfg.port; } ];
        extraConfig = ''
          allow ${cfg.clientAddress};
          deny all;
          default_type text/plain;
          client_max_body_size 16k;

          if ($http_upgrade) {
            return 403 "${refused}\n";
          }
          if ($ha_allowed = 0) {
            return 403 "${refused}\n";
          }

          set $ha_auth "";
          include ${runDir}/*.conf;
          if ($ha_auth = "") {
            return 503 "${noToken}\n";
          }
        '';
        locations."/".extraConfig = ''
          proxy_pass ${cfg.upstream};
          proxy_http_version 1.1;
          proxy_set_header Host ${cfg.serverName};
          proxy_set_header Authorization $ha_auth;
          proxy_set_header Cookie "";
          proxy_set_header Upgrade "";
          proxy_set_header Connection "";
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
