# Hermes Agent's messaging gateway, sandboxed in a NixOS container together
# with the signal-cli daemon it talks to.
#
# Why a container (and not the upstream module's container mode): upstream runs
# an Ubuntu image with --network=host and passwordless sudo for the agent, and
# forces the host CLI into the container. Here the container is a plain NixOS
# system with a private network, and inside it the upstream module runs in its
# native mode: the gateway is the unprivileged `hermes` user, never root.
# What runs inside (the gateway, signal-cli, nginx, scripts, skills) is
# hermes-service.nix.
#
#   - Network: private veth (10.233.2.2), NAT to the internet. signal-cli's
#     JSON-RPC listens on the container's own loopback, so nothing on the host
#     can use the bot's Signal account. ollama is argo over the LAN
#     (allowedLanTargets).
#   - Filesystem: the container sees its own root, the read-only Nix store,
#     Hermes's state, and nothing else of the host's. The host's nix-daemon
#     socket is covered. Grant more by adding bindMounts below
#     (isReadOnly = true unless writes are wanted).
#   - State: /var/lib/hermes is bound from the host. UID/GID 870 is fixed on
#     both sides so ownership lines up across the bind mount.
#   - Secrets: /etc/hermes/gateway.env on the host (root, 0600; never in this
#     repo) is mounted read-only into the container, that one file and nothing
#     else of /etc/hermes (the GitHub App key beside it stays on the host).
#     The mount holds the file the container started with, so after replacing
#     it restart the container, not just the gateway. Hermes's activation merges
#     it into $HERMES_HOME/.env.
#   - Webhooks: Home Assistant (and only it) reaches Hermes's webhook receiver
#     through nginx in the container on :8645, over mutual TLS with
#     certificates from the step CA: nginx requires a client certificate for
#     Home Assistant's name, and the receiver itself listens on the
#     container's loopback. The server certificate lives in /etc/hermes-tls on
#     the host (root plus the container nginx's group, which shares the host's
#     IDs), issued once by hand for 30 days (--not-after 720h); a daily timer
#     renews it in its last 7 days, authenticating with the current one. Two
#     routes: ha-maintenance (device lists reconciled into kanban tasks, no
#     agent turn) and ha-log (errors and some warnings Home Assistant logs:
#     one task per distinct issue, and a triage turn on Signal for new ones,
#     rate-limited).
#   - PR events: on a review or comment, a workflow in each repo
#     (.github/workflows/pr-events.yml) joins the tailnet as tag:github-ci
#     (Tailscale workload identity federation; the tailnet policy lets that tag
#     reach only tag:hermes:8646) and posts {repo, pr}. The host DNATs
#     tailscale0:8646 to a plain-HTTP nginx listener in the container that only
#     forwards /webhooks/github-pr; github-pr.py treats the post as a hint and
#     reads the PR from GitHub itself.
#   - Home Assistant: no access from the container itself (egress rejects the
#     LAN). The host's egress gateway (hermes-egress.nix), on its end of the
#     veth, is the only way: Hermes uses it with `ha-get` and `ha-call` and
#     never sees the token.
#   - Dashboard: see hermes-service.nix. Its login is Pocket ID
#     (dashboard.oidc), which the container must be allowed to reach.
#   - GitHub: Hermes acts as the zila-hermes GitHub App (installed on
#     jzila/home-assistant and jzila/nixfiles; no workflow permission, can't
#     bypass the main rulesets). The app's private key stays on the host
#     (/etc/hermes/github-app.pem, root 0600); a timer mints a one-hour
#     installation token every 30 minutes into /run/hermes-github, which the
#     container sees read-only and git and gh read on every call.
{ config, lib, pkgs, hermes-agent, ... }:
let
  inherit (cfg) hostAddress localAddress homeAssistantAddress;
  hermesId = 870;
  stateDir = "/var/lib/hermes";

  # Mutual-TLS webhook ingress from Home Assistant.
  webhookPort = 8645;
  # PR event ingress from GitHub Actions over the tailnet (see the header).
  prEventsPort = 8646;
  tlsDir = "/etc/hermes-tls";
  # The container shares the host's IDs, so its nginx reads the bind-mounted
  # certificate as this group.
  nginxGid = toString config.ids.gids.nginx;
  stepRootCa = ../ssh-ca/root_ca.crt;

  # GitHub App credentials (see the header).
  githubAppId = "5415128";
  githubAppKey = "/etc/hermes/github-app.pem";
  githubTokenDir = "/run/hermes-github";

  cfg = config.services.hermesContainer;
  egressPort = config.services.hermesEgress.port;

  egressRules = lib.concatMapStrings (t: ''
    ip daddr ${t.address} tcp dport ${toString t.port} accept
  '') cfg.allowedLanTargets;
in
{
  options.services.hermesContainer = {
    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.233.2.1";
      description = "The host's end of the container's veth.";
    };
    localAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.233.2.2";
      description = "The container's address.";
    };
    ollamaHost = lib.mkOption {
      type = lib.types.str;
      description = "Where the container reaches ollama.";
    };
    allowedLanTargets = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options.address = lib.mkOption { type = lib.types.str; };
        options.port = lib.mkOption { type = lib.types.port; };
      });
      default = [ ];
      description = "TCP services on private ranges the container may reach, forwarded.";
    };
    resolvers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "DNS servers the container may query.";
    };
    # An address, not a name: nft resolves names once, at load, and the
    # firewall fails to start if DNS isn't up yet. The client certificate is
    # what authenticates.
    homeAssistantAddress = lib.mkOption {
      type = lib.types.str;
      description = "The only source DNATed to the mutual-TLS webhook port.";
    };
    dashboard = {
      publicUrl = lib.mkOption { type = lib.types.str; };
      oidc = {
        issuer = lib.mkOption { type = lib.types.str; };
        clientId = lib.mkOption { type = lib.types.str; };
      };
    };
  };

  config = {
  # ── Host side ─────────────────────────────────────────────────────────────
  users.groups.hermes.gid = hermesId;
  users.users.hermes = {
    isSystemUser = true;
    uid = hermesId;
    group = "hermes";
    home = stateDir;
  };

  systemd.tmpfiles.rules = [
    # setgid so files created by either side stay in the hermes group.
    "d ${stateDir} 2770 hermes hermes -"
    "d /etc/hermes 0700 root root -"
    # Created empty if missing, so the container can start before the secrets
    # are filled in.
    "f /etc/hermes/gateway.env 0600 root root -"
    "d ${githubTokenDir} 0750 root hermes -"
    "d ${tlsDir} 0750 root ${nginxGid} -"
    "z ${tlsDir}/server.crt 0640 root ${nginxGid} -"
    "z ${tlsDir}/server.key 0640 root ${nginxGid} -"
  ];

  systemd.services.hermes-tls-renew = {
    description = "Renew the Hermes webhook TLS certificate";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.step-cli config.systemd.package pkgs.nixos-container ];
    script = ''
      [ -s ${tlsDir}/server.crt ] || exit 0
      step ca renew --force --expires-in 168h \
        --ca-url https://smallstep-ca.local.zila.dev:9000 --root ${stepRootCa} \
        ${tlsDir}/server.crt ${tlsDir}/server.key
      chown root:${nginxGid} ${tlsDir}/server.crt ${tlsDir}/server.key
      chmod 0640 ${tlsDir}/server.crt ${tlsDir}/server.key
      # Also picks up a certificate reissued by hand.
      nixos-container run hermes -- systemctl reload-or-restart nginx
    '';
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
    unitConfig.ConditionPathExists = githubAppKey;
    path = [ pkgs.openssl pkgs.curl pkgs.jq pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
      now=$(date +%s)
      unsigned="$(printf '{"alg":"RS256","typ":"JWT"}' | b64).$(printf '{"iat":%d,"exp":%d,"iss":"${githubAppId}"}' $((now - 60)) $((now + 540)) | b64)"
      jwt="$unsigned.$(printf %s "$unsigned" | openssl dgst -sha256 -sign ${githubAppKey} | b64)"
      api() { curl -sS --fail -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" "$@"; }
      installation=$(api https://api.github.com/app/installations | jq -r '.[] | select(.account.login == "jzila") | .id')
      token=$(api -X POST "https://api.github.com/app/installations/$installation/access_tokens" | jq -r .token)
      umask 027
      printf %s "$token" >${githubTokenDir}/token.new
      chgrp hermes ${githubTokenDir}/token.new
      mv ${githubTokenDir}/token.new ${githubTokenDir}/token
    '';
  };
  systemd.timers.hermes-github-token = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "30min";
    };
  };

  # ── The container ─────────────────────────────────────────────────────────
  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-hermes" ];
  };

  # Network grants for the container, like the bindMounts below for files:
  #   - to the host: the egress gateway only. Everything else from the
  #     container is rejected, including the host's allowedTCPPorts, which
  #     apply on every interface.
  #   - forwarded: DNS to the resolvers, allowedLanTargets, nothing else on
  #     private or local ranges (LAN, Tailscale CGNAT, link-local, multicast),
  #     internet otherwise (Signal, web tools). Replies to connections made to
  #     the container are allowed.
  #   - inbound: the webhook port, DNATed to the container for Home
  #     Assistant's address only; the PR events port, for the tailnet only
  #     (tailnet policy narrows it to tag:github-ci).
  # Its own nftables table, loaded atomically with the rest of the ruleset.
  # Base chains run just before the firewall's own (priority filter - 1); a
  # packet needs every hook's chains to accept it, so these only narrow what
  # the firewall would allow.
  networking.firewall.interfaces.ve-hermes.allowedTCPPorts = [ egressPort ];
  networking.nftables.tables.hermes = {
    family = "inet";
    content = ''
      chain to-host {
        type filter hook input priority filter - 1; policy accept;
        iifname "ve-hermes" ct state established,related accept
        iifname "ve-hermes" tcp dport { ${toString egressPort} } accept
        iifname "ve-hermes" reject
      }

      chain egress {
        type filter hook forward priority filter - 1; policy accept;
        iifname != "ve-hermes" accept
        ct state established,related accept
        ip daddr { ${lib.concatStringsSep ", " cfg.resolvers} } meta l4proto { tcp, udp } th dport 53 accept
        ${egressRules}ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 224.0.0.0/4 } reject
      }

      chain ingress {
        type nat hook prerouting priority dstnat - 1; policy accept;
        ip saddr ${homeAssistantAddress} tcp dport ${toString webhookPort} fib daddr type local \
          dnat ip to ${localAddress}:${toString webhookPort}
        iifname "tailscale0" ip saddr 100.64.0.0/10 tcp dport ${toString prEventsPort} fib daddr type local \
          dnat ip to ${localAddress}:${toString prEventsPort}
      }
    '';
  };

  containers.hermes = {
    autoStart = true;
    privateNetwork = true;
    inherit hostAddress localAddress;

    bindMounts = {
      ${stateDir} = {
        hostPath = stateDir;
        isReadOnly = false;
      };
      # Only gateway.env: the rest of /etc/hermes (the app key) stays out.
      "/run/host-secrets/hermes/gateway.env" = {
        hostPath = "/etc/hermes/gateway.env";
        isReadOnly = true;
      };
      "/run/host-secrets/hermes-tls" = {
        hostPath = tlsDir;
        isReadOnly = true;
      };
      "/run/host-secrets/github" = {
        hostPath = githubTokenDir;
        isReadOnly = true;
      };
      # nspawn binds the host's daemon socket into every container; cover it.
      "/nix/var/nix/daemon-socket/socket" = {
        hostPath = "/dev/null";
        isReadOnly = true;
      };
      # Access grants go here, one per folder, e.g.:
      #   "/grants/notes" = { hostPath = "/home/john/notes"; isReadOnly = true; };
    };

    specialArgs = { inherit hermes-agent; };
    config = {
      imports = [ ./hermes-service.nix ];
      hermes.ollamaHost = cfg.ollamaHost;
      hermes.haProxyUrl = "http://${hostAddress}:${toString egressPort}";
      hermes.dashboard = {
        inherit (cfg.dashboard) publicUrl oidc;
        address = localAddress;
        proxy = hostAddress;
      };
      system.stateVersion = "26.05";
      networking.useHostResolvConf = lib.mkForce false;
    };
  };
  };
}
