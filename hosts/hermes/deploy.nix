# The hermes microVM deploys jzila/nixfiles main to itself; argo never
# deploys automatically (see modules/hermes-vm/host.nix). A root timer in the
# VM, every 2 minutes:
#
#   1. reads main's head with `git ls-remote` (public repo, no credentials)
#      and stops if that commit is deployed and running, or failed and main
#      hasn't moved;
#   2. waits until GitHub Actions' "Build NixOS (hermes)" check on that exact
#      commit has succeeded (public API, unauthenticated; any API error or
#      rate limit just means "next round");
#   3. refuses a commit that isn't a descendant of the deployed one;
#   4. builds github.com/jzila/nixfiles at that rev (never a branch, never a
#      local checkout), and if it's the running system, records it and stops;
#   5. switches, then checks health for up to 5 minutes: the units below
#      active, no unit failed that wasn't failed before, github.com
#      reachable, and hermes-health (deploy/health.sh): the gateway running
#      with its webhook platform and, once an account is registered, Signal
#      connected; the receiver answering; ollama on argo reachable.
#      Unhealthy, or a broken activation: it switches back to the system it
#      replaced and records the commit as failed.
#
# What it can change is the VM: its kernel, disks, shares and network are
# argo's (modules/hermes-vm/boundary.nix, built into argo's runner), and a
# restart boots what argo last built, until the next round switches back to
# the deployed commit (deployed and system in the state directory). The
# store's writable layer starts empty on every VM start, so that round
# rebuilds what argo's image lacks.
#
# History only moves forward: main must be ahead of the deployed commit. A
# revert is a new descendant and deploys normally; a force-push (blocked by the
# ruleset) or an admin reset of main is refused and filed until
# /var/lib/nixos-deploy/deployed is removed.
#
# Kill switches: /var/lib/nixos-deploy/paused in the VM, or from argo
# /etc/hermes/vm-deploy-paused (the VM sees it read-only, from its next
# start; `sudo touch /run/hermes-vm/secrets/deploy-paused` for the running
# VM, until argo reboots).
#
# State is in /var/lib/nixos-deploy (deployed, system, attempt, report.md).
# Logs: journalctl -u nixos-deploy -u nixos-deploy-switch -u nixos-deploy-rollback
# Failures are filed on the VM's kanban board (untenanted, "hermes deploy:")
# by nixos-deploy-report, as hermes; the next deploy completes them.
{ config, lib, pkgs, ... }:
let
  stateDir = "/var/lib/nixos-deploy";
  hermesHome = "/var/lib/hermes/.hermes";

  # Must be active after a switch, if the new system still has them.
  healthUnits = [
    "hermes-agent.service"
    "signal-cli.service"
    "nginx.service" # skipped while it waits for its certificate
    "systemd-networkd.service"
    "nix-daemon.socket"
  ];

  health = pkgs.writeShellApplication {
    name = "hermes-health";
    runtimeInputs = with pkgs; [ config.systemd.package curl jq ];
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

  report = pkgs.writeShellApplication {
    name = "nixos-deploy-report";
    runtimeInputs = [ config.services.hermes-agent.package pkgs.jq ];
    text = builtins.readFile ./deploy/report.sh;
  };
in
{
  environment.systemPackages = [ deploy health ]; # dry runs: NIXOS_DEPLOY_DRY_RUN=1

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
      NIXOS_DEPLOY_PAUSE = "${stateDir}/paused /run/host-secrets/hermes/deploy-paused";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe deploy;
      StateDirectory = "nixos-deploy";
      StateDirectoryMode = "0755"; # report.md is read by hermes
      # The build has its own timeout (4h); never cut a switch short.
      TimeoutStartSec = "infinity";
    };
  };
  systemd.timers.nixos-deploy = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnActiveSec = "1min"; # also after the switch that starts it
      OnBootSec = "2min";
      OnUnitInactiveSec = "2min";
    };
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
