{
  description = "Per-device NixOS flake that consumes nixfiles.lib.mkSystem";

  inputs = {
    # The installer copies the public nixfiles into ./nixfiles for pure evaluation
    nixfiles.url = "path:./nixfiles";
  };

  outputs = { self, nixfiles, ... }:
    let
      # Host name is read from ./host.nix written by the installer
      host = import ./host.nix;
    in {
      nixosConfigurations."${host}" = nixfiles.lib.mkSystem {
        hostPath = nixfiles + "/hosts/${host}/configuration.nix";
        extraModules = [ ./hardware-configuration.nix nixfiles.lib.homeManagerModule ];
      };
    };
}
