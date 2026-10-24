# The hermes microVM's boundary: what argo gives it (CPUs, memory, disks, the
# network link, the read-only shares) and how it runs it. Imported twice: by
# the guest (hosts/hermes/), so that it mounts what it is given, and by
# argo's host.nix, which builds the hypervisor command, virtiofsd and the tap
# setup, the parts that run on argo, from this module alone. See host.nix.
{ ... }:
{
  microvm = {
    # cloud-hypervisor, not QEMU: a small Rust VMM with a seccomp filter and
    # only virtio devices, which is all this VM needs. QEMU's extras (user
    # networking, 9p, emulated devices) would only add attack surface.
    hypervisor = "cloud-hypervisor";
    # The LLM runs in argo's ollama; this is the gateway, signal-cli, nginx,
    # tool calls, and now and then a nix build of its own config.
    vcpu = 4;
    mem = 8192;
    # systemd readiness over vsock (microvm@hermes is Type=notify), and the
    # host's way in: ssh vsock-mux//var/lib/microvms/hermes/notify.vsock
    vsock.cid = 3;

    interfaces = [
      {
        type = "tap";
        id = "vm-hermes";
        mac = "02:68:72:6d:73:02";
      }
    ];

    # Paths are relative to /var/lib/microvms/hermes on argo.
    volumes = [
      # Everything that must survive a restart: Hermes's state
      # (/var/lib/hermes), signal-cli's account and keys
      # (/var/lib/signal-cli), the deploy's record (/var/lib/nixos-deploy).
      {
        image = "var-lib.img";
        label = "hermes-var-lib";
        mountPoint = "/var/lib";
        size = 64 * 1024; # MiB, sparse
      }
      # The writable layer of /nix/store, for the VM's own deploys. Recreated
      # empty on every start (host.nix), like the store database on the
      # tmpfs root: the VM boots from argo's build and rebuilds main.
      {
        image = "nix-rw.img";
        label = "hermes-nix-rw";
        mountPoint = "/nix/.rw-store";
        size = 64 * 1024;
      }
    ];
    # The read-only store is a disk image of the guest's closure (the
    # default with no /nix/store share), not argo's store: the VM sees only
    # its own paths.
    writableStoreOverlay = "/nix/.rw-store";

    # Read-only, enforced by virtiofsd on argo (--readonly), at the paths
    # modules/hermes-service.nix expects.
    shares = [
      {
        proto = "virtiofs";
        tag = "hermes-secrets";
        # A copy of /etc/hermes/gateway.env only: /etc/hermes also holds the
        # GitHub App key (host.nix).
        source = "/run/hermes-vm/secrets";
        mountPoint = "/run/host-secrets/hermes";
        readOnly = true;
      }
      {
        proto = "virtiofs";
        tag = "hermes-tls";
        source = "/etc/hermes-tls";
        mountPoint = "/run/host-secrets/hermes-tls";
        readOnly = true;
      }
      {
        proto = "virtiofs";
        tag = "hermes-github";
        source = "/run/hermes-github";
        mountPoint = "/run/host-secrets/github";
        readOnly = true;
      }
    ];
  };
}
