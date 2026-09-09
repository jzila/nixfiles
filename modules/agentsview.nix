# Run `agentsview serve` as an always-on user service instead of a terminal
# tab you have to remember to leave open.
#
# Port: 8420, not 8080. 8080 is agentsview's own default and the
# conventional "behind a reverse proxy" port, and it's what a manually
# started `agentsview serve` on this machine already uses (see the
# coexistence note in the PR that introduced this module).
#
# Foreground `serve`, not `daemon start` / `--background`: the supervisor
# (launchd on darwin, systemd on linux) should own the process's lifecycle
# directly, not babysit a self-detaching child. This also sidesteps
# agentsview's idle-timeout self-exit: that timeout only arms when the
# process was launched via `serve --background` (it checks an
# AGENTSVIEW_BACKGROUND_CHILD env var set by that launcher — see
# cmd/agentsview/main.go's newDaemonIdleTracker and serve_background.go's
# runningAsBackgroundChild in the agentsview source). A plain foreground
# `serve` never sets that variable, so it never idles itself out; the only
# way this service stops on its own is a crash, which KeepAlive/Restart then
# catches.
{ config, lib, isLinux, isDarwin, ... }:

with lib;

let
  cfg = config.services.agentsview;

  logDir = "${config.home.homeDirectory}/Library/Logs/agentsview";

  # agentsview shells out to git (and possibly other tools) while parsing
  # session transcripts, and a bare launchd/systemd PATH would hide those
  # from it. opencode-bin's wrapProgram documents the same concern for
  # opencode; there's no wrapper to attach it to here, so the PATH has to
  # come from the service/agent environment instead.
  pathEnv = concatStringsSep ":" ([
    "${config.home.profileDirectory}/bin"
    "/run/current-system/sw/bin"
  ] ++ optionals isDarwin [
    "/opt/homebrew/bin"
    "/usr/bin"
    "/bin"
  ] ++ optionals isLinux [
    "/usr/bin"
    "/bin"
  ]);

  args = [
    "serve"
    "--no-browser"
    "--host"
    cfg.host
    "--port"
    (toString cfg.port)
  ]
  ++ optional (!cfg.updateCheck) "--no-update-check"
  ++ cfg.extraArgs;
in
{
  options.services.agentsview = {
    enable = mkEnableOption "agentsview as an always-on user service (launchd on darwin, systemd on linux)";

    package = mkOption {
      type = types.package;
      description = "The agentsview package to run.";
    };

    port = mkOption {
      type = types.port;
      default = 8420;
      description = ''
        Port `agentsview serve` listens on. Deliberately not 8080 (see the
        module header comment).
      '';
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Host/address `agentsview serve` binds to.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra arguments appended to `agentsview serve`.";
    };

    updateCheck = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether agentsview should check for its own updates. Nix manages the
        binary here, so this defaults to false, which passes
        `--no-update-check` on the command line.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf isDarwin {
      launchd.agents.agentsview = {
        enable = true;
        config = {
          ProgramArguments = [ "${cfg.package}/bin/agentsview" ] ++ args;
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "${logDir}/stdout.log";
          StandardErrorPath = "${logDir}/stderr.log";
          EnvironmentVariables = {
            PATH = pathEnv;
          };
        };
      };

      # launchd expects StandardOutPath/StandardErrorPath's parent directory
      # to already exist; it will not create it.
      home.activation.agentsviewLogDir = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
        mkdir -p "${logDir}"
      '';
    })

    (mkIf isLinux {
      systemd.user.services.agentsview = {
        Unit = {
          Description = "agentsview session-search and analytics server";
        };
        Service = {
          ExecStart = concatStringsSep " " ([ "${cfg.package}/bin/agentsview" ] ++ args);
          Restart = "on-failure";
          RestartSec = 5;
          Environment = "PATH=${pathEnv}";
        };
        Install = {
          WantedBy = [ "default.target" ];
        };
      };
    })
  ]);
}
