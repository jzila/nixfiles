# modules/darwin/power.nix
#
# Declarative macOS power management via `pmset`.
# All knobs live in the `cfg` block below — edit values there and rebuild.
#
# Profiles:  battery (-b) | ac (-c) | global (-a, both sources)
# Units:     minutes, except booleans noted inline. 0 = "never".
#
# Why pmset instead of nix-darwin's `power.sleep.*`?
#   `power.sleep.*` is backed by `systemsetup`, which is global and cannot
#   distinguish battery from power adapter. We need per-source control plus
#   standby/autopoweroff/disablesleep, so we drive `pmset` directly.
{ lib, ... }:

let
  cfg = {
    # ---- On battery (-b) ------------------------------------------
    # Goal: keep processes running, but let the display turn off and the
    # lock screen engage. Deep power-saving modes are disabled so the
    # machine does not doze off after extended idle.
    battery = {
      sleep        = 0;   # system sleep: 0 = never (processes keep running)
      displaysleep = 5;   # display off after N min (lock screen fires here)
      disksleep    = 10;  # spin down disk after N min
      standby      = 0;   # deep standby: 0 = off (don't doze after long idle)
      autopoweroff = 0;   # hibernate-to-disk: 0 = off
      powernap     = 0;   # background wakeups (mail/backups): 0 = off
    };

    # ---- On power adapter (-c) ------------------------------------
    # ac.sleep = 0 is what the macOS UI shows as
    # "Prevent automatic sleeping on power adapter when the display is off" = ON.
    ac = {
      sleep        = 0;
      displaysleep = 10;
      disksleep    = 10;
      standby      = 1;
      autopoweroff = 1;
      powernap     = 1;
    };

    # ---- Both power sources (-a) ----------------------------------
    global = {
      disablesleep = 0;   # 0 = lid close ALWAYS sleeps (clamshell sleep on).
                          # NEVER set to 1 — that disables lid-close sleep too.
    };
  };

  render = flag: attrs:
    lib.concatStringsSep "\n"
      (lib.mapAttrsToList (k: v: "/usr/bin/pmset ${flag} ${k} ${toString v}") attrs);
in
{
  system.activationScripts.postActivation.text = ''
    echo "[power] applying pmset profiles..." >&2
    ${render "-b" cfg.battery}
    ${render "-c" cfg.ac}
    ${render "-a" cfg.global}
  '';
}
