# macOS base configuration module (nix-darwin)
{ config, pkgs, pkgs-unstable, lib, ... }:

{
  imports = [ ../common/base.nix ];

  # Nix garbage collection (launchd syntax)
  nix.gc = {
    automatic = true;
    interval = { Weekday = 2; Hour = 3; Minute = 15; };
    options = "--delete-older-than 14d";
  };

  # macOS system defaults
  system.defaults = {
    dock = {
      autohide = false;
      show-recents = false;
    };
    finder = {
      AppleShowAllExtensions = true;
      FXPreferredViewStyle = "clmv";
    };
    NSGlobalDomain = {
      ApplePressAndHoldEnabled = false;
      InitialKeyRepeat = 15;
      KeyRepeat = 2;
    };
  };

  # Tailscale VPN
  services.tailscale.enable = true;

  # Security - touch ID for sudo (reattach enables it inside tmux)
  security.pam.services.sudo_local.touchIdAuth = true;
  security.pam.services.sudo_local.reattach = true;

  # macOS-specific system packages
  environment.systemPackages = with pkgs; [
    # macOS utilities
    coreutils
  ];
}
