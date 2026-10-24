# Hermes Agent's messaging gateway, sandboxed in a NixOS container together
# with the signal-cli daemon it talks to.
#
# Why a container (and not the upstream module's container mode): upstream runs
# an Ubuntu image with --network=host and passwordless sudo for the agent, and
# forces the host CLI into the container. Here the container is a plain NixOS
# system with a private network, and inside it the upstream module runs in its
# native mode: the gateway is the unprivileged `hermes` user, never root.
#
#   - Network: private veth (10.233.1.2), NAT to the internet. signal-cli's
#     JSON-RPC listens on the container's own loopback, so nothing on the host
#     can use the bot's Signal account. The host is 10.233.1.1, which is how the
#     container reaches ollama.
#   - Filesystem: the container sees its own root, the read-only Nix store, the
#     shared Hermes state, and nothing of the host's /home. Grant more by adding
#     bindMounts below (isReadOnly = true unless writes are wanted).
#   - State: /var/lib/hermes is shared with the host, where `hermes` (the CLI,
#     run as john, a member of the hermes group) uses the same sessions, memory,
#     skills and cron jobs. UID/GID 870 is fixed on both sides so ownership
#     lines up across the bind mount.
#   - Secrets: /etc/hermes/gateway.env on the host (root, 0600; never in this
#     repo) is mounted read-only into the container. Hermes's activation merges
#     it into $HERMES_HOME/.env, which the hermes group can read, so keep only
#     values john may see there (bot number, allowlist, the signal-cli URL).
#   - Webhooks: Home Assistant (and only it) reaches Hermes's webhook receiver
#     through nginx in the container on :8645, over mutual TLS with
#     certificates from the step CA: nginx requires a client certificate for
#     Home Assistant's name, and the receiver itself listens on the
#     container's loopback. The server certificate lives in /etc/hermes-tls on
#     the host (root plus the container nginx's group, which shares the host's
#     IDs; issued once by hand, renewed by a timer).
#   - PR events: on a review or comment, a workflow in each repo
#     (.github/workflows/pr-events.yml) joins the tailnet as tag:github-ci
#     (Tailscale workload identity federation; the tailnet policy lets that tag
#     reach only argo:8646) and posts {repo, pr}. The host DNATs
#     tailscale0:8646 to a plain-HTTP nginx listener in the container that only
#     forwards /webhooks/github-pr; github-pr.py treats the post as a hint and
#     reads the PR from GitHub itself.
#   - GitHub: Hermes acts as the zila-hermes GitHub App (installed on
#     jzila/home-assistant and jzila/nixfiles; no workflow permission, can't
#     bypass the main rulesets). The app's private key stays on the host
#     (/etc/hermes/github-app.pem, root 0600); a timer mints a one-hour
#     installation token every 30 minutes into /run/hermes-github, which the
#     container sees read-only and git and gh read on every call.
{ config, lib, pkgs, hermes-agent, ... }:
let
  hostAddress = "10.233.1.1";
  localAddress = "10.233.1.2";
  hermesId = 870;
  signalCliId = 871;
  stateDir = "/var/lib/hermes";

  # Mutual-TLS webhook ingress from Home Assistant.
  webhookPort = 8645;
  # An address, not a name: iptables resolves names once, at load, and the
  # firewall fails to start if DNS isn't up yet. The client certificate is
  # what authenticates.
  homeAssistantAddress = "192.168.1.153";
  homeAssistantCertName = "homeassistant.local.zila.dev";
  # PR event ingress from GitHub Actions over the tailnet (see the header).
  prEventsPort = 8646;
  tlsDir = "/etc/hermes-tls";
  stepRootCa = ./ssh-ca/root_ca.crt;
  # The container shares the host's IDs, so its nginx reads the bind-mounted
  # certificate as this group.
  nginxGid = toString config.ids.gids.nginx;

  # gh as the zila-hermes app, with the token the host mints.
  ghApp = pkgs.writeShellScriptBin "gh" ''
    GH_TOKEN=$(cat /run/host-secrets/github/token) exec ${lib.getExe pkgs.gh} "$@"
  '';

  # GitHub App credentials (see the header).
  githubAppId = "5415128";
  githubTokenDir = "/run/hermes-github";
  githubBotName = "zila-hermes[bot]";
  githubBotEmail = "345981252+zila-hermes[bot]@users.noreply.github.com";
in
{
  # ── Host side ─────────────────────────────────────────────────────────────
  users.groups.hermes.gid = hermesId;
  users.users.hermes = {
    isSystemUser = true;
    uid = hermesId;
    group = "hermes";
    home = stateDir;
  };
  users.users.john.extraGroups = [ "hermes" ];

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

  # The webhook server certificate is issued by hand for 30 days
  # (--not-after 720h); renewal keeps that lifetime. Check daily and renew in
  # the last 7 days (renewal authenticates with the current certificate, no
  # password), then have nginx pick it up, starting it if it was waiting.
  systemd.services.hermes-tls-renew = {
    description = "Renew the Hermes webhook TLS certificate";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.step-cli config.systemd.package pkgs.nixos-container ];
    script = ''
      [ -s ${tlsDir}/server.crt ] || exit 0
      step ca renew --force --expires-in 168h \
        --ca-url ${config.services.ssh-ca.caUrl} --root ${stepRootCa} \
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

  # Mint the GitHub App's installation token (an hour's life) for the container.
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
      jwt="$unsigned.$(printf %s "$unsigned" | openssl dgst -sha256 -sign /etc/hermes/github-app.pem | b64)"
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

  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-hermes" ];
  };

  # Network grants for the container, like the bindMounts below for files:
  #   - to the host: ollama only. Inserted ahead of the host's allowedTCPPorts,
  #     which apply on every interface and would otherwise also open Piper,
  #     Parakeet and dev ports to the container.
  #   - forwarded: DNS to Pi-hole and the router, nothing else on private or
  #     local ranges (LAN, Tailscale CGNAT, link-local, multicast), internet
  #     otherwise (Signal, web tools). Replies to connections made to the
  #     container are allowed.
  #   - inbound: the webhook port, DNATed to the container for Home
  #     Assistant's address only; the PR events port, for the tailnet only
  #     (tailnet policy narrows it to tag:github-ci).
  networking.firewall.extraCommands = ''
    iptables -w -N hermes-to-host 2>/dev/null || iptables -w -F hermes-to-host
    iptables -w -A hermes-to-host -p tcp --dport 11434 -j nixos-fw-accept
    iptables -w -A hermes-to-host -m conntrack --ctstate ESTABLISHED,RELATED -j nixos-fw-accept
    iptables -w -A hermes-to-host -j nixos-fw-refuse
    iptables -w -I nixos-fw 1 -i ve-hermes -j hermes-to-host

    iptables -w -N hermes-egress 2>/dev/null || iptables -w -F hermes-egress
    iptables -w -A hermes-egress -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    for resolver in 192.168.1.135 192.168.1.1; do
      for proto in udp tcp; do
        iptables -w -A hermes-egress -d "$resolver" -p "$proto" --dport 53 -j RETURN
      done
    done
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4; do
      iptables -w -A hermes-egress -d "$net" -j REJECT
    done
    iptables -w -D FORWARD -i ve-hermes -j hermes-egress 2>/dev/null || true
    iptables -w -I FORWARD 1 -i ve-hermes -j hermes-egress

    iptables -w -t nat -N hermes-ingress 2>/dev/null || iptables -w -t nat -F hermes-ingress
    iptables -w -t nat -A hermes-ingress -s ${homeAssistantAddress} -p tcp --dport ${toString webhookPort} \
      -m addrtype --dst-type LOCAL -j DNAT --to-destination ${localAddress}:${toString webhookPort}
    iptables -w -t nat -A hermes-ingress -i tailscale0 -s 100.64.0.0/10 -p tcp --dport ${toString prEventsPort} \
      -m addrtype --dst-type LOCAL -j DNAT --to-destination ${localAddress}:${toString prEventsPort}
    iptables -w -t nat -D PREROUTING -j hermes-ingress 2>/dev/null || true
    iptables -w -t nat -I PREROUTING 1 -j hermes-ingress
  '';
  # Also run before every reload. The chains must go, not just their jumps:
  # hermes-to-host's rules reference nixos-fw-accept/-refuse, which the
  # firewall deletes and recreates, so a leftover hermes-to-host makes that
  # fail and the reload falls back to stopping the firewall altogether.
  networking.firewall.extraStopCommands = ''
    iptables -w -D FORWARD -i ve-hermes -j hermes-egress 2>/dev/null || true
    iptables -w -t nat -D PREROUTING -j hermes-ingress 2>/dev/null || true
    iptables -w -D nixos-fw -i ve-hermes -j hermes-to-host 2>/dev/null || true
    for chain in hermes-to-host hermes-egress; do
      iptables -w -F "$chain" 2>/dev/null || true
      iptables -w -X "$chain" 2>/dev/null || true
    done
    iptables -w -t nat -F hermes-ingress 2>/dev/null || true
    iptables -w -t nat -X hermes-ingress 2>/dev/null || true
  '';
  # Leave the container's veth to the container configuration.
  networking.networkmanager.unmanaged = [ "interface-name:ve-*" ];

  containers.hermes = {
    autoStart = true;
    privateNetwork = true;
    inherit hostAddress localAddress;

    bindMounts = {
      ${stateDir} = {
        hostPath = stateDir;
        isReadOnly = false;
      };
      "/run/host-secrets/hermes" = {
        hostPath = "/etc/hermes";
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
      # Access grants go here, one per folder, e.g.:
      #   "/grants/notes" = { hostPath = "/home/john/notes"; isReadOnly = true; };
    };

    config =
      { config, ... }:
      {
        imports = [
          hermes-agent.nixosModules.default
          ./signal-cli.nix
        ];

        system.stateVersion = "26.05";

        networking.useHostResolvConf = lib.mkForce false;
        networking.nameservers = [
          "192.168.1.135"
          "192.168.1.1"
        ];

        users.groups.hermes.gid = hermesId;
        users.users.hermes.uid = hermesId;

        # GitHub as the zila-hermes app: git and gh read the host-minted
        # installation token on every call, so a rotated token is picked up
        # without a restart.
        programs.git = {
          enable = true;
          config = {
            user.name = githubBotName;
            user.email = githubBotEmail;
            credential."https://github.com".helper =
              "!f() { [ \"$1\" = get ] && echo username=x-access-token && echo password=$(cat /run/host-secrets/github/token); }; f";
          };
        };
        users.groups.signal-cli.gid = signalCliId;
        users.users.signal-cli.uid = signalCliId;

        # TLS front for the webhook receiver.
        networking.firewall.allowedTCPPorts = [ webhookPort prEventsPort ];
        services.nginx = {
          enable = true;
          recommendedTlsSettings = true;
          recommendedProxySettings = true;
          virtualHosts.hermes-webhooks = {
            onlySSL = true;
            listen = [
              {
                addr = "0.0.0.0";
                port = webhookPort;
                ssl = true;
              }
            ];
            sslCertificate = "/run/host-secrets/hermes-tls/server.crt";
            sslCertificateKey = "/run/host-secrets/hermes-tls/server.key";
            extraConfig = ''
              ssl_client_certificate ${stepRootCa};
              ssl_verify_client on;
              ssl_verify_depth 2;
              # Any certificate the step CA signed passes ssl_verify_client;
              # only Home Assistant's may post.
              if ($ssl_client_s_dn != "CN=${homeAssistantCertName}") {
                return 403;
              }
            '';
            locations."= /webhooks/ha-maintenance".proxyPass = "http://127.0.0.1:8644";
            locations."/".return = "404";
          };
          # PR events from the tailnet: plain HTTP (WireGuard encrypts it), one
          # path, small JSON bodies only.
          virtualHosts.hermes-pr-events = {
            listen = [
              {
                addr = "0.0.0.0";
                port = prEventsPort;
              }
            ];
            locations."= /webhooks/github-pr" = {
              proxyPass = "http://127.0.0.1:8644";
              extraConfig = ''
                limit_except POST { deny all; }
                client_max_body_size 4k;
              '';
            };
            locations."/".return = "404";
          };
        };
        # Wait for the certificate instead of failing; hermes-tls-renew on the
        # host starts nginx once one exists.
        systemd.services.nginx.unitConfig.ConditionPathExists = "/run/host-secrets/hermes-tls/server.crt";

        # Webhook route scripts must live under $HERMES_HOME/scripts (symlinks
        # out of it are refused), so copy them in on every start; a changed
        # script changes the unit, which restarts it. (tmpfiles' C+ never
        # replaces an existing file.)
        systemd.tmpfiles.rules = [
          "d ${stateDir}/.hermes/scripts 2770 hermes hermes -"
        ];
        systemd.services.hermes-agent.preStart = lib.mkAfter ''
          install -m 0444 ${
            pkgs.replaceVars ./hermes-scripts/ha-maintenance.py {
              hermes = lib.getExe' config.services.hermes-agent.package "hermes";
            }
          } ${stateDir}/.hermes/scripts/.ha-maintenance.py.new
          mv -f ${stateDir}/.hermes/scripts/.ha-maintenance.py.new ${stateDir}/.hermes/scripts/ha-maintenance.py
          install -m 0444 ${
            pkgs.replaceVars ./hermes-scripts/github-pr.py { gh = lib.getExe ghApp; }
          } ${stateDir}/.hermes/scripts/.github-pr.py.new
          mv -f ${stateDir}/.hermes/scripts/.github-pr.py.new ${stateDir}/.hermes/scripts/github-pr.py
        '';

        services.hermes-agent = {
          enable = true;
          extraPackages = [
            ghApp
            # search_files refuses broad searches without it.
            pkgs.ripgrep
          ];
          # Skills this repo maintains, installed into $HERMES_HOME/skills.
          hermesHomeFiles = {
            "skills/devops/home-assistant-changes/SKILL.md" =
              ./hermes-skills/home-assistant-changes/SKILL.md;
            "skills/devops/home-assistant-changes/references/make-pr.md" =
              ./hermes-skills/home-assistant-changes/references/make-pr.md;
          };
          inherit stateDir;
          # Shared-state permissions: config.yaml group-writable, so the host
          # CLI can save settings.
          addToSystemPackages = true;
          # The gateway's own directory (systemd WorkingDirectory).
          workingDirectory = "${stateDir}/workspace";
          environmentFiles = [ "/run/host-secrets/hermes/gateway.env" ];
          settings = {
            model = {
              provider = "custom";
              base_url = "http://${hostAddress}:11434/v1";
              default = "gemma4:26b-a4b";
              context_length = 262144;
            };
            # "." resolves against the process's working directory: the
            # gateway's workingDirectory above, and the launch directory for
            # the host CLI, which reads this same config.yaml.
            terminal.cwd = ".";
            # Always ask before dangerous commands (the default "smart" lets a
            # helper model approve some by itself).
            approvals.mode = "manual";
            # Kanban tools are hidden from chats unless the platform opts in,
            # so without this Hermes "records" tasks in its per-session
            # todo_list, which is gone once the conversation ends.
            platform_toolsets = {
              signal = [ "hermes-signal" "kanban" ];
              cli = [ "hermes-cli" "kanban" ];
            };
            # The board is a task list, not a work queue: don't let the
            # gateway spawn workers that act on tasks by themselves.
            kanban.dispatch_in_gateway = false;
            # Subagents (delegate_task, e.g. the HA PR work) run on a coding
            # model in Ollama Cloud, through the host's signed-in Ollama: no key
            # here. The work they're given leaves the house; chat stays local.
            delegation = {
              model = "glm-5.3:cloud";
              base_url = "http://${hostAddress}:11434/v1";
              api_key = "ollama"; # Ollama ignores it
              request_overrides.reasoning_effort = "high";
            };
            # Webhook receiver, reachable only through nginx above (loopback
            # is also the only bind Hermes allows without request signing;
            # mutual TLS authenticates instead). ha-maintenance's script
            # turns Home Assistant's device list into kanban tasks without
            # an agent turn.
            platforms.webhook = {
              enabled = true;
              extra = {
                host = "127.0.0.1";
                port = 8644;
                routes.ha-maintenance = {
                  secret = "INSECURE_NO_AUTH";
                  script = "ha-maintenance.py";
                  deliver = "log";
                };
                # Activity on Hermes's own PRs (see the header): github-pr.py
                # reads the PR and either drops the event or writes the
                # prompt; the reply goes to the Signal home channel (/sethome).
                routes.github-pr = {
                  secret = "INSECURE_NO_AUTH";
                  script = "github-pr.py";
                  prompt = "{prompt}";
                  deliver = "signal";
                };
              };
            };
          };
        };
      };
  };
}
