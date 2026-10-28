# GitHub Actions runners, each in its own NixOS container (the hermes VM). A
# runner's container is named after it and holds only what its jobs need:
#
#   - Credentials: a root-only directory on the host (secretsDir, under a
#     0700 parent), bound read-only into that container alone, holding at
#     least runner-token (a one-hour registration token, consumed at first
#     start). The container starts only once that directory exists, so a
#     runner never registers before it is provisioned. Only root can enter
#     the containers.
#   - Jobs: a job-started hook (runner-guard.nix) refuses any job that isn't
#     the repo's own, from main's workflows, against main, for the runner's
#     events. Approval
#     is the repo's main ruleset's (PR required, John's review as code
#     owner), so a runner runs whatever reaches main.
#   - Network: its own namespace (NAT, nothing of the host's loopback);
#     DNS to the resolvers, its own `allow` rules, the internet, and nothing
#     else on private or local ranges; nothing on the host; no new
#     connections in. One nftables table for all of them (the host must use
#     nftables), next to hermes-container.nix's.
#   - Nix: `nix develop` in the jobs, through the host's nix-daemon (the
#     host's allowed-users must list the runner's user).
#
# Each runner registers as <hostname>-<name>, with the label <name>.
{ config, lib, ... }:
let
  cfg = config.services.runnerContainers;
  ifs = lib.mapAttrsToList (name: _: "\"ve-${name}\"") cfg;
  anyIf = "{ ${lib.concatStringsSep ", " ifs} }";
  # Per runner: DNS, then its own rules.
  allowed = lib.concatLists (lib.mapAttrsToList (name: r:
    map (match: ''iifname "ve-${name}" ${match} accept'') (
      [ "ip daddr { ${lib.concatStringsSep ", " r.resolvers} } meta l4proto { tcp, udp } th dport 53" ] ++ r.allow)
  ) cfg);

  container = name: r: {
    autoStart = true;
    privateNetwork = true;
    inherit (r) hostAddress localAddress;
    bindMounts = {
      ${r.secrets.path} = {
        hostPath = r.secrets.hostPath;
        isReadOnly = true;
      };
    } // r.bindMounts;
    config = { lib, pkgs, ... }: {
      system.stateVersion = "26.05";
      networking.useHostResolvConf = lib.mkForce false;
      networking.nameservers = cfg.${name}.resolvers;
      nix.settings.experimental-features = [ "nix-command" "flakes" ];
      users.groups.${r.group}.gid = r.gid;
      users.users.${r.user} = {
        isSystemUser = true;
        inherit (r) uid group;
      };
      services.github-runners.${name} = lib.recursiveUpdate {
        enable = true;
        name = "${config.networking.hostName}-${name}";
        url = "https://github.com/${r.repo}";
        tokenFile = "${r.secrets.path}/runner-token";
        replace = true;
        extraLabels = [ name ];
        inherit (r) user group;
        extraEnvironment.ACTIONS_RUNNER_HOOK_JOB_STARTED = import ./runner-guard.nix { inherit lib pkgs; } name r.repo r.events;
      } r.runner;
      # The host sets up the container's network as the container boots, so
      # the first registration can fail on DNS; the module doesn't retry.
      systemd.services."github-runner-${name}".serviceConfig = {
        Restart = lib.mkForce "on-failure";
        RestartSec = "30s";
      };
    };
  };
in
{
  options.services.runnerContainers = lib.mkOption {
    default = { };
    description = "GitHub Actions runners, each in its own container (see the header).";
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        repo = lib.mkOption {
          type = lib.types.str;
          example = "jzila/home-assistant";
        };
        events = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          description = "Events whose jobs the runner accepts.";
        };
        user = lib.mkOption { type = lib.types.str; };
        uid = lib.mkOption { type = lib.types.int; };
        group = lib.mkOption { type = lib.types.str; };
        gid = lib.mkOption { type = lib.types.int; };
        hostAddress = lib.mkOption { type = lib.types.str; };
        localAddress = lib.mkOption { type = lib.types.str; };
        resolvers = lib.mkOption { type = lib.types.listOf lib.types.str; };
        secrets = {
          hostPath = lib.mkOption {
            type = lib.types.str;
            description = "Root-only directory on the host with runner-token and the jobs' secrets.";
          };
          path = lib.mkOption {
            type = lib.types.str;
            description = "Where it is bound in the container.";
          };
        };
        bindMounts = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "More of containers.<name>.bindMounts.";
        };
        allow = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "ip daddr 192.168.1.153 tcp dport { 22, 443 }" ];
          description = "nftables matches for what the runner may reach on private ranges.";
        };
        runner = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "Merged into the container's services.github-runners.<name>.";
        };
      };
    });
  };

  config = lib.mkIf (cfg != { }) {
    containers = lib.mapAttrs container cfg;
    systemd.services = lib.mapAttrs' (name: r:
      lib.nameValuePair "container@${name}" { unitConfig.ConditionPathExists = r.secrets.hostPath; }
    ) cfg;

    networking.nat = {
      enable = true;
      internalInterfaces = lib.mapAttrsToList (name: _: "ve-${name}") cfg;
    };
    assertions = [{
      assertion = config.networking.nftables.enable;
      message = "services.runnerContainers needs networking.nftables.enable.";
    }];
    networking.nftables.tables.runner-containers = {
      family = "inet";
      content = ''
        chain to-host {
          type filter hook input priority filter - 1; policy accept;
          iifname ${anyIf} ct state established,related accept
          iifname ${anyIf} reject
        }

        chain egress {
          type filter hook forward priority filter - 1; policy accept;
          oifname ${anyIf} ct state new reject
          iifname != ${anyIf} accept
          ct state established,related accept
          ${lib.concatMapStrings (l: l + "\n  ") allowed}ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 224.0.0.0/4 } reject
        }
      '';
    };
  };
}
