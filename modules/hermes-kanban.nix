# Every kanban_list costs Hermes context, so the board is kept small: done
# tasks are archived after a week, and kanban_list hides priority < 0 unless
# asked (hermes-patches/). Upstream builds its Python code with uv2nix and has
# no patch hook, so the patch goes in through the workspace overlay.
{ config, lib, pkgs, hermes-agent, ... }:
let
  cfg = config.services.hermes-agent;
in
{
  services.hermes-agent.package = hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.override (old: {
    uv2nix = lib.recursiveUpdate old.uv2nix {
      lib.workspace.loadWorkspace = args:
        let workspace = old.uv2nix.lib.workspace.loadWorkspace args;
        in workspace // {
          mkPyprojectOverlay = overlayArgs: final: prev:
            let set = workspace.mkPyprojectOverlay overlayArgs final prev;
            in set // lib.optionalAttrs (set ? hermes-agent) {
              hermes-agent = set.hermes-agent.overrideAttrs (o: {
                patches = (o.patches or [ ]) ++ [ ./hermes-patches/kanban-list-low-priority.patch ];
              });
            };
        };
    };
  });

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
