# GitHub Actions runners for jzila/home-assistant, which declares Home Assistant
# with OpenTofu. Two runners, each in its own container
# (modules/runner-containers.nix), as two users:
#
#   ha     holds the Home Assistant credentials (admin token, the SSH key the
#          add-on forces through /data/gate.sh) and writes the state. Its
#          job-started hook refuses any job whose workflow or ref isn't main.
#   ha-pr  plans pull requests against the state; no credentials, and it can
#          only read the state.
#
# Secrets, root-only in /etc/ha-tofu/<runner>, bound into that runner's
# container alone as /etc/ha-tofu, reach its jobs as systemd credentials:
#   token             HA long-lived token of the "OpenTofu" user   (ha)
#   ssh-apply         SSH key, restricted to the gate's apply role (ha)
#   state-passphrase  OpenTofu state encryption                    (both)
#   runner-token      one-hour registration token, consumed at first start
#
# Neither Hermes's user nor the other runner can reach a runner's
# credentials. Both reach Home Assistant (HTTPS and the add-on's SSH). The
# state (/var/lib/ha-tofu) is bound in read-write for ha, read-only for ha-pr.
# A container starts only once its directory in /etc/ha-tofu exists
# (hosts/hermes/README.md).
#
# Approval is enforced by the repo's main ruleset at merge time (PR required,
# John's review as code owner, only John bypasses), so the runner applies
# whatever reaches main.
#
# The nightly drift check writes its verdict to /var/lib/ha-tofu/drift/report.md;
# drift is filed on the hass kanban board, and a clean night completes it.
{ config, lib, pkgs, hermes-agent, ... }:
let
  cfg = config.services.haGitops;
  repo = "jzila/home-assistant";
  stateDir = "/var/lib/ha-tofu";
  secretsDir = "/etc/ha-tofu";
  hermesHome = "/var/lib/hermes/.hermes";
  homeAssistantAddress = "192.168.1.153";
  # Fixed, so ownership of the bound state lines up inside the containers.
  haTofuId = 880;
  haPrId = 881;
  # Inside each runner's container.
  resolvers = [ "192.168.1.135" "192.168.1.1" ];

  # Host key of Home Assistant's SSH add-on (Terminal & SSH).
  knownHosts = pkgs.writeText "ha-known-hosts" ''
    homeassistant.local.zila.dev ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ8Eo+WQmet7vufMnTB9MlyQGjtZbv7fKhUqwLlZs7rf
  '';

  events = {
    ha = [ "push" "pull_request_target" "schedule" "workflow_dispatch" ];
    ha-pr = [ "pull_request_target" ];
  };

  # Reconciles the drift report with the hass board, like ha-maintenance.py: one
  # open "HA drift:" task by ha-drift, its body refreshed when the drift changes,
  # completed when a check comes back clean. The report's first line is the
  # verdict (tools/ci/drift.sh in the HA repo); a failed check doesn't rewrite
  # it, and anything else is refused.
  driftReport = pkgs.writeShellApplication {
    name = "ha-drift-report";
    runtimeInputs = [ hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default pkgs.jq ];
    text = ''
      report=$1
      title="HA drift: Home Assistant differs from main"
      verdict=$(head -n 1 "$report")
      open=$(hermes kanban list --tenant hass --json | jq -c '[.[]
        | select(.created_by == "ha-drift" and (.title | startswith("HA drift:")))
        | select(.status != "done" and .status != "archived")]')

      if [[ $verdict =~ ^Drift\ found\ .+\ at\ main\ [0-9a-f]+\.$ ]]; then
        task=$(jq -c 'max_by(.created_at) // empty' <<<"$open")
        if [ -z "$task" ]; then
          # No --idempotency-key: it would also match the completed task of an
          # earlier episode and never open a new one.
          hermes kanban create --tenant hass --created-by ha-drift --body-file "$report" "$title"
        elif [ "$(jq -r .body <<<"$task" | tail -n +2)" != "$(tail -n +2 "$report")" ]; then
          hermes kanban edit "$(jq -r .id <<<"$task")" --body "$(cat "$report")"
        fi
      elif [[ $verdict =~ ^No\ drift\ ([0-9-]+)T[^\ ]+\ at\ main\ ([0-9a-f]+)\.$ ]]; then
        result="Nightly drift check on ''${BASH_REMATCH[1]} found no drift (main ''${BASH_REMATCH[2]})."
        for id in $(jq -r '.[].id' <<<"$open"); do
          hermes kanban complete "$id" --result "$result"
        done
      else
        echo "ha-drift-report: unrecognised verdict: $verdict" >&2
        exit 1
      fi
    '';
  };

  environment = {
    HOMEASSISTANT_URL = "https://homeassistant.local.zila.dev";
    HA_STATE_DIR = stateDir;
    HA_KNOWN_HOSTS = "${knownHosts}";
  };

  # What each runner's jobs get.
  jobs = {
    ha = {
      user = "ha-tofu";
      uid = haTofuId;
      net = "3";
      serviceOverrides = {
        LoadCredential = [
          "ha-token:${secretsDir}/token"
          "ssh-key:${secretsDir}/ssh-apply"
          "state-passphrase:${secretsDir}/state-passphrase"
        ];
        ReadWritePaths = [ stateDir ];
        UMask = "0027"; # state readable by ha-pr
      };
    };
    ha-pr = {
      user = "ha-pr";
      uid = haPrId;
      net = "4";
      serviceOverrides = {
        LoadCredential = [ "state-passphrase:${secretsDir}/state-passphrase" ];
        ReadOnlyPaths = [ stateDir ];
      };
    };
  };
  # Each in its own container, with its credentials (/etc/ha-tofu/<runner> as
  # /etc/ha-tofu) and the state.
  containerRunner = name: {
    inherit repo resolvers;
    events = events.${name};
    inherit (jobs.${name}) user uid;
    group = "ha-tofu";
    gid = haTofuId;
    hostAddress = "10.233.${jobs.${name}.net}.1";
    localAddress = "10.233.${jobs.${name}.net}.2";
    secrets = {
      hostPath = "${secretsDir}/${name}";
      path = secretsDir;
    };
    bindMounts.${stateDir} = {
      hostPath = stateDir;
      isReadOnly = name != "ha";
    };
    allow = [ "ip daddr ${homeAssistantAddress} tcp dport { 22, 443 }" ];
    runner = {
      extraPackages = with pkgs; [ openssh gh curl util-linux ];
      extraEnvironment = environment;
      inherit (jobs.${name}) serviceOverrides;
    };
  };
in
{
  imports = [ ./runner-containers.nix ];

  options.services.haGitops = {
    enable = lib.mkEnableOption "the GitHub Actions runners for jzila/home-assistant, each in its own container";
  };

  config = lib.mkIf cfg.enable {
  users.groups.ha-tofu.gid = haTofuId;
  users.users.ha-tofu = {
    isSystemUser = true;
    group = "ha-tofu";
    uid = haTofuId;
    description = "Home Assistant GitHub runner (apply)";
  };
  users.users.ha-pr = {
    isSystemUser = true;
    group = "ha-tofu"; # reads the state
    uid = haPrId;
    description = "Home Assistant GitHub runner (PR plans)";
  };

  systemd.tmpfiles.rules = [
    "d ${secretsDir} 0700 root root -"
    "d ${stateDir} 2750 ha-tofu ha-tofu -"
    "f ${stateDir}/.lock 0640 ha-tofu ha-tofu -"
    "d ${stateDir}/drift 2750 ha-tofu ha-tofu -"
  ];

  # Drift: reconcile each new report with the hass board.
  systemd.paths.ha-drift-report = {
    wantedBy = [ "paths.target" ];
    pathConfig.PathChanged = "${stateDir}/drift/report.md";
  };
  systemd.services.ha-drift-report = {
    description = "Reconcile Home Assistant drift with the hass kanban board";
    unitConfig.ConditionPathExists = "${stateDir}/drift/report.md";
    environment.HERMES_HOME = hermesHome;
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      SupplementaryGroups = [ "ha-tofu" ];
      ExecStart = "${lib.getExe driftReport} ${stateDir}/drift/report.md";
    };
  };

  services.runnerContainers = lib.genAttrs [ "ha" "ha-pr" ] containerRunner;
  };
}
