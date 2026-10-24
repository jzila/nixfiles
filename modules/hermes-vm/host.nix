# Hermes in a microVM on argo (microvm.nix, cloud-hypervisor): the successor
# to modules/hermes-container.nix, which puts the boundary at a kernel instead
# of a container. The VM is its own NixOS system (hosts/hermes/), deployed
# from main by the VM itself; argo, John's desktop, stays manual and only sets
# what the VM boots on start.
#
# Off by default: services.hermesVm.enable declares the VM, its network and
# shares but leaves it stopped (`systemctl start microvm@hermes`, alongside
# the container, which stays the live Hermes); services.hermesVm.cutover
# starts it at boot and moves the webhook ingress to it, and requires
# services.hermesContainer.enable = false.
#
#   - Boundary: what runs on argo for the VM (the cloud-hypervisor command
#     line, the virtiofsd daemons, the tap setup) is built from
#     ./boundary.nix and this file only, never from the guest's own
#     configuration, which Hermes may change through PRs. From the guest
#     argo takes the kernel, initrd, kernel command line and store image:
#     data for the VM, passed to cloud-hypervisor as escaped arguments.
#   - Network: tap vm-hermes, argo 10.233.2.1, the VM 10.233.2.2 (the
#     container keeps 10.233.1.x). Same grants as the container: to argo
#     only ollama; forwarded, DNS to Pi-hole and the router, nothing else on
#     private or local ranges, internet otherwise. No IPv6 on the link. On
#     cutover, HA's mutual-TLS port and the tailnet PR events port are
#     DNATed to the VM instead of the container.
#   - Files: two disk images in /var/lib/microvms/hermes (var-lib.img, the
#     VM's /var/lib with Hermes's state and signal-cli's keys;
#     nix-rw.img, its writable store layer, emptied on every start) and
#     three read-only virtiofs shares: the GitHub token (/run/hermes-github),
#     the webhook certificate (/etc/hermes-tls) and a copy of
#     /etc/hermes/gateway.env (the GitHub App key stays on argo). The VM sees
#     none of argo's store: its read-only store is an image of its own
#     closure.
#   - State is the VM's alone, not shared live with argo as the container's
#     is: SQLite (kanban.db, state.db) can't lock across virtiofs. Reach it
#     from argo as root: ssh vsock-mux//var/lib/microvms/hermes/notify.vsock
#     (keys in /etc/hermes/vm-admin-keys).
{ config, lib, pkgs, self, microvm, nixpkgs, ... }:
let
  cfg = config.services.hermesVm;
  name = "hermes";
  iface = "vm-hermes";
  hostAddress = "10.233.2.1";
  guestAddress = "10.233.2.2";
  vmDir = "${config.microvm.stateDir}/${name}";
  secretsDir = "/run/hermes-vm/secrets";

  # Same as the container (modules/hermes-container.nix).
  webhookPort = 8645;
  prEventsPort = 8646;
  homeAssistantAddress = "192.168.1.153";

  # The guest as Hermes defines it (hosts/hermes/).
  guest = self.nixosConfigurations.${name}.config;
  # The boundary alone, evaluated without anything from the guest.
  boundary =
    (nixpkgs.lib.nixosSystem {
      modules = [
        microvm.nixosModules.microvm
        ./boundary.nix
        {
          nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform;
          networking.hostName = name;
          system.stateVersion = "26.05";
        }
      ];
    }).config;
  runner = microvm.lib.buildRunner {
    inherit pkgs;
    microvmConfig = boundary.microvm // {
      hostName = name;
      inherit (guest.microvm) kernel initrdPath kernelParams storeDisk;
    };
    toplevel = guest.system.build.toplevel;
  };
  # The guest must mount what the boundary provides; a mismatch fails here,
  # not at boot. (Only the fields that matter: unset ones can't be compared.)
  fields = {
    hypervisor = x: x;
    writableStoreOverlay = x: x;
    storeOnDisk = x: x;
    interfaces = map (i: { inherit (i) type id mac; });
    volumes = map (v: { inherit (v) image label mountPoint fsType readOnly; });
    shares = map (s: { inherit (s) proto tag source mountPoint readOnly; });
  };
  # The files taken from the guest go into cloud-hypervisor's comma-separated
  # options: only plain store paths, so that the guest can't name another
  # file or add an option.
  guestFiles = {
    kernel = "${guest.microvm.kernel.dev}/vmlinux";
    inherit (guest.microvm) initrdPath;
    storeDisk = toString guest.microvm.storeDisk;
  };
  isPlainStorePath =
    p:
    builtins.match "${builtins.storeDir}/[0-9a-z]{32}-[^/,]+(/[^,]*)?" p != null
    && !lib.hasInfix "/.." p;
  sameAsBoundary = attr: fields.${attr} guest.microvm.${attr} == fields.${attr} boundary.microvm.${attr};
in
{
  imports = [ microvm.nixosModules.host ];

  options.services.hermesVm = {
    enable = lib.mkEnableOption "Hermes's microVM (declared, started by hand)";
    cutover = lib.mkEnableOption "Hermes's microVM as the live Hermes: started at boot, webhooks routed to it";
  };

  config = lib.mkMerge [
    # The host module does nothing unless enabled (it defaults to on).
    { microvm.host.enable = cfg.enable; }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.cutover -> !config.services.hermesContainer.enable;
          message = "services.hermesVm.cutover needs services.hermesContainer.enable = false: one Hermes, one signal-cli.";
        }
      ]
      ++ map (attr: {
        assertion = sameAsBoundary attr;
        message = "hosts/hermes: microvm.${attr} differs from modules/hermes-vm/boundary.nix";
      }) (lib.attrNames fields)
      ++ lib.mapAttrsToList (attr: path: {
        assertion = isPlainStorePath path;
        message = "hosts/hermes: microvm ${attr} (${path}) must be a plain store path";
      }) guestFiles;

      microvm.vms.${name} = {
        # microvm.nix reads the runner, the shares (for tmpfiles) and the
        # toplevel from this.
        evaluatedConfig.config = {
          microvm = {
            declaredRunner = runner;
            inherit (boundary.microvm) shares;
          };
          system.build.toplevel = guest.system.build.toplevel;
        };
        autostart = cfg.cutover;
        # A rebuild of argo changes what the VM boots next, not the running
        # VM, which deploys main itself.
        restartIfChanged = false;
      };

      # microvm.nix's default lets any user attach taps to any bridge
      # through the setuid qemu-bridge-helper; nothing here uses it.
      environment.etc."qemu/bridge.conf".text = "";

      systemd.tmpfiles.rules = [
        "d /run/hermes-vm 0700 root root -"
        "d ${secretsDir} 0700 root root -"
        # root's authorized_keys in the VM, over vsock only (see the header).
        "f /etc/hermes/vm-admin-keys 0600 root root -"
      ];

      # What the VM may read of /etc/hermes, copied before each start.
      systemd.services.hermes-vm-secrets = {
        description = "Stage the secrets Hermes's microVM may read";
        before = [ "microvm-virtiofsd@${name}.service" "microvm@${name}.service" ];
        requiredBy = [ "microvm@${name}.service" ];
        partOf = [ "microvm@${name}.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
        };
        script = ''
          stage() {
            install -m 0600 "/etc/hermes/$1" "${secretsDir}/.$2.new"
            mv -f "${secretsDir}/.$2.new" "${secretsDir}/$2"
          }
          stage gateway.env gateway.env
          stage vm-admin-keys admin_authorized_keys
          # The VM's deploy kill switch, from argo (hosts/hermes/deploy.nix).
          if [ -e /etc/hermes/vm-deploy-paused ]; then
            touch ${secretsDir}/deploy-paused
          else
            rm -f ${secretsDir}/deploy-paused
          fi
        '';
      };

      systemd.services."microvm-tap-interfaces@${name}".serviceConfig.ExecStartPost = [
        "${pkgs.procps}/bin/sysctl -q -w net.ipv6.conf.${iface}.disable_ipv6=1"
        "${pkgs.iproute2}/bin/ip addr replace ${hostAddress}/24 dev ${iface}"
      ];
      # The writable store layer starts empty (see boundary.nix); microvm-run
      # recreates the image.
      systemd.services."microvm@${name}".serviceConfig.ExecStartPre = [
        "${pkgs.coreutils}/bin/rm -f ${vmDir}/nix-rw.img"
      ];

      networking.nat = {
        enable = true;
        internalInterfaces = [ iface ];
      };
      networking.networkmanager.unmanaged = [ "interface-name:${iface}" ];

      # As the container's grants (modules/hermes-container.nix), for the
      # VM's tap; ingress only on cutover.
      networking.firewall.extraCommands = ''
        iptables -w -N hermes-vm-to-host 2>/dev/null || iptables -w -F hermes-vm-to-host
        iptables -w -A hermes-vm-to-host -p tcp --dport 11434 -j nixos-fw-accept
        iptables -w -A hermes-vm-to-host -m conntrack --ctstate ESTABLISHED,RELATED -j nixos-fw-accept
        iptables -w -A hermes-vm-to-host -j nixos-fw-refuse
        iptables -w -I nixos-fw 1 -i ${iface} -j hermes-vm-to-host

        iptables -w -N hermes-vm-egress 2>/dev/null || iptables -w -F hermes-vm-egress
        iptables -w -A hermes-vm-egress -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
        for resolver in 192.168.1.135 192.168.1.1; do
          for proto in udp tcp; do
            iptables -w -A hermes-vm-egress -d "$resolver" -p "$proto" --dport 53 -j RETURN
          done
        done
        for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4; do
          iptables -w -A hermes-vm-egress -d "$net" -j REJECT
        done
        iptables -w -D FORWARD -i ${iface} -j hermes-vm-egress 2>/dev/null || true
        iptables -w -I FORWARD 1 -i ${iface} -j hermes-vm-egress
      '' + lib.optionalString cfg.cutover ''

        iptables -w -t nat -N hermes-vm-ingress 2>/dev/null || iptables -w -t nat -F hermes-vm-ingress
        iptables -w -t nat -A hermes-vm-ingress -s ${homeAssistantAddress} -p tcp --dport ${toString webhookPort} \
          -m addrtype --dst-type LOCAL -j DNAT --to-destination ${guestAddress}:${toString webhookPort}
        iptables -w -t nat -A hermes-vm-ingress -i tailscale0 -s 100.64.0.0/10 -p tcp --dport ${toString prEventsPort} \
          -m addrtype --dst-type LOCAL -j DNAT --to-destination ${guestAddress}:${toString prEventsPort}
        iptables -w -t nat -D PREROUTING -j hermes-vm-ingress 2>/dev/null || true
        iptables -w -t nat -I PREROUTING 1 -j hermes-vm-ingress
      '';
      # Before every reload too; see the container's note on why the chains
      # themselves must go.
      networking.firewall.extraStopCommands = ''
        iptables -w -D FORWARD -i ${iface} -j hermes-vm-egress 2>/dev/null || true
        iptables -w -t nat -D PREROUTING -j hermes-vm-ingress 2>/dev/null || true
        iptables -w -D nixos-fw -i ${iface} -j hermes-vm-to-host 2>/dev/null || true
        for chain in hermes-vm-to-host hermes-vm-egress; do
          iptables -w -F "$chain" 2>/dev/null || true
          iptables -w -X "$chain" 2>/dev/null || true
        done
        iptables -w -t nat -F hermes-vm-ingress 2>/dev/null || true
        iptables -w -t nat -X hermes-vm-ingress 2>/dev/null || true
      '';
    })
  ];
}
