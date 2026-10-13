# Google Drive on the Linux hosts via rclone, as Home Manager user services.
# Imported only on Linux; on a Mac, use Google's Drive for desktop app.
#
# Two modes, chosen per host. Every Linux host gets the mount unless it runs
# bisync (argo, which keeps the NAS copy in sync instead):
#   mount   an on-demand FUSE mount of Drive (files fetched when opened and
#           cached locally); reads and writes go straight to Drive, but
#           anything not yet cached needs the network.
#   bisync  a two-way sync on a timer between Drive and `bisync.target`: a
#           local directory, such as an NFS mount of the NAS, or any rclone
#           path. With `bisync.watch`, writes to a local target also trigger
#           a sync within seconds.
#
# No credentials live in this repo. Each machine signs in once through the
# browser OAuth flow:
#
#   rclone config        # n) new remote, name "gdrive", type "drive", enter
#                        # your own client_id/client_secret (an "Internal"
#                        # OAuth app in the Workspace org), "y" to sign in
#                        # in the web browser
#
# rclone stores the resulting token in ~/.config/rclone/rclone.conf. That
# file is deliberately left out of Home Manager: rclone rewrites it whenever
# it refreshes the access token, which a read-only store symlink (or a file
# regenerated on every activation) would break. A bisync target on another
# rclone remote needs that remote in the same file, set up the same way.
#
# Until the Drive remote holds a token (and a remote target exists), the
# services below are skipped (ExecCondition) rather than failing, and a
# .path unit watching rclone.conf starts them once rclone writes it, so no
# manual `systemctl --user start` is needed after sign-in. The file existing
# isn't enough: `rclone config` writes the remote with an empty token before
# the browser flow finishes, then again once it has one. The .path unit
# fires on both writes; the first is skipped, the second starts. (rclone
# also rewrites the file on token refresh, which re-triggers them; that's a
# no-op for a running mount and just an extra sync for bisync.)
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.gdrive;
  home = config.home.homeDirectory;
  rcloneConf = "${home}/.config/rclone/rclone.conf";
  rclone = "${cfg.package}/bin/rclone";
  remote = "${cfg.remote}:";

  # The rclone remote a bisync target lives on, if it isn't a local path
  # ("truenas:zila-family/drive" -> "truenas"; "/home/..." -> null).
  targetRemote =
    let m = builtins.match "([^/:]+):.*" cfg.bisync.target;
    in if m == null then null else head m;

  # ExecCondition: exit 1 skips the unit (as an unmet Condition*= would)
  # until the Drive remote has a non-empty token and, for bisync, the
  # target's remote exists.
  signedIn = withTarget: pkgs.writeShellScript "gdrive-signed-in" (''
    conf=$(${rclone} config dump 2>/dev/null)
    ${pkgs.jq}/bin/jq -e --arg r ${escapeShellArg cfg.remote} '(.[$r].token // "") != ""' <<< "$conf" > /dev/null \
      || { echo "rclone remote ${cfg.remote} has no token yet; run \`rclone config\` to sign in"; exit 1; }
  '' + optionalString (withTarget && targetRemote != null) ''
    ${pkgs.jq}/bin/jq -e --arg r ${escapeShellArg targetRemote} 'has($r)' <<< "$conf" > /dev/null \
      || { echo "rclone remote ${targetRemote} is not configured yet (see modules/gdrive.nix)"; exit 1; }
  '');

  bisyncWorkdir = "${config.xdg.stateHome}/rclone-bisync";

  bisyncArgs = [
    "${remote}${cfg.bisync.remotePath}"
    cfg.bisync.target
    "--workdir" bisyncWorkdir
    # Self-heal after interrupted runs instead of demanding a manual --resync.
    "--resilient"
    "--recover"
    "--max-lock" "2m"
    "--conflict-resolve" "newer"
    "--create-empty-src-dirs"
    # Native Docs/Sheets/Slides have no real file content; exporting them
    # into a two-way sync just produces copies that can't be written back.
    "--drive-skip-gdocs"
  ] ++ cfg.bisync.extraArgs;

  # Watch a local bisync target and run a sync shortly after writes to it,
  # instead of waiting for the timer. inotify only reports changes made
  # through this machine's kernel: on an NFS mount that's this host's own
  # writes, not other clients'; on the file server itself it's every write.
  # bisync's own writes trigger one extra run afterwards, which finds
  # nothing to do and ends the cycle.
  watchScript = pkgs.writeShellScript "gdrive-watch" ''
    set -u
    ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg cfg.bisync.target}
    ${pkgs.inotify-tools}/bin/inotifywait -m -r -q \
      -e close_write -e create -e delete -e move \
      --format x ${escapeShellArg cfg.bisync.target} |
    while read -r _; do
      # Debounce: wait for ${toString cfg.bisync.watch.quietSeconds}s without events, so a burst of writes is one sync.
      while read -r -t ${toString cfg.bisync.watch.quietSeconds} _; do :; done
      ${pkgs.systemd}/bin/systemctl --user start gdrive-bisync.service || true
    done
    # inotifywait exited (e.g. the mount went away); let systemd restart us.
    exit 1
  '';

  # bisync refuses to run without prior state; the very first run (or one
  # after the workdir is wiped) has to be a --resync, which merges both sides
  # without deleting anything. Both sides must exist first; `rclone mkdir`
  # handles a local target and a remote one alike.
  bisyncScript = pkgs.writeShellScript "gdrive-bisync" ''
    set -eu
    ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg bisyncWorkdir}
    ${rclone} mkdir ${escapeShellArg cfg.bisync.target}
    resync=()
    # (Not compgen: the non-interactive bash scripts run under lacks it.)
    if [ -z "$(${pkgs.findutils}/bin/find ${escapeShellArg bisyncWorkdir} -maxdepth 1 -name '*.lst' -print -quit)" ]; then
      echo "no bisync state yet; running initial --resync"
      resync=(--resync)
    fi
    exec ${rclone} bisync ${escapeShellArgs bisyncArgs} "''${resync[@]}"
  '';
in
{
  options.services.gdrive = {
    package = mkOption {
      type = types.package;
      default = pkgs.rclone;
      description = "The rclone package to use.";
    };

    remote = mkOption {
      type = types.str;
      default = "gdrive";
      description = "Name of the rclone remote created with `rclone config`.";
    };

    mount = {
      enable = mkOption {
        type = types.bool;
        # On by default on every Linux host that isn't the one keeping the
        # NAS in sync (argo): that host reaches Drive's files on the NAS.
        default = !cfg.bisync.enable;
        defaultText = literalExpression "!config.services.gdrive.bisync.enable";
        description = "Whether to keep an on-demand rclone FUSE mount of Google Drive.";
      };

      path = mkOption {
        type = types.str;
        default = "${home}/GoogleDrive";
        description = "Where to mount Google Drive.";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra arguments appended to `rclone mount`.";
      };
    };

    bisync = {
      enable = mkEnableOption "periodic two-way rclone bisync of Google Drive with a local directory or another rclone remote";

      remotePath = mkOption {
        type = types.str;
        default = "";
        example = "Documents";
        description = "Folder within Drive to sync; empty syncs all of My Drive.";
      };

      target = mkOption {
        type = types.str;
        default = "${home}/GoogleDrive";
        example = "truenas:zila-family/drive";
        description = ''
          What Drive is kept in sync with: a local directory, or an rclone
          path (`remote:path`) on a remote configured in rclone.conf.
        '';
      };

      interval = mkOption {
        type = types.str;
        default = "10min";
        description = "How often to sync (systemd time span).";
      };

      timeout = mkOption {
        type = types.str;
        default = "2h";
        description = ''
          Longest a single sync may run before systemd kills it (systemd
          time span). It only has to beat a hung run, e.g. on a hard NFS
          mount whose server went away, which would otherwise block every
          later run: work already copied is kept and the next run (with
          --recover) picks up where it stopped. Normal runs take seconds; a
          full first sync of ~28 GiB took about 9 minutes.
        '';
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra arguments appended to `rclone bisync`.";
      };

      watch = {
        enable = mkEnableOption ''
          syncing shortly after writes to a local `target`, on top of the
          timer. On an NFS/SMB mount this only sees this host's own writes
        '';

        quietSeconds = mkOption {
          type = types.ints.positive;
          default = 15;
          description = "Seconds without further writes before a sync starts.";
        };
      };
    };
  };

  config = mkMerge [
    (mkIf (cfg.mount.enable || cfg.bisync.enable) {
      # For the one-time `rclone config` sign-in and ad-hoc use.
      home.packages = [ cfg.package ];

      assertions = [{
        assertion = !(cfg.mount.enable && cfg.bisync.enable && cfg.mount.path == cfg.bisync.target);
        message = "services.gdrive: mount.path and bisync.target must differ.";
      } {
        assertion = !(cfg.bisync.watch.enable && targetRemote != null);
        message = "services.gdrive: bisync.watch needs a local bisync.target (inotify can't see an rclone remote).";
      }];
    })

    (mkIf cfg.mount.enable {
      systemd.user.services.gdrive-mount = {
        Unit = {
          Description = "Google Drive rclone mount at ${cfg.mount.path}";
          ConditionPathExists = rcloneConf;
        };
        Service = {
          Type = "notify";
          ExecCondition = "${signedIn false}";
          ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${cfg.mount.path}";
          ExecStart = concatStringsSep " " ([
            rclone "mount" remote cfg.mount.path
            "--vfs-cache-mode" "full"
            "--vfs-cache-max-age" "72h"
            # Drive pushes change notifications (polled every minute by
            # default), so listings can be cached long without going stale.
            "--dir-cache-time" "1000h"
          ] ++ cfg.mount.extraArgs);
          ExecStop = "/run/wrappers/bin/fusermount3 -uz ${cfg.mount.path}";
          Restart = "on-failure";
          RestartSec = 30;
          # rclone execs fusermount3, which only exists as the setuid wrapper.
          Environment = "PATH=/run/wrappers/bin";
        };
        Install.WantedBy = [ "default.target" ];
      };

      systemd.user.paths.gdrive-mount = {
        Unit.Description = "Start the Google Drive mount once rclone is signed in";
        Path.PathChanged = rcloneConf;
        Install.WantedBy = [ "default.target" ];
      };
    })

    (mkIf cfg.bisync.enable {
      systemd.user.services.gdrive-bisync = {
        Unit = {
          Description = "Two-way sync of Google Drive with ${cfg.bisync.target}";
          ConditionPathExists = rcloneConf;
          # A rebuild would otherwise restart a sync in progress and block
          # activation until it finished; a first sync easily outlasts Home
          # Manager's activation timeout. The next run picks up the change.
          X-SwitchMethod = "keep-old";
        };
        Service = {
          Type = "oneshot";
          ExecCondition = "${signedIn true}";
          ExecStart = "${bisyncScript}";
          # oneshot services have no start timeout by default.
          TimeoutStartSec = cfg.bisync.timeout;
        };
      };

      systemd.user.timers.gdrive-bisync = {
        Unit.Description = "Periodic Google Drive bisync";
        Timer = {
          # Relative to the timer's own activation, which happens at login
          # and also when a rebuild first installs it. (OnStartupSec would
          # already be in the past for a timer added to a running session,
          # leaving nothing to fire until the next login.)
          OnActiveSec = "2min";
          # Counted from the service's last run. A run skipped before
          # sign-in doesn't count, so before sign-in this chain stalls; the
          # path unit below restarts it.
          OnUnitActiveSec = cfg.bisync.interval;
        };
        Install.WantedBy = [ "timers.target" ];
      };

      # PathChanged, not PathExists: with a oneshot service, PathExists
      # re-triggers every time the service exits, looping until systemd's
      # trigger limit trips.
      systemd.user.paths.gdrive-bisync = {
        Unit.Description = "Run a Google Drive bisync once rclone is signed in to both sides";
        Path.PathChanged = rcloneConf;
        Install.WantedBy = [ "default.target" ];
      };
    })

    (mkIf (cfg.bisync.enable && cfg.bisync.watch.enable) {
      systemd.user.services.gdrive-watch = {
        Unit.Description = "Sync Google Drive soon after writes to ${cfg.bisync.target}";
        Service = {
          ExecCondition = "${signedIn true}";
          ExecStart = "${watchScript}";
          Restart = "always";
          RestartSec = 30;
        };
        Install.WantedBy = [ "default.target" ];
      };
    })
  ];
}
