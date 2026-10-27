# Hermes's credentials, kept by root next to the gateway: the zila-hermes
# GitHub App's installation token, minted from the app's private key, and
# renewal of the webhook TLS certificate. Shared by argo, which keeps them for
# the container (modules/hermes-container.nix), and the hermes VM
# (hosts/hermes/), which keeps its own: its own app key and its own
# certificate, provisioned out of band, never in this repo.
#
#   - GitHub: the app's private key (root, 0600) never leaves root; a timer
#     mints a one-hour installation token every 30 minutes into
#     githubTokenDir (root:hermes 0750), which git and gh read on every call.
#   - TLS: the certificate in tlsDir is issued once by hand for 30 days
#     (--not-after 720h) by the step CA; renewal keeps that lifetime. Checked
#     daily and renewed in the last 7 days (renewal authenticates with the
#     current certificate, no password), then nginx picks it up.
{ config, lib, pkgs, ... }:
let
  cfg = config.hermes.credentials;
  stepRootCa = ./ssh-ca/root_ca.crt;
  nginxGid = toString config.ids.gids.nginx;
  githubAppId = "5415128";
in
{
  options.hermes.credentials = {
    enable = lib.mkEnableOption "Hermes's GitHub token minting and webhook certificate renewal";
    githubAppKey = lib.mkOption {
      type = lib.types.str;
      default = "/etc/hermes/github-app.pem";
      description = "The GitHub App's private key (root, 0600; never in this repo).";
    };
    githubTokenDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/hermes-github";
      description = "Where the installation token is written, readable by the hermes group.";
    };
    tlsDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/hermes-tls";
      description = "The webhook server certificate and key (root plus nginx's group).";
    };
    caUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://smallstep-ca.local.zila.dev:9000";
      description = "The step CA that issued the webhook certificate.";
    };
    reloadNginx = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Appended to the renewal script: how nginx picks up the certificate.";
    };
    renewPath = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra packages on the renewal script's PATH (for reloadNginx).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.hermes-tls-renew = {
      description = "Renew the Hermes webhook TLS certificate";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig.Type = "oneshot";
      path = [ pkgs.step-cli config.systemd.package ] ++ cfg.renewPath;
      script = ''
        [ -s ${cfg.tlsDir}/server.crt ] || exit 0
        step ca renew --force --expires-in 168h \
          --ca-url ${cfg.caUrl} --root ${stepRootCa} \
          ${cfg.tlsDir}/server.crt ${cfg.tlsDir}/server.key
        chown root:${nginxGid} ${cfg.tlsDir}/server.crt ${cfg.tlsDir}/server.key
        chmod 0640 ${cfg.tlsDir}/server.crt ${cfg.tlsDir}/server.key
      '' + cfg.reloadNginx;
    };
    systemd.timers.hermes-tls-renew = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    # Mint the GitHub App's installation token (an hour's life).
    systemd.services.hermes-github-token = {
      description = "Mint Hermes's GitHub App installation token";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.openssl pkgs.curl pkgs.jq pkgs.coreutils ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail
        b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
        now=$(date +%s)
        unsigned="$(printf '{"alg":"RS256","typ":"JWT"}' | b64).$(printf '{"iat":%d,"exp":%d,"iss":"${githubAppId}"}' $((now - 60)) $((now + 540)) | b64)"
        jwt="$unsigned.$(printf %s "$unsigned" | openssl dgst -sha256 -sign ${cfg.githubAppKey} | b64)"
        api() { curl -sS --fail -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" "$@"; }
        installation=$(api https://api.github.com/app/installations | jq -r '.[] | select(.account.login == "jzila") | .id')
        token=$(api -X POST "https://api.github.com/app/installations/$installation/access_tokens" | jq -r .token)
        umask 027
        printf %s "$token" >${cfg.githubTokenDir}/token.new
        chgrp hermes ${cfg.githubTokenDir}/token.new
        mv ${cfg.githubTokenDir}/token.new ${cfg.githubTokenDir}/token
      '';
    };
    systemd.timers.hermes-github-token = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "30min";
      };
    };
  };
}
