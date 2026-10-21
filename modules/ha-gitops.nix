# GitHub Actions runners for jzila/home-assistant, which declares Home Assistant
# with OpenTofu. Two runners, as two users:
#
#   ha     holds the Home Assistant credentials (admin token, the SSH key the
#          add-on forces through /data/gate.sh) and writes the state. Its
#          job-started hook refuses any job whose workflow or ref isn't main.
#   ha-pr  plans pull requests against the state; no credentials, and it can
#          only read the state.
#
# Secrets, root-only in /etc/ha-tofu, reach the runners as systemd credentials:
#   token             HA long-lived token of the "OpenTofu" user   (ha)
#   ssh-apply         SSH key, restricted to the gate's apply role (ha)
#   state-passphrase  OpenTofu state encryption                    (both)
#   runner-token      one-hour registration token, consumed at first start
#
# Approval is enforced by the repo's main ruleset at merge time (PR required,
# John's review as code owner, only John bypasses), so the runner applies
# whatever reaches main.
#
# Drift found by the nightly workflow lands in /var/lib/ha-tofu/drift/report.md
# and is filed on the hass kanban board.
{ lib, pkgs, hermes-agent, ... }:
let
  repo = "jzila/home-assistant";
  stateDir = "/var/lib/ha-tofu";
  secretsDir = "/etc/ha-tofu";
  hermesHome = "/var/lib/hermes/.hermes";

  # Host key of Home Assistant's SSH add-on (Terminal & SSH).
  knownHosts = pkgs.writeText "ha-known-hosts" ''
    homeassistant.local.zila.dev ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ8Eo+WQmet7vufMnTB9MlyQGjtZbv7fKhUqwLlZs7rf
  '';

  # Job-started hook: a runner only runs main's workflows, against main, for the
  # given events. A failing hook fails the job before any step runs.
  guard =
    name: events:
    # The runner only accepts hooks ending in .sh, .ps1 or .js.
    pkgs.writeShellScript "${name}-guard.sh" ''
      fail() { echo "${name} runner: refusing this job: $*" >&2; exit 1; }
      [ "''${GITHUB_REPOSITORY:-}" = ${repo} ] || fail "repository ''${GITHUB_REPOSITORY:-?}"
      [ "''${GITHUB_REF:-}" = refs/heads/main ] || fail "ref ''${GITHUB_REF:-?} is not main"
      case "''${GITHUB_WORKFLOW_REF:-}" in
        ${repo}/.github/workflows/*@refs/heads/main) ;;
        *) fail "workflow ''${GITHUB_WORKFLOW_REF:-?} is not from main" ;;
      esac
      case "''${GITHUB_EVENT_NAME:-}" in
        ${lib.concatStringsSep "|" events}) ;;
        *) fail "event ''${GITHUB_EVENT_NAME:-?}" ;;
      esac
      echo "${name} runner: $GITHUB_WORKFLOW_REF, $GITHUB_EVENT_NAME"
    '';

  common = {
    enable = true;
    url = "https://github.com/${repo}";
    tokenFile = "${secretsDir}/runner-token";
    replace = true;
    extraPackages = with pkgs; [ openssh gh curl util-linux ];
  };
  environment = {
    HOMEASSISTANT_URL = "https://homeassistant.local.zila.dev";
    HA_STATE_DIR = stateDir;
    HA_KNOWN_HOSTS = "${knownHosts}";
  };
in
{
  users.groups.ha-tofu = { };
  users.users.ha-tofu = {
    isSystemUser = true;
    group = "ha-tofu";
    description = "Home Assistant GitHub runner (apply)";
  };
  users.users.ha-pr = {
    isSystemUser = true;
    group = "ha-tofu"; # reads the state
    description = "Home Assistant GitHub runner (PR plans)";
  };

  systemd.tmpfiles.rules = [
    "d ${secretsDir} 0700 root root -"
    "d ${stateDir} 2750 ha-tofu ha-tofu -"
    "f ${stateDir}/.lock 0640 ha-tofu ha-tofu -"
    "d ${stateDir}/drift 2750 ha-tofu ha-tofu -"
  ];

  services.github-runners.ha = common // {
    name = "argo-ha";
    extraLabels = [ "ha" ];
    user = "ha-tofu";
    group = "ha-tofu";
    extraEnvironment = environment // {
      ACTIONS_RUNNER_HOOK_JOB_STARTED = guard "ha" [
        "push"
        "pull_request_target"
        "schedule"
        "workflow_dispatch"
      ];
    };
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

  services.github-runners.ha-pr = common // {
    name = "argo-ha-pr";
    extraLabels = [ "ha-pr" ];
    user = "ha-pr";
    group = "ha-tofu";
    extraEnvironment = environment // {
      ACTIONS_RUNNER_HOOK_JOB_STARTED = guard "ha-pr" [ "pull_request_target" ];
    };
    serviceOverrides = {
      LoadCredential = [ "state-passphrase:${secretsDir}/state-passphrase" ];
      ReadOnlyPaths = [ stateDir ];
    };
  };

  # Drift: file the nightly report on the hass board. The idempotency key is the
  # report's content (without its timestamp line), so the same drift night after
  # night stays one task.
  systemd.paths.ha-drift-report = {
    wantedBy = [ "paths.target" ];
    pathConfig.PathChanged = "${stateDir}/drift/report.md";
  };
  systemd.services.ha-drift-report = {
    description = "File Home Assistant drift on the hass kanban board";
    unitConfig.ConditionPathExists = "${stateDir}/drift/report.md";
    environment.HERMES_HOME = hermesHome;
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      SupplementaryGroups = [ "ha-tofu" ];
    };
    script = ''
      report=${stateDir}/drift/report.md
      key=ha-drift-$(tail -n +2 "$report" | sha256sum | cut -c1-16)
      ${lib.getExe' hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default "hermes"} kanban create \
        --tenant hass --created-by ha-drift --idempotency-key "$key" \
        --body-file "$report" "HA drift: Home Assistant differs from main"
    '';
  };
}
