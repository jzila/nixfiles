# HTTPS front for Hermes's dashboard (hermes.dashboard, hermes/hermes-service.nix),
# for browsers on argo and the tailnet. Auth stays the dashboard's own login.
{ config, lib, ... }:
let
  cfg = config.services.hermesDashboardProxy;
  tailnet = "100.64.0.0/10";
in
{
  options.services.hermesDashboardProxy = with lib; {
    enable = mkEnableOption "the HTTPS front for Hermes's dashboard";
    upstream = mkOption { type = types.str; };
    serverName = mkOption { type = types.str; default = "hermes.local.zila.dev"; };
    allowedAddresses = mkOption { type = types.listOf types.str; };
    tailnetInterface = mkOption { type = types.str; default = "tailscale0"; };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.extraInputRules = ''
      ip saddr { ${lib.concatStringsSep ", " cfg.allowedAddresses} } tcp dport { 80, 443 } accept
      iifname "${cfg.tailnetInterface}" ip saddr ${tailnet} tcp dport { 80, 443 } accept
    '';

    services.nginx = {
      enable = true;
      commonHttpConfig = ''
        map $http_upgrade $hermes_dashboard_connection {
          default upgrade;
          "" close;
        }
        # Variables make nginx load the certificate per handshake: it starts
        # without one, and renewals need no reload.
        map "" $hermes_dashboard_cert { default /etc/hermes-tls/server.crt; }
        map "" $hermes_dashboard_key { default /etc/hermes-tls/server.key; }
        # $uri, not $request: WebSocket tickets travel in the query string.
        log_format hermes_dashboard '$remote_addr [$time_local] "$request_method $uri" $status';
      '';
      virtualHosts.hermes-dashboard-redirect = {
        listen = [ { addr = "0.0.0.0"; port = 80; } ];
        extraConfig = "access_log /var/log/nginx/access.log hermes_dashboard;";
        locations."/".return = "301 https://${cfg.serverName}$request_uri";
      };
      virtualHosts.hermes-dashboard = {
        listen = [ { addr = "0.0.0.0"; port = 443; ssl = true; } ];
        extraConfig = ''
          ssl_certificate $hermes_dashboard_cert;
          ssl_certificate_key $hermes_dashboard_key;
          access_log /var/log/nginx/access.log hermes_dashboard;
          ${lib.concatMapStrings (a: "allow ${a};\n") cfg.allowedAddresses}
          allow ${tailnet};
          deny all;
          client_max_body_size 0;
        '';
        locations."/".extraConfig = ''
          proxy_pass ${cfg.upstream};
          proxy_http_version 1.1;
          # The dashboard checks Host against its public_url.
          proxy_set_header Host ${cfg.serverName};
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $hermes_dashboard_connection;
          proxy_set_header X-Forwarded-For $remote_addr;
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-Host "";
          proxy_set_header X-Forwarded-Prefix "";
          proxy_buffering off;
          proxy_read_timeout 1h;
        '';
      };
    };
  };
}
