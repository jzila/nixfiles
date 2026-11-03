# Every kanban_list costs Hermes context, so the board is kept small: done
# tasks are archived after a week, and kanban_list hides priority < 0 unless
# asked (hermes-plugins/kanban-list).
{ config, pkgs, ... }:
let
  cfg = config.services.hermes-agent;
in
{
  systemd.services.hermes-kanban-archive = {
    description = "Archive Hermes's kanban tasks done for over a week";
    environment.HERMES_HOME = "${cfg.stateDir}/.hermes";
    path = [ cfg.package pkgs.jq pkgs.findutils ];
    script = ''
      set -o pipefail
      hermes kanban list --status done --json \
        | jq -r '.[] | select((.completed_at // now) < now - 7 * 86400) | .id' \
        | xargs -r hermes kanban archive
    '';
    serviceConfig = {
      Type = "oneshot";
      User = cfg.user;
      Group = cfg.group;
    };
    startAt = "daily";
  };
  systemd.timers.hermes-kanban-archive.timerConfig.Persistent = true;
}
