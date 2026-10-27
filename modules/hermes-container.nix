# Hermes Agent's messaging gateway, sandboxed in a NixOS container together
# with the signal-cli daemon it talks to.
#
# Why a container (and not the upstream module's container mode): upstream runs
# an Ubuntu image with --network=host and passwordless sudo for the agent, and
# forces the host CLI into the container. Here the container is a plain NixOS
# system with a private network, and inside it the upstream module runs in its
# native mode: the gateway is the unprivileged `hermes` user, never root.
# What runs inside (the gateway, signal-cli, nginx, scripts, skills) is
# modules/hermes-service.nix.
#
# Two hosts use this module, one at a time: argo today, and the hermes VM on
# the TrueNAS box (hosts/hermes/), which runs this same container with its own
# credentials. The options below are what differs between them (addresses,
# where ollama is, who shares the state); their defaults are argo's. At the
# cut-over (hosts/hermes/README.md) argo sets enable = false, which drops the
# container and everything argo keeps for it.
#
#   - Network: private veth (on argo 10.233.1.2), NAT to the internet.
#     signal-cli's JSON-RPC listens on the container's own loopback, so nothing
#     on the host can use the bot's Signal account. On argo the host is
#     10.233.1.1, which is how the container reaches ollama; in the VM, ollama
#     is argo over the LAN (allowedLanTargets).
#   - Filesystem: the container sees its own root, the read-only Nix store, the
#     shared Hermes state, and nothing of the host's /home. Grant more by adding
#     bindMounts below (isReadOnly = true unless writes are wanted).
#   - State: /var/lib/hermes is shared with the host, where `hermes` (the CLI,
#     run as john, a member of the hermes group) uses the same sessions, memory,
#     skills and cron jobs. UID/GID 870 is fixed on both sides so ownership
#     lines up across the bind mount.
#   - Secrets: /etc/hermes/gateway.env on the host (root, 0600; never in this
#     repo) is mounted read-only into the container, that one file and nothing
#     else of /etc/hermes (the GitHub App key beside it stays on the host).
#     The mount holds the file the container started with, so after replacing
#     it restart the container, not just the gateway. Hermes's activation merges
#     it into $HERMES_HOME/.env, which the hermes group can read, so keep only
#     values john may see there (bot number, allowlist, the signal-cli URL).
#   - Webhooks: Home Assistant (and only it) reaches Hermes's webhook receiver
#     through nginx in the container on :8645, over mutual TLS with
#     certificates from the step CA: nginx requires a client certificate for
#     Home Assistant's name, and the receiver itself listens on the
#     container's loopback. The server certificate lives in /etc/hermes-tls on
#     the host (root plus the container nginx's group, which shares the host's
#     IDs; issued once by hand, renewed by a timer). Two routes: ha-maintenance
#     (device lists reconciled into kanban tasks, no agent turn) and ha-log
#     (errors and some warnings Home Assistant logs: one task per distinct
#     issue, and a triage turn on Signal for new ones, rate-limited).
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

  # GitHub App credentials (see the header).
  githubTokenDir = "/run/hermes-github";

  cfg = config.services.hermesContainer;

  # Firewall lines from the options; empty lists add nothing.
  hostPortRules = lib.optionalString (cfg.hostPorts != [ ]) ''
    iifname "ve-hermes" tcp dport { ${lib.concatMapStringsSep ", " toString cfg.hostPorts} } accept
  '';
  egressRules = lib.concatMapStrings (t: ''
    ip daddr ${t.address} tcp dport ${toString t.port} accept
  '') cfg.allowedLanTargets;
in
{
  imports = [ ./hermes-credentials.nix ];

  options.services.hermesContainer = {
    # Never on in two places at once (hosts/hermes/README.md).
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run Hermes in the NixOS container, and what the host keeps for it.";
    };
    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.233.1.1";
      description = "The host's end of the container's veth.";
    };
    localAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.233.1.2";
      description = "The container's address.";
    };
    ollamaHost = lib.mkOption {
      type = lib.types.str;
      default = cfg.hostAddress;
      defaultText = lib.literalExpression "hostAddress";
      description = "Where the container reaches ollama: the host itself, or argo over the LAN.";
    };
    hostPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 11434 ];
      description = "Ports on the host the container may reach (argo: ollama).";
    };
    allowedLanTargets = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options.address = lib.mkOption { type = lib.types.str; };
        options.port = lib.mkOption { type = lib.types.port; };
      });
      default = [ ];
      description = "TCP services on private ranges the container may reach, forwarded (e.g. argo's ollama from the VM).";
    };
    resolvers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "192.168.1.135" "192.168.1.1" ];
      description = "DNS servers the container may query (Pi-hole, the router).";
    };
    # An address, not a name: nft resolves names once, at load, and the
    # firewall fails to start if DNS isn't up yet. The client certificate is
    # what authenticates.
    homeAssistantAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.153";
      description = "The only source DNATed to the mutual-TLS webhook port.";
    };
    stateUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "john" ];
      description = "Host users in the hermes group, who share the state through the CLI.";
    };
    hideNixDaemon = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Cover the host's nix-daemon socket inside the container, so nothing in it can build.";
    };
  };

  config = lib.mkIf cfg.enable {
  # ── Host side ─────────────────────────────────────────────────────────────
  users.groups.hermes.gid = hermesId;
  users.users = {
    hermes = {
      isSystemUser = true;
      uid = hermesId;
      group = "hermes";
      home = stateDir;
    };
  } // lib.genAttrs cfg.stateUsers (_: { extraGroups = [ "hermes" ]; });

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

  # Token minting and certificate renewal (modules/hermes-credentials.nix).
  hermes.credentials = {
    enable = true;
    inherit githubTokenDir tlsDir;
    renewPath = [ pkgs.nixos-container ];
    reloadNginx = ''
      # Also picks up a certificate reissued by hand.
      nixos-container run hermes -- systemctl reload-or-restart nginx
    '';
  };

  # ── The container ─────────────────────────────────────────────────────────
  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-hermes" ];
  };

  # Network grants for the container, like the bindMounts below for files:
  #   - to the host: hostPorts only (ollama on argo). Everything else from the
  #     container is rejected, including the host's allowedTCPPorts, which
  #     apply on every interface and would otherwise also open Piper,
  #     Parakeet and dev ports to the container.
  #   - forwarded: DNS to Pi-hole and the router, nothing else on private or
  #     local ranges (LAN, Tailscale CGNAT, link-local, multicast), internet
  #     otherwise (Signal, web tools). Replies to connections made to the
  #     container are allowed.
  #   - inbound: the webhook port, DNATed to the container for Home
  #     Assistant's address only; the PR events port, for the tailnet only
  #     (tailnet policy narrows it to tag:github-ci).
  # Its own nftables table (the host must use nftables): loaded atomically
  # with the rest of the ruleset, and gone at the next switch if this module
  # is turned off. Base chains run just before the firewall's own (priority
  # filter - 1); a packet needs every hook's chains to accept it, so these
  # only narrow what the firewall would allow.
  assertions = [{
    assertion = config.networking.nftables.enable;
    message = "services.hermesContainer needs networking.nftables.enable.";
  }];
  networking.firewall.interfaces.ve-hermes.allowedTCPPorts = cfg.hostPorts;
  networking.nftables.tables.hermes = {
    family = "inet";
    content = ''
      chain to-host {
        type filter hook input priority filter - 1; policy accept;
        iifname "ve-hermes" ct state established,related accept
        ${hostPortRules}iifname "ve-hermes" reject
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
      # Access grants go here, one per folder, e.g.:
      #   "/grants/notes" = { hostPath = "/home/john/notes"; isReadOnly = true; };
    } // lib.optionalAttrs cfg.hideNixDaemon {
      # nspawn binds the host's daemon socket into every container; cover it.
      "/nix/var/nix/daemon-socket/socket" = {
        hostPath = "/dev/null";
        isReadOnly = true;
      };
    };

    # The inner system is modules/hermes-service.nix, shared with the VM.
    specialArgs = { inherit hermes-agent; };
    config = {
      imports = [ ./hermes-service.nix ];
      hermes.ollamaHost = cfg.ollamaHost;
      system.stateVersion = "26.05";
      networking.useHostResolvConf = lib.mkForce false;
    };
  };
  };
}
