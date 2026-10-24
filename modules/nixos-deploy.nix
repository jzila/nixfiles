# Deploys jzila/nixfiles main to argo. A root timer, every 2 minutes:
#
#   1. reads main's head with `git ls-remote` (public repo, no credentials)
#      and stops if that commit is deployed, or failed and main hasn't moved;
#   2. waits until GitHub Actions' "Build NixOS (argo)" check on that exact
#      commit has succeeded (public API, unauthenticated; any API error or
#      rate limit just means "next round");
#   3. refuses a commit that isn't a descendant of the deployed one;
#   4. builds github.com/jzila/nixfiles at that rev (never a branch, never the
#      local checkout), and if it's the running system, records it and stops;
#   5. switches, then checks health for up to 5 minutes: the units below
#      active, no unit failed that wasn't failed before, github.com reachable.
#      Unhealthy, or a broken activation: it switches back to the system it
#      replaced and records the commit as failed.
#
# Nothing on GitHub can reach argo: no runner, no webhook, no token. To get code
# here, an attacker needs a commit on main, which the ruleset only allows
# through a PR with John's approval (Hermes can open PRs, not merge them), and
# then a green build of it. Only John bypasses, as for ha-gitops.
#
# History only moves forward: main must be ahead of the deployed commit. A
# revert is a new descendant and deploys normally; a force-push (blocked by the
# ruleset) or an admin reset of main is refused and filed until John removes
# /var/lib/nixos-deploy/deployed.
#
# Kill switch: `sudo touch /etc/nixos-deploy/paused` (remove to resume). A
# manual `nixos-rebuild switch` is fine meanwhile, but without the pause the
# next commit on main replaces it.
#
# State is in /var/lib/nixos-deploy (deployed, attempt, report.md). Logs:
#   journalctl -u nixos-deploy -u nixos-deploy-switch -u nixos-deploy-rollback
# Failures are filed on the kanban board (untenanted, "argo deploy:") by
# nixos-deploy-report, as hermes; the next deploy completes them.
{ config, lib, pkgs, hermes-agent, ... }:
let
  stateDir = "/var/lib/nixos-deploy";
  hermesHome = "/var/lib/hermes/.hermes";

  # Must be active after a switch, if the new system still has them.
  healthUnits = [
    "container@hermes.service"
    "ollama.service"
    "github-runner-ha.service"
    "github-runner-ha-pr.service"
    "tailscaled.service"
    "NetworkManager.service"
    "nix-daemon.service"
  ];

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
    text = builtins.readFile ./nixos-deploy/deploy.sh;
  };

  report = pkgs.writeShellApplication {
    name = "nixos-deploy-report";
    runtimeInputs = [ hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default pkgs.jq ];
    text = builtins.readFile ./nixos-deploy/report.sh;
  };
in
{
  environment.systemPackages = [ deploy ]; # for dry runs: NIXOS_DEPLOY_DRY_RUN=1
  systemd.tmpfiles.rules = [ "d /etc/nixos-deploy 0755 root root -" ]; # the kill switch's home

  systemd.services.nixos-deploy = {
    description = "Deploy jzila/nixfiles main to this host";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # The running deploy is the one switching: a switch must neither stop nor
    # restart it. (It switches through systemd-run, so even a commit that drops
    # this module only ends the deploy after the switch.)
    restartIfChanged = false;
    environment.NIXOS_DEPLOY_UNITS = lib.concatStringsSep " " healthUnits;
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
      OnBootSec = "5min";
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
