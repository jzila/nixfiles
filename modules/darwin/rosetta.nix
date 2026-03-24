# nix-darwin module to declaratively install Rosetta 2.
#
# Rosetta 2 enables running x86_64 binaries and Linux containers
# on Apple silicon Macs.
#
# Usage:
#   imports = [ ./modules/darwin/rosetta.nix ];
#   system.rosetta.enable = true;
{ config, lib, ... }:

let
  cfg = config.system.rosetta;
in {
  options.system.rosetta = {
    enable = lib.mkEnableOption "Rosetta 2 for x86_64 binary translation on Apple silicon";
  };

  config = lib.mkIf cfg.enable {
    system.activationScripts.postActivation.text = ''
      if ! /usr/bin/pgrep -q oahd 2>/dev/null; then
        echo "Installing Rosetta 2..."
        /usr/sbin/softwareupdate --install-rosetta --agree-to-license
      fi
    '';
  };
}
