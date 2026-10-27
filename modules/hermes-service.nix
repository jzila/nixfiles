# What runs inside Hermes's sandbox: Hermes Agent's gateway (as the
# unprivileged `hermes` user), signal-cli, nginx in front of the webhook
# receiver, the webhook scripts and the skills this repo maintains: the inner
# system of the hermes container (modules/hermes-container.nix), on argo and
# in the hermes VM alike; see the container's header for the design.
#
# The container provides, as read-only bind mounts of the host's copies:
#   /run/host-secrets/hermes        gateway.env alone (root-only)
#   /run/host-secrets/hermes-tls    the webhook server certificate (nginx's group)
#   /run/host-secrets/github        the GitHub App installation token (hermes's group)
# plus Hermes's state at /var/lib/hermes, and where ollama is in
# hermes.ollamaHost.
{ config, lib, pkgs, hermes-agent, ... }:
let
  secretsDir = "/run/host-secrets/hermes";
  tlsDir = "/run/host-secrets/hermes-tls";
  githubTokenDir = "/run/host-secrets/github";
  hostAddress = config.hermes.ollamaHost;
  hermesId = 870;
  signalCliId = 871;
  stateDir = "/var/lib/hermes";

  # Mutual-TLS webhook ingress from Home Assistant.
  webhookPort = 8645;
  homeAssistantCertName = "homeassistant.local.zila.dev";
  # PR event ingress from GitHub Actions over the tailnet.
  prEventsPort = 8646;
  stepRootCa = ./ssh-ca/root_ca.crt;

  # gh as the zila-hermes app, with the token root mints
  # (modules/hermes-credentials.nix).
  ghApp = pkgs.writeShellScriptBin "gh" ''
    GH_TOKEN=$(cat ${githubTokenDir}/token) exec ${lib.getExe pkgs.gh} "$@"
  '';

  githubBotName = "zila-hermes[bot]";
  githubBotEmail = "345981252+zila-hermes[bot]@users.noreply.github.com";

  hermes = lib.getExe' config.services.hermes-agent.package "hermes";
  hermesHome = "${stateDir}/.hermes";
  scripts = pkgs.runCommand "hermes-scripts" { } ''
    mkdir $out
    cp ${pkgs.replaceVars ./hermes-scripts/ha-maintenance.py { inherit hermes; }} $out/ha-maintenance.py
    cp ${pkgs.replaceVars ./hermes-scripts/ha-log.py { inherit hermes; }} $out/ha-log.py
    cp ${pkgs.replaceVars ./hermes-scripts/github-pr.py { gh = lib.getExe ghApp; }} $out/github-pr.py
  '';
  # See BindReadOnlyPaths below.
  readOnlyState = [
    "${scripts}:${hermesHome}/scripts"
    "${./hermes-plugins/model-options}:${hermesHome}/plugins/model-options"
    "${hermesHome}/skills/devops/home-assistant-changes"
    "${hermesHome}/skills/devops/nixfiles-changes"
    "${hermesHome}/config.yaml"
    "${hermesHome}/.env"
  ];
in
{
  imports = [
    hermes-agent.nixosModules.default
    ./signal-cli.nix
  ];

  options.hermes.ollamaHost = lib.mkOption {
    type = lib.types.str;
    description = "Where ollama listens (no authentication): the host, or argo over the LAN.";
  };

  config = {
    networking.nameservers = [
      "192.168.1.135"
      "192.168.1.1"
    ];

    users.groups.hermes.gid = hermesId;
    users.users.hermes.uid = hermesId;

    # GitHub as the zila-hermes app: git and gh read the root-minted
    # installation token on every call, so a rotated token is picked up
    # without a restart.
    programs.git = {
      enable = true;
      config = {
        user.name = githubBotName;
        user.email = githubBotEmail;
        credential."https://github.com".helper =
          "!f() { [ \"$1\" = get ] && echo username=x-access-token && echo password=$(cat ${githubTokenDir}/token); }; f";
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
        sslCertificate = "${tlsDir}/server.crt";
        sslCertificateKey = "${tlsDir}/server.key";
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
        locations."= /webhooks/ha-log".proxyPass = "http://127.0.0.1:8644";
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
    # Wait for the certificate instead of failing; nginx is started once one
    # exists (the TLS renewal's reloadNginx).
    systemd.services.nginx.unitConfig.ConditionPathExists = "${tlsDir}/server.crt";

    # What defines Hermes's own behaviour changes only through this repo:
    # Hermes owns its state directory, so the webhook route scripts, the
    # skills maintained here, config.yaml (its routes, toolsets and
    # approvals; the activation merge keeps keys Nix doesn't set) and
    # .env (the Signal allowlist) are mounted read-only over it for the
    # gateway and for Hermes's user manager, which `systemd-run --user`
    # would otherwise run commands under. The scripts must be regular
    # files under $HERMES_HOME/scripts (symlinks out of it are refused),
    # hence a copied tree; a changed script changes the unit, which
    # restarts it. Activation writes the rest before either unit starts.
    # The user manager keeps its view until the container restarts.
    systemd.tmpfiles.rules = [
      "d ${hermesHome}/scripts 2770 hermes hermes -"
      "d ${hermesHome}/plugins 2770 hermes hermes -"
      "d ${hermesHome}/plugins/model-options 2770 hermes hermes -"
    ];
    systemd.services.hermes-agent.serviceConfig.BindReadOnlyPaths = readOnlyState;
    systemd.services."user@${toString hermesId}" = {
      overrideStrategy = "asDropin";
      serviceConfig.BindReadOnlyPaths = readOnlyState;
    };

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
        "skills/devops/nixfiles-changes/SKILL.md" =
          ./hermes-skills/nixfiles-changes/SKILL.md;
        "skills/devops/nixfiles-changes/references/make-pr.md" =
          ./hermes-skills/nixfiles-changes/references/make-pr.md;
      };
      inherit stateDir;
      # Shared-state permissions: config.yaml group-writable, so the host
      # CLI can save settings.
      addToSystemPackages = true;
      # The gateway's own directory (systemd WorkingDirectory).
      workingDirectory = "${stateDir}/workspace";
      environmentFiles = [ "${secretsDir}/gateway.env" ];
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
        # model in the cloud: by default one in Ollama Cloud, through
        # argo's signed-in Ollama (no key here). The model-options backend
        # (hermes-plugins/model-options) lets each task pick another; the
        # OpenRouter ones need OPENROUTER_API_KEY in gateway.env and are
        # refused without it. The work they're given leaves the house; chat
        # stays local.
        delegation = rec {
          backend = "model-options";
          model = "glm-5.3:cloud";
          base_url = "http://${hostAddress}:11434/v1";
          api_key = "ollama"; # Ollama ignores it
          request_overrides.reasoning_effort = "high";
          backends.model-options.options = [
            {
              name = "glm";
              description = "GLM 5.3 on Ollama Cloud, the usual one: fast, no per-token cost.";
              inherit model base_url api_key request_overrides;
            }
            {
              name = "argon";
              description = "Gemini 4 Argon on OpenRouter, standard tier: stronger at large or tricky code, seconds per step, paid.";
              provider = "openrouter";
              model = "google/gemini-4-argon";
              reasoning_effort = "high";
            }
            {
              name = "argon-flex";
              description = "Gemini 4 Argon on OpenRouter's flex tier: half the price, but each step can take minutes and fails when Google is busy; only for long background work nobody is waiting on.";
              provider = "openrouter";
              model = "google/gemini-4-argon";
              reasoning_effort = "high";
              request_overrides.service_tier = "flex";
            }
          ];
        };
        plugins.enabled = [ "model-options" ];
        # On OpenRouter, only endpoints that don't store or train on
        # prompts; flex answers can take up to ~15 minutes.
        provider_routing.models."google/gemini-4-argon".data_collection = "deny";
        providers.openrouter.models."google/gemini-4-argon" = {
          timeout_seconds = 1200;
          stale_timeout_seconds = 1200;
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
            # Errors Home Assistant logs: ha-log.py keeps one kanban task
            # per distinct issue and writes a triage prompt only for a new
            # one (otherwise [SILENT]); the reply goes to Signal as for
            # github-pr below.
            routes.ha-log = {
              secret = "INSECURE_NO_AUTH";
              script = "ha-log.py";
              prompt = "{prompt}";
              deliver = "signal";
              # The log text is untrusted, but it reaches the prompt only
              # sanitised and marked as data, and triage needs more than the
              # web-only default: the terminal (git, reading HA's states),
              # delegate_task for a fix John asks for, and the kanban task.
              toolsets = [
                "hermes-signal"
                "kanban"
              ];
            };
            # Activity on Hermes's own PRs (see the container's header):
            # github-pr.py reads the PR and either drops the event or writes
            # the prompt; the reply goes to the Signal home channel
            # (SIGNAL_HOME_CHANNEL in /etc/hermes/gateway.env: managed
            # mode refuses /sethome's config write).
            routes.github-pr = {
              secret = "INSECURE_NO_AUTH";
              script = "github-pr.py";
              prompt = "{prompt}";
              deliver = "signal";
              # Webhook turns default to a web-only toolset (payloads are
              # untrusted). This prompt is built by github-pr.py from the
              # PR as read from GitHub, with only John's comments, so it
              # gets the tools of his Signal chats.
              toolsets = [
                "hermes-signal"
                "kanban"
              ];
            };
          };
        };
      };
    };
  };
}
