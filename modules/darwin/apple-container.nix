# nix-darwin module for Apple's container CLI.
#
# The container CLI binaries are code-signed with entitlements for
# Virtualization.framework and vmnet, so they must live at /usr/local/
# (outside the Nix store) to preserve their signatures.
#
# This module downloads the signed .pkg and installs it to /usr/local/
# via an activation script. The system service is started automatically
# after installation.
#
# Usage in your darwin configuration:
#   imports = [ ./modules/darwin/apple-container.nix ];
#   services.apple-container.enable = true;
#
# Requires macOS 26 (Tahoe) and Apple silicon.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.apple-container;
in {
  options.services.apple-container = {
    enable = lib.mkEnableOption "Apple container CLI for running Linux containers as lightweight VMs";

    version = lib.mkOption {
      type = lib.types.str;
      default = "0.10.0";
      description = "Version of the container CLI to install.";
    };

    hash = lib.mkOption {
      type = lib.types.str;
      default = "sha256-xIHONVUk0DbDzdrH/SgeMXlNQGkL+aIfcy7z12+p/gg=";
      description = "SRI hash of the installer .pkg. Update when changing version.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Install the signed .pkg to /usr/local/ and start the system service.
    # Uses xar + pax (same method as upstream `make install`).
    system.activationScripts.postActivation.text = let
      src = pkgs.fetchurl {
        url = "https://github.com/apple/container/releases/download/${cfg.version}/container-${cfg.version}-installer-signed.pkg";
        hash = cfg.hash;
      };
    in ''
      echo "Checking Apple container CLI..."
      needs_install=true
      if [ -x /usr/local/bin/container ]; then
        if /usr/local/bin/container system version 2>/dev/null | grep -q "${cfg.version}"; then
          needs_install=false
        fi
      fi
      if [ "$needs_install" = true ]; then
        echo "Installing Apple container CLI ${cfg.version}..."
        /usr/local/bin/container system stop 2>/dev/null || true
        temp_dir=$(mktemp -d)
        ${pkgs.xar}/bin/xar -xf ${src} -C "$temp_dir"
        (cd /usr/local && pax -rz -f "$temp_dir"/Payload)
        rm -rf "$temp_dir"
        echo "Apple container CLI ${cfg.version} installed."
        echo "Run 'container system start' to start the system service."
      else
        echo "Apple container CLI ${cfg.version} already installed."
      fi
    '';
  };
}
