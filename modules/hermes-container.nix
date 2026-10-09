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
{ lib, hermes-agent, ... }:
let
  hostAddress = "10.233.1.1";
  localAddress = "10.233.1.2";
  hermesId = 870;
  signalCliId = 871;
  stateDir = "/var/lib/hermes";
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
  ];

  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-hermes" ];
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
      "/run/host-secrets/hermes" = {
        hostPath = "/etc/hermes";
        isReadOnly = true;
      };
      # Access grants go here, one per folder, e.g.:
      #   "/grants/notes" = { hostPath = "/home/john/notes"; isReadOnly = true; };
    };

    config =
      { ... }:
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
        users.groups.signal-cli.gid = signalCliId;
        users.users.signal-cli.uid = signalCliId;

        services.hermes-agent = {
          enable = true;
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
          };
        };
      };
  };
}
