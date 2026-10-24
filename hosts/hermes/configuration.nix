# The hermes microVM: Hermes Agent's gateway and everything around it
# (modules/hermes-service.nix), run by argo (modules/hermes-vm/host.nix)
# inside the boundary of modules/hermes-vm/boundary.nix, and deployed from
# main by itself (./deploy.nix).
#
# This is the VM's own system: changing it through a reviewed PR changes the
# VM, never argo. What argo gives the VM (CPUs, memory, disks, the network
# link, the shares) is the boundary module's, and argo checks that this
# system mounts exactly that.
{ config, lib, pkgs, microvm, ... }:
let
  hostAddress = "10.233.2.1";
  address = "10.233.2.2";
in
{
  imports = [
    microvm.nixosModules.microvm
    ../../modules/hermes-vm/boundary.nix
    ../../modules/hermes-service.nix
    ./deploy.nix
  ];

  networking.hostName = "hermes";
  system.stateVersion = "26.05";
  # argo's zone (the container saw argo's /etc/localtime): cron jobs and
  # report times.
  time.timeZone = "America/Chicago";

  hermes.hostAddress = hostAddress;

  # Static on the tap; argo routes and NATs (modules/hermes-vm/host.nix).
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.networks."10-argo" = {
    matchConfig.MACAddress = (lib.head config.microvm.interfaces).mac;
    address = [ "${address}/24" ];
    routes = [ { Gateway = hostAddress; } ];
    networkConfig = {
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
    };
  };

  # Persistent /var/lib (boundary.nix) before anything writes to it, the
  # activation's user and group records included.
  fileSystems."/var/lib".neededForBoot = true;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    # Builds on the store's disk layer, not the tmpfs root.
    build-dir = "/nix/.rw-store/build";
  };
  systemd.tmpfiles.rules = [ "d /nix/.rw-store/build 0755 root root -" ];
  # The writable layer lasts until the VM stops; keep long uptimes in check.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # The webhook certificate is renewed on argo (hermes-tls-renew), which can't
  # reach into the VM: pick up a new one, or the first, within the hour.
  systemd.services.hermes-tls-reload = {
    description = "Reload nginx when argo renews the webhook certificate";
    unitConfig.ConditionPathExists = "/run/host-secrets/hermes-tls/server.crt";
    serviceConfig.Type = "oneshot";
    script = ''
      new=$(sha256sum /run/host-secrets/hermes-tls/server.crt)
      old=$(cat /run/hermes-tls-loaded 2>/dev/null || true)
      if [ "$new" != "$old" ] || ! systemctl is-active --quiet nginx; then
        systemctl reload-or-restart nginx
        echo "$new" >/run/hermes-tls-loaded
      fi
    '';
  };
  systemd.timers.hermes-tls-reload = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1h";
    };
  };

  # Root, from argo only: sshd over vsock (no TCP port is open), keys from
  # /etc/hermes/vm-admin-keys on argo.
  microvm.vsock.ssh.enable = true;
  services.openssh = {
    openFirewall = false;
    authorizedKeysFiles = [ "/run/host-secrets/hermes/admin_authorized_keys" ];
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
}
