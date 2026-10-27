# hermes: Hermes's VM on the TrueNAS box

A NixOS VM next to Home Assistant's on the TrueNAS box, hosting three NixOS
containers:

- `hermes`: Hermes Agent's gateway, signal-cli and the webhook front (nginx).
  It is the same `modules/hermes-container.nix` as on argo, with the VM's
  addresses: its own egress rules, NAT, and the forwarded webhook ports.
- `ha` and `ha-pr`: the Home Assistant runners (`modules/ha-gitops.nix`).

The VM itself keeps the credentials (its own GitHub App key and token, the
webhook certificate, `gateway.env`); the hermes container gets read-only
`gateway.env`, the certificate and the token, never the key, as on argo. It also runs Tailscale and its own deploy.

TrueNAS defines the VM; `configuration.nix` is the system on its disk. It is
booted once from an image built here, and from then on it deploys `main` to
itself (`deploy.nix`).

Only root and the runners may use the VM's nix-daemon. The hermes container
doesn't see its socket at all. Hermes doesn't build; CI checks its PRs.

Until the cut-over below, the container on argo (`modules/hermes-container.nix`)
stays the live Hermes and argo runs the Home Assistant runners. The VM can run
alongside it with empty state: no Signal account, no webhooks routed to it, its
runner containers not started. **Signal must never run in two places**, and
neither must the runners.

## Build the image

```sh
nix build .#hermes-image   # result/nixos-image-efi-qcow2-*.qcow2, ~7 GB, sparse
```

UEFI (systemd-boot, with the removable-media fallback `EFI/BOOT/BOOTX64.EFI`, so
no NVRAM entry is needed), GPT with a 256 MB ESP and an ext4 root labelled
`nixos`. The root partition and file system grow to fill the disk at boot, so
the zvol's size is the VM's space: the store (it builds its own updates) and
`/var/lib` (Hermes, signal-cli, the runners' state). Grow the zvol later and
reboot to grow both.

## Create the VM in TrueNAS

1. Copy the qcow2 to the NAS (e.g. a dataset over SMB/NFS, or `scp`).
2. Create a zvol for it, 64 GiB or more (e.g. `data/vms/hermes`), and write the
   image onto it from the TrueNAS shell:
   ```sh
   qemu-img convert -p -f qcow2 -O raw hermes.qcow2 /dev/zvol/data/vms/hermes
   ```
   (Or use the VM wizard's "Import image" for the disk, if your TrueNAS version
   has it: it does the same conversion.)
3. Create the VM (Virtualization → Add):
   - boot method **UEFI**, Secure Boot off;
   - 4 vCPUs, 8 GiB memory (the models run on argo; this is the gateway, the
     JVM of signal-cli, two runner containers, and its own `nix build`s);
   - disk: the zvol, type **VirtIO** (AHCI also works);
   - NIC: **VirtIO**, on the same bridge as Home Assistant's VM (the LAN). Note
     its MAC;
   - display and serial on; autostart on.
4. Give the MAC a DHCP reservation (argo's firewall and Home Assistant use the
   address), or set `hermesVm.address` (CIDR) in `configuration.nix` for a
   static one. Add a DNS name for it in Pi-hole, e.g. `hermes.local.zila.dev`.
5. Boot. It comes up with:
   - sshd (root, John's YubiKey only; keys in `configuration.nix`, more in
     `/root/.ssh/authorized_keys`);
   - the hermes container, with empty state;
   - the runner containers not started;
   - the deploy waiting for `Build NixOS (hermes)` on main.

## Provision the secrets (out of band, never in this repo)

From your machine, `ssh root@hermes.local.zila.dev`. Never paste secrets into a
chat or a command line; copy files (`scp`, or `cat file | ssh … 'install -m 0600 /dev/stdin …'`).

| What | Where (in the VM) | Then |
| --- | --- | --- |
| A **new** private key for the zila-hermes GitHub App (app settings → Private keys → Generate) | `/etc/hermes/github-app.pem`, root 0600 | `systemctl start hermes-github-token`; `/run/hermes-github/token` appears |
| A Tailscale auth key, pre-approved, tagged `tag:hermes` | `/etc/tailscale/authkey`, root 0600 | `systemctl restart tailscaled-autoconnect`; `tailscale status` |
| The webhook server certificate from the step CA, for the VM's name and address (`step ca certificate hermes.local.zila.dev server.crt server.key --provisioner admin --not-after 720h --san hermes.local.zila.dev --san <address>`) | `/etc/hermes-tls/server.{crt,key}`, `chown root:60` (nginx's gid; the VM has no nginx group of its own), 0640 | nginx in the container starts by itself (`hermes-tls-first`); `hermes-tls-renew` renews it daily within its last 7 days and reloads it |

Of `/etc/hermes` (root 0700), only `gateway.env` is bound read-only into the
container, as `/run/host-secrets/hermes/gateway.env`, as on argo; the gateway
gets it through systemd, and the app key never enters the container. `gateway.env`, the signal-cli data
and the runners' credentials wait for the cut-over.

Tailnet policy (you edit it): let `tag:github-ci` reach `tag:hermes` on
tcp/8646 only, as it reaches argo:8646 today, e.g.

```json
{ "action": "accept", "src": ["tag:github-ci"], "dst": ["tag:hermes:8646"] }
```

and own `tag:hermes` (`tagOwners`) so the auth key can carry it.

### Check (prototype)

```sh
systemctl --failed
machinectl list                                # hermes (ha, ha-pr once provisioned)
hermes-health                                  # looks into the container; Signal isn't checked without an account
h() { nixos-container run hermes -- runuser -u hermes -- "$@"; }
h curl -sS -m5 https://192.168.1.153           # refused: no LAN for Hermes
h curl -sS http://<argo>:11434/api/version     # ollama on argo answers
nixos-container run hermes -- ls -l /nix/var/nix/daemon-socket/socket   # /dev/null: no nix-daemon
journalctl -u nixos-deploy                     # waits for "Build NixOS (hermes)" on main
```
(`curl` inside the container: use the host's, `$(readlink -f $(command -v curl))`;
the store is shared.)

From the LAN, `curl -k https://hermes.local.zila.dev:8645/` is refused unless
it comes from Home Assistant's address, and without its client certificate
nginx answers 400. From the tailnet (`tag:github-ci` only),
`POST http://hermes:8646/webhooks/github-pr`.

## Cut-over (manual; one Hermes, one set of runners, at all times)

Pick a quiet moment: no Home Assistant workflow running
(`gh run list -R jzila/home-assistant`), nothing urgent on Signal.

1. **Stop the VM's empty Hermes container and its deploy**, so nothing
   restarts it while state is copied:
   ```sh
   # in the VM
   touch /var/lib/nixos-deploy/paused
   nixos-container stop hermes
   ```
2. **Stop Hermes and the runners on argo.** From here on, nothing writes the
   state on argo; it stays there untouched for a rollback.
   ```sh
   # on argo
   sudo nixos-container stop hermes
   sudo systemctl stop github-runner-ha github-runner-ha-pr ha-drift-report.path
   ```
3. **Copy the state** from argo into the VM, to the same paths: the
   container's `/var/lib/hermes` is the VM's `/var/lib/hermes` (bound in), and
   signal-cli's data lives in the container's root,
   `/var/lib/nixos-containers/hermes/var/lib/signal-cli`, on both. uids match
   for hermes (870) and signal-cli (871); the runners' state is re-owned to
   the VM's fixed ha-tofu (880).
   ```sh
   # on argo, as john (sudo reads; ssh to the VM's root with the YubiKey)
   vm=root@hermes.local.zila.dev
   sudo tar -C /var/lib/hermes --numeric-owner \
     --exclude=./.hermes/gateway.sock --exclude=./.hermes/gateway.pid --exclude=./.hermes/gateway.lock \
     -cf - . | ssh $vm 'tar -C /var/lib/hermes --numeric-owner -xpf -'
   sudo tar -C /var/lib/nixos-containers/hermes/var/lib/signal-cli --numeric-owner -cf - . \
     | ssh $vm 'tar -C /var/lib/nixos-containers/hermes/var/lib/signal-cli --numeric-owner -xpf -'
   sudo cat /etc/hermes/gateway.env | ssh $vm 'install -m 0600 /dev/stdin /etc/hermes/gateway.env'
   sudo tar -C /var/lib/ha-tofu -cf - . \
     | ssh $vm 'tar -C /var/lib/ha-tofu -xpf - && chown -R ha-tofu:ha-tofu /var/lib/ha-tofu'
   ```
4. **The runners' credentials.** Get a fresh registration token
   (`gh api -X POST repos/jzila/home-assistant/actions/runners/registration-token -q .token`,
   valid for an hour, usable by both) and lay out `/etc/ha-tofu` in the VM, one
   directory per container (the directory's existence is what lets each
   container start):
   ```
   /etc/ha-tofu/ha/{token,ssh-apply,state-passphrase,runner-token}   root 0600
   /etc/ha-tofu/ha-pr/{state-passphrase,runner-token}                root 0600
   ```
   Copy `token`, `ssh-apply` and `state-passphrase` from argo's `/etc/ha-tofu`
   the same way as `gateway.env` above (`sudo cat … | ssh $vm 'install -D -m 0600 /dev/stdin …'`),
   and the new registration token into both `runner-token` files.
5. **Start everything in the VM:**
   ```sh
   nixos-container start hermes
   systemctl start container@ha container@ha-pr
   rm /var/lib/nixos-deploy/paused
   ```
   The runners register as `hermes-ha` and `hermes-ha-pr`.
6. **Point the ingress at the VM:**
   - Home Assistant's webhook posts (`shell_command`s for `ha-maintenance` and
     `ha-log`) go to `https://hermes.local.zila.dev:8645/…` instead of argo's
     address; its client certificate stays as it is.
   - `.github/workflows/pr-events.yml` here and in home-assistant: target the
     VM's tailnet name (`hermes`) instead of argo, port 8646 (a PR in each repo).
   - The tailnet policy rule above (if not done yet), and drop the one for
     argo:8646.
7. **argo**, in `hosts/argo/configuration.nix`:
   ```nix
   services.hermesContainer.enable = false;
   services.haGitops.enable = false;
   ```
   then `sudo nixos-rebuild switch --flake .#argo`. Then on GitHub, remove the
   offline runners `argo-ha` and `argo-ha-pr` (repo settings → Runners), delete
   argo's private key of the zila-hermes app (app settings) and
   `/etc/hermes/github-app.pem` on argo.
8. **Verify:**
   - `hermes-health` passes, Signal `connected`;
     `nixos-container run hermes -- runuser -u hermes -- env HERMES_HOME=/var/lib/hermes/.hermes hermes kanban list`
     shows the board;
   - a Signal message gets a reply;
   - Home Assistant's maintenance post and an `ha-log` post show up in
     `journalctl -M hermes -u hermes-agent` (and their tasks reconcile);
   - a comment on a Hermes PR reaches `github-pr` (Signal);
   - a home-assistant PR gets its plan from `hermes-ha-pr`; the next apply or
     nightly drift runs on `hermes-ha`, and drift is filed on the VM's board;
   - `journalctl -u nixos-deploy` records main as deployed.

The `hermes` CLI on argo then falls back to `~/.hermes` (there is no container
any more); use it in the VM's container: `ssh root@hermes…`, then
`nixos-container run hermes -- runuser -u hermes -- env HERMES_HOME=/var/lib/hermes/.hermes hermes …`.

## Rollback

1. In the VM: `touch /var/lib/nixos-deploy/paused; systemctl stop container@hermes container@ha container@ha-pr`,
   then shut the VM down in TrueNAS (a reboot would start them again).
2. If the VM ran for a while, copy its state back the same way, the other
   direction, so nothing is lost and Signal's ratchets don't go back in time:
   `/var/lib/hermes`, `/var/lib/nixos-containers/hermes/var/lib/signal-cli`
   (same paths on argo), and `/var/lib/ha-tofu` (re-owned to argo's
   `ha-tofu`).
3. Revert the three lines on argo and rebuild; point the ingress back; the
   runners re-register as `argo-ha*` with a new registration token in argo's
   `/etc/ha-tofu/runner-token`; argo needs a GitHub App key again.

## Later: the NAS on NixOS

When the TrueNAS box becomes a NixOS host from this repo, its configuration
declares this VM (UEFI/OVMF, the same vCPUs, memory and LAN bridge, e.g. with
libvirt or plain QEMU under systemd) and attaches **the same zvol** as its
disk. Nothing in the VM changes: same system, same state, and it keeps
deploying itself. Re-pin the NIC's MAC so the address stays put.

## Day to day

- Pause the self-deploy: `touch /var/lib/nixos-deploy/paused` (remove to resume).
- Logs: `journalctl -u nixos-deploy -u nixos-deploy-switch -u nixos-deploy-rollback`,
  `journalctl -M hermes -u hermes-agent`, Hermes's own in `/var/lib/hermes/.hermes/logs`;
  runners: `nixos-container run ha -- journalctl -u github-runner-ha`.
- Booting an older generation from the boot menu works, but the next deploy
  round switches back to the deployed commit; pause first to stay there.
- `gateway.env` changes: `systemctl restart container@hermes` (the container's
  mount holds the file it started with, so a replaced file needs a restart of
  the container, not just the gateway).
- A deploy that changes the container's system restarts the container (the
  switch does), then checks its health from inside.
