# The hermes VM on the TrueNAS box, next to Home Assistant's. It hosts three
# NixOS containers: hermes (Hermes Agent's gateway, signal-cli, nginx; the
# same modules/hermes-container.nix as on argo, inner system
# modules/hermes-service.nix), and ha and ha-pr (the Home Assistant runners,
# modules/ha-gitops.nix). The VM itself keeps the credentials
# (modules/hermes-credentials.nix), Tailscale and its own deploy. TrueNAS
# defines the VM (CPUs, memory, the zvol, the NIC); this is the system on its
# disk. First booted from packages.x86_64-linux.hermes-image, then it deploys
# main to itself (./deploy.nix). Setup, cut-over and rollback: ./README.md.
#
#   - Network: a plain LAN guest (DHCP by default; keep its address fixed with
#     a reservation, argo's firewall and Home Assistant use it). IPv4 only on
#     the LAN. Tailscale as its own node (tag:hermes) for the PR events.
#   - Inbound: ssh to the VM (keys below). The mutual-TLS webhook (8645, from
#     Home Assistant's address only) and the PR events (8646, from the tailnet
#     only) are DNATed into the hermes container, as on argo.
#   - Hermes's egress is the container's (hermes-container.nix): argo's
#     ollama (allowedLanTargets), DNS to Pi-hole and the router, the internet;
#     nothing else on private or local ranges, nothing on the VM itself.
#   - Nix: only root and the runners may use the daemon; the hermes container
#     doesn't even see its socket. Hermes doesn't build; CI checks its PRs.
#   - Secrets, provisioned out of band, never in this repo, root-only:
#     /etc/hermes (gateway.env, github-app.pem: the VM's own key for the
#     zila-hermes app; bound read-only into the container, as on argo, where
#     only root can traverse it), /etc/hermes-tls (the webhook certificate
#     from the step CA, root plus nginx), /etc/tailscale/authkey (the VM's
#     only), /etc/ha-tofu/ha and /etc/ha-tofu/ha-pr (the runners'). Each
#     service waits for its secret.
{ config, lib, pkgs, modulesPath, ... }:
let
  cfg = config.hermesVm;
  tailscaleKey = "/etc/tailscale/authkey";
in
{
  imports = [
    # UEFI disk image (system.build.image) with the matching file systems:
    # ext4 root labelled nixos that grows with its partition, ESP, systemd-boot.
    "${modulesPath}/virtualisation/disk-image.nix"
    "${modulesPath}/profiles/qemu-guest.nix"
    ../../modules/hermes-container.nix
    ../../modules/ha-gitops.nix
    ./deploy.nix
  ];

  options.hermesVm = {
    address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "192.168.1.50/24";
      description = "Static LAN address (CIDR); null for DHCP.";
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.1";
      description = "The LAN's router, with a static address.";
    };
    ollamaAddress = lib.mkOption {
      type = lib.types.str;
      # argo's wired address, held by a DHCP reservation (hosts/argo/).
      default = "192.168.1.237";
      description = "argo's LAN address, where ollama listens.";
    };
    homeAssistantAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.153";
      description = "The only address forwarded to the mutual-TLS webhook port.";
    };
    resolvers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "192.168.1.135" "192.168.1.1" ];
      description = "DNS servers Hermes may query (Pi-hole, the router).";
    };
  };

  config = {
    networking.hostName = "hermes";
    system.stateVersion = "26.05";
    # Cron jobs and report times (the container follows the VM's zone).
    time.timeZone = "America/Chicago";

    # ── Boot ──────────────────────────────────────────────────────────────
    # TrueNAS's VM disk may be VirtIO or AHCI.
    boot.initrd.availableKernelModules = [ "ahci" "sd_mod" ];
    # TrueNAS's display and serial consoles.
    boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];
    boot.loader.systemd-boot.configurationLimit = 20;
    # OVMF's NVRAM may not persist: rely on the removable-media path
    # (EFI/BOOT/BOOTX64.EFI), which bootctl also installs.
    boot.loader.efi.canTouchEfiVariables = false;
    # The ESP (systemd-boot's random seed) is root's.
    fileSystems."/boot".options = [ "fmask=0077" "dmask=0077" ];
    services.qemuGuest.enable = true;

    # ── Network ───────────────────────────────────────────────────────────
    networking.useDHCP = false;
    networking.useNetworkd = true;
    systemd.network.networks."10-lan" = {
      matchConfig.Name = "en*";
      DHCP = if cfg.address == null then "ipv4" else "no";
      address = lib.optional (cfg.address != null) cfg.address;
      routes = lib.optional (cfg.address != null) { Gateway = cfg.gateway; };
      dhcpV4Config.UseDNS = false;
      networkConfig = {
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
      };
    };

    # Its own tailnet node, for the PR events (.github/workflows/pr-events.yml
    # posts to it at cut-over). The auth key is pre-authorised for tag:hermes.
    services.tailscale = {
      enable = true;
      openFirewall = true;
      authKeyFile = tailscaleKey;
      extraUpFlags = [
        "--hostname=hermes"
        "--advertise-tags=tag:hermes"
        # DNS stays on the LAN resolvers.
        "--accept-dns=false"
      ];
    };
    systemd.services.tailscaled-autoconnect.unitConfig.ConditionPathExists = tailscaleKey;

    networking.nameservers = cfg.resolvers;
    # Only ssh on the VM itself; the webhook ports are forwarded into the
    # container (hermes-container.nix's hermes-ingress), not served here.
    networking.firewall.allowedTCPPorts = lib.mkForce [ 22 ];

    # ── Hermes, in its container ──────────────────────────────────────────
    services.hermesContainer = {
      enable = true;
      # Its own range (argo's container is 10.233.1.x; ha and ha-pr are
      # 10.233.3.x and 10.233.4.x).
      hostAddress = "10.233.2.1";
      localAddress = "10.233.2.2";
      # Nothing on the VM itself; argo's ollama over the LAN instead.
      hostPorts = [ ];
      ollamaHost = cfg.ollamaAddress;
      allowedLanTargets = [ { address = cfg.ollamaAddress; port = 11434; } ];
      inherit (cfg) resolvers homeAssistantAddress;
      stateUsers = [ ];
      hideNixDaemon = true;
    };
    systemd.services.hermes-github-token.unitConfig.ConditionPathExists =
      "/etc/hermes/github-app.pem";
    # nginx in the container waits for the certificate (hermes-service.nix):
    # start it once the first one is in place. (Stays active, so the path
    # unit doesn't fire again; renewals reload nginx themselves.)
    systemd.paths.hermes-tls-first = {
      wantedBy = [ "paths.target" ];
      pathConfig.PathExists = "/etc/hermes-tls/server.crt";
    };
    systemd.services.hermes-tls-first = {
      description = "Start nginx in the hermes container once it has a certificate";
      after = [ "container@hermes.service" ];
      requires = [ "container@hermes.service" ];
      path = [ pkgs.nixos-container ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = "nixos-container run hermes -- systemctl reload-or-restart nginx";
    };

    # The Home Assistant runners, each in its own container; they start only
    # once their credentials are in /etc/ha-tofu (README.md, cut-over).
    services.haGitops = {
      enable = true;
      containers = true;
    };

    # ── Administration ────────────────────────────────────────────────────
    # root over ssh with John's YubiKey (FIDO2, touch per login); more keys
    # can go in /root/.ssh/authorized_keys.
    services.openssh = {
      enable = true;
      openFirewall = false; # allowedTCPPorts above
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };
    users.users.root.openssh.authorizedKeys.keys = [
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIBA0wZGn/jKiln2v9+qR0OJt0YfwoqTw7Abf6nnT7MXiAAAAC3NzaDp2ZW5hdG9y"
    ];
    environment.systemPackages = [ pkgs.step-cli ];

    # ── Nix ───────────────────────────────────────────────────────────────
    # The VM builds its own updates (./deploy.nix) on its own disk. Only root
    # (the deploy) and the runners (`nix develop` in their jobs, through the
    # socket nspawn binds into their containers) may use the daemon: not the
    # hermes user, not the hermes container (whose socket is covered anyway).
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      allowed-users = [ "root" "ha-tofu" "ha-pr" ];
      trusted-users = [ "root" ];
    };
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };
}
