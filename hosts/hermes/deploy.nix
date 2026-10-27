# The hermes VM deploys jzila/nixfiles main to itself; argo never deploys
# automatically. CI's "Deploy (hermes)" job (.github/workflows/ci.yml), on
# every push to main once the builds pass, runs on the VM's own GitHub runner
# `nixfiles` (its container, modules/runner-containers.nix: no credentials but
# its registration token, nothing on the LAN). It can't switch the VM; it
# asks: it drops a request in /run/nixos-deploy/request (deploy/request.sh),
# which starts nixos-deploy.service as root here (deploy/run.sh), and streams
# that run's log and verdict from /run/nixos-deploy/result into the job. The
# job passes once its commit, or a later one on main, is deployed. A failed
# or paused deploy fails the job; "Re-run" in GitHub tries again. Jobs run one
# at a time (the job's concurrency group). The deploy itself (deploy/deploy.sh)
# doesn't trust the request, only main:
#
#   1. reads main's head with `git ls-remote` (public repo, no credentials)
#      and stops if that commit is deployed and running, or failed and main
#      hasn't moved;
#   2. requires GitHub Actions' "Build NixOS (hermes)" check on that exact
#      commit to have succeeded (public API, unauthenticated);
#   3. refuses a commit that isn't a descendant of the deployed one;
#   4. builds github.com/jzila/nixfiles at that rev (never a branch, never a
#      local checkout), and if it's the running system, records it and stops;
#   5. switches (which restarts the hermes container, or a Home Assistant
#      runner's, when its system changed; the nixfiles runner's container is
#      restarted by run.sh once its job is done), then checks health for up
#      to 5 minutes: the units below active, no unit failed that wasn't
#      failed before, github.com reachable, and hermes-health
#      (deploy/health.sh), which looks into the hermes container: the gateway
#      running with its webhook platform and, once an account is registered,
#      Signal connected; signal-cli and nginx (once it has its certificate)
#      active; the receiver answering; argo's ollama reachable from inside,
#      through the container's egress rules.
#      Unhealthy, or a broken activation: it switches back to the system it
#      replaced and records the commit as failed.
#
# What it can change is the VM's own system, on its own disk: the switch
# also installs the boot entry, so a reboot comes up on the deployed system.
# What TrueNAS gives the VM (CPUs, memory, the disk, the NIC) is TrueNAS's.
# Booted into another generation (picked by hand at the boot menu), the next
# deploy switches back to the deployed commit (deployed and system in the
# state directory); pause it first to stay there.
#
# History only moves forward: main must be ahead of the deployed commit. A
# revert is a new descendant and deploys normally; a force-push (blocked by the
# ruleset) or an admin reset of main is refused and filed until
# /var/lib/nixos-deploy/deployed is removed.
#
# Kill switch: touch /var/lib/nixos-deploy/paused in the VM (deploy jobs then
# fail, saying so).
#
# State is in /var/lib/nixos-deploy (deployed, system, attempt, report.md).
# Logs: the job's, or journalctl -u nixos-deploy -u nixos-deploy-switch -u nixos-deploy-rollback
# Failures are filed on the VM's kanban board (untenanted, "hermes deploy:")
# by nixos-deploy-report, as hermes; the next deploy completes them.
{ config, lib, pkgs, hermes-agent, ... }:
let
  stateDir = "/var/lib/nixos-deploy";
  runDir = "/run/nixos-deploy";
  runnerId = 882;
  hermesHome = "/var/lib/hermes/.hermes";

  # Must be active after a switch, if the new system still has them.
  healthUnits = [
    "container@hermes.service"
    "systemd-networkd.service"
    "tailscaled.service"
    "sshd.service"
    "nix-daemon.socket"
  ];

  health = pkgs.writeShellApplication {
    name = "hermes-health";
    runtimeEnv = {
      HERMES_HEALTH_IN = "nixos-container run hermes --";
      # The store is shared, so the container runs the host's curl.
      HERMES_HEALTH_CURL = lib.getExe pkgs.curl;
      HERMES_HEALTH_SIGNAL = "/var/lib/nixos-containers/hermes/var/lib/signal-cli/data/accounts.json";
      HERMES_HEALTH_OLLAMA = "http://${config.hermesVm.ollamaAddress}:11434/api/version";
    };
    runtimeInputs = with pkgs; [ config.systemd.package nixos-container curl jq ];
    text = builtins.readFile ./deploy/health.sh;
  };

  deploy = pkgs.writeShellApplication {
    name = "nixos-deploy";
    runtimeInputs = with pkgs; [
      config.nix.package
      config.systemd.package
      git
      curl
      jq
      coreutils
      util-linux # flock
      gawk
    ];
    text = builtins.readFile ./deploy/deploy.sh;
  };

  run = pkgs.writeShellApplication {
    name = "nixos-deploy-run";
    runtimeInputs = with pkgs; [ deploy config.systemd.package nixos-container coreutils gnused ];
    text = builtins.readFile ./deploy/run.sh;
  };

  # The job's step, in the runner's container.
  request = pkgs.writeShellApplication {
    name = "nixos-deploy-request";
    runtimeInputs = with pkgs; [ coreutils curl jq ];
    text = builtins.readFile ./deploy/request.sh;
  };

  report = pkgs.writeShellApplication {
    name = "nixos-deploy-report";
    runtimeInputs = [ hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default pkgs.jq ];
    text = builtins.readFile ./deploy/report.sh;
  };
in
{
  imports = [ ../../modules/runner-containers.nix ];

  environment.systemPackages = [ deploy health ]; # dry runs: NIXOS_DEPLOY_DRY_RUN=1

  # The runner, registered as hermes-nixfiles. Its credentials directory,
  # /etc/nixfiles-runner (root 0700, runner-token), is provisioned by hand
  # (README.md); its container starts once that exists.
  services.runnerContainers.nixfiles = {
    repo = "jzila/nixfiles";
    events = [ "push" ];
    user = "nixfiles-runner";
    uid = runnerId;
    group = "nixfiles-runner";
    gid = runnerId;
    hostAddress = "10.233.5.1";
    localAddress = "10.233.5.2";
    inherit (config.hermesVm) resolvers;
    secrets = {
      hostPath = "/etc/nixfiles-runner";
      path = "/etc/nixfiles-runner";
    };
    bindMounts = {
      "${runDir}/request" = {
        hostPath = "${runDir}/request";
        isReadOnly = false;
      };
      "${runDir}/result" = {
        hostPath = "${runDir}/result";
        isReadOnly = true;
      };
    };
    runner = {
      extraPackages = [ request ];
      serviceOverrides.ReadWritePaths = [ "${runDir}/request" ];
    };
  };
  # Its job waits on the deploy that would restart it (run.sh restarts it).
  containers.nixfiles.restartIfChanged = false;
  systemd.tmpfiles.rules = [
    "d ${runDir} 0755 root root -"
    "d ${runDir}/request 0700 ${toString runnerId} ${toString runnerId} -"
    "d ${runDir}/result 0755 root root -"
  ];

  systemd.services.nixos-deploy = {
    description = "Deploy jzila/nixfiles main to this VM";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # The running deploy is the one switching: a switch must neither stop nor
    # restart it. (It switches through systemd-run, so even a commit that drops
    # this module only ends the deploy after the switch.)
    restartIfChanged = false;
    environment = {
      NIXOS_DEPLOY_HOST = config.networking.hostName;
      NIXOS_DEPLOY_UNITS = lib.concatStringsSep " " healthUnits;
      NIXOS_DEPLOY_CHECK = lib.getExe health;
      NIXOS_DEPLOY_PAUSE = "${stateDir}/paused";
      NIXOS_DEPLOY_RUN_DIR = runDir;
      NIXOS_DEPLOY_RUNNER = "nixfiles";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe run;
      StateDirectory = "nixos-deploy";
      StateDirectoryMode = "0755"; # report.md is read by hermes
      # The build has its own timeout (4h); never cut a switch short.
      TimeoutStartSec = "infinity";
    };
  };
  # A waiting request starts it (again, once a running deploy is done).
  systemd.paths.nixos-deploy = {
    wantedBy = [ "paths.target" ];
    pathConfig.DirectoryNotEmpty = "${runDir}/request";
  };

  # Reporting: reconcile each verdict with the kanban board.
  systemd.paths.nixos-deploy-report = {
    wantedBy = [ "paths.target" ];
    pathConfig.PathChanged = "${stateDir}/report.md";
  };
  systemd.services.nixos-deploy-report = {
    description = "Reconcile nixos-deploy's verdict with the kanban board";
    unitConfig.ConditionPathExists = "${stateDir}/report.md";
    environment.HERMES_HOME = hermesHome;
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      ExecStart = "${lib.getExe report} ${stateDir}/report.md";
    };
  };
}
