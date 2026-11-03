# hermes: Hermes's VM on the TrueNAS box

A NixOS VM next to Home Assistant's on the TrueNAS box, hosting four NixOS
containers:

- `hermes`: Hermes Agent's gateway, signal-cli and the webhook front (nginx).
  `modules/hermes/hermes-container.nix`: its own egress rules, NAT, and the
  forwarded webhook ports.
- `ha` and `ha-pr`: the Home Assistant runners (`modules/ha-gitops.nix`).
- `nixfiles`: this repo's runner, for CI's `Deploy (hermes)` job (`deploy.nix`).

All three runners are `modules/runners/runner-containers.nix` entries.

The VM itself keeps the credentials (its own GitHub App key and token, the
webhook certificate, `gateway.env`); the hermes container gets read-only
`gateway.env`, the certificate and the token, never the key. It also runs Tailscale and its own deploy.

TrueNAS defines the VM; `configuration.nix` is the system on its disk. It is
booted once from an image built here, and from then on it deploys `main` to
itself (`deploy.nix`).

Only root and the runners may use the VM's nix-daemon. The hermes container
doesn't see its socket at all. Hermes doesn't build; CI checks its PRs.

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
| A long-lived token of the non-admin Home Assistant user "Hermes" | `/etc/hermes/ha-token`, root 0600 | `systemctl start hermes-egress-token`; see [Home Assistant](#home-assistant) |
| A **new** private key for the zila-hermes GitHub App (app settings → Private keys → Generate) | `/etc/hermes/github-app.pem`, root 0600 | `systemctl start hermes-github-token`; `/run/hermes-github/token` appears |
| A Tailscale auth key, pre-approved, tagged `tag:hermes` | `/etc/tailscale/authkey`, root 0600 (below) | `systemctl restart tailscaled-autoconnect`; `tailscale status` |
| The runners' credentials: `token`, `ssh-apply`, `state-passphrase` and a registration token (`gh api -X POST repos/jzila/home-assistant/actions/runners/registration-token -q .token`, an hour's life) as `runner-token` | `/etc/ha-tofu/ha/{token,ssh-apply,state-passphrase,runner-token}` and `/etc/ha-tofu/ha-pr/{state-passphrase,runner-token}`, root 0600 | `systemctl start container@ha container@ha-pr`; they register as `hermes-ha` and `hermes-ha-pr` |
| The webhook server certificate from the step CA, for the VM's name and address (`step ca certificate hermes.local.zila.dev server.crt server.key --provisioner admin --not-after 720h --san hermes.local.zila.dev --san <address>`, on your machine: `step` defaults to the local CA through Home Manager's `~/.step`, or a `step ca bootstrap`) | `/etc/hermes-tls/server.{crt,key}`, `chown root:60` (nginx's gid; the VM has no nginx group of its own), 0640 | nginx in the container starts by itself (`hermes-tls-first`); `hermes-tls-renew` renews it daily within its last 7 days and reloads it |

The Tailscale key has no file to copy; in the VM, read it at a hidden prompt
(works in bash and zsh):

```sh
printf 'Tailscale auth key: '; read -rs k; echo
install -d -m 0700 /etc/tailscale
printf '%s\n' "$k" | install -m 0600 /dev/stdin /etc/tailscale/authkey; unset k
```

Of `/etc/hermes` (root 0700), only `gateway.env` is bound read-only into the
container (`ha-token` stays with the VM's nginx), as `/run/host-secrets/hermes/gateway.env`; the gateway
gets it through systemd, and the app key never enters the container.

Tailnet policy (you edit it): let `tag:github-ci` reach `tag:hermes` on
tcp/8646 only, e.g.

```json
{ "action": "accept", "src": ["tag:github-ci"], "dst": ["tag:hermes:8646"] }
```

and own `tag:hermes` (`tagOwners`) so the auth key can carry it.

### Check

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

## Home Assistant

Hermes reaches Home Assistant through the egress gateway, nginx on the VM
outside its container (`modules/hermes/hermes-egress.nix`), on `10.233.2.1:8647`:
GET of an allowlist of read endpoints (`ha-get`) and POST of the services in
`services.hermesEgress.services` (`ha-call`), nothing else. The gateway adds
the token; the container never sees it. Until a token is installed, the
gateway answers 503.

1. In Home Assistant (Settings → People → Users, advanced mode on): add a
   user **Hermes**, *not* an administrator, "Can only log in from
   the local network" on. Log in as it once (a private window), then on its
   profile → Security → Long-lived access tokens, create one ("hermes-proxy")
   and copy it. Log out.
2. In the VM, read it at a hidden prompt and install it (never echoed, never
   in the shell history):
   ```sh
   printf 'Home Assistant token: '; read -rs t; echo
   printf '%s\n' "$t" | install -m 0600 /dev/stdin /etc/hermes/ha-token; unset t
   systemctl start hermes-egress-token      # renders it for nginx, reloads nginx
   ```
3. Check, from inside the container (`h` and `curl` as in the checks above;
   Hermes's `ha-get` is the first of these):
   ```sh
   p=http://10.233.2.1:8647
   h curl -sS $p/api/                                   # {"message":"API running."}
   h curl -sS -X POST $p/api/services/light/turn_on     # 403, not approved
   h curl -sS $p/api/websocket                          # 403
   h curl -sS -m5 https://192.168.1.153                 # still refused: no LAN
   ```

To rotate, create a new token, install it the same way, then delete the old
one in Home Assistant. To cut Hermes off, delete the token there (or the
file here, then `systemctl start hermes-egress-token`).

## Dashboard

Hermes's dashboard (its web UI, Chat included) is at
`https://hermes.local.zila.dev` from argo and the tailnet, behind nginx on
the VM; port 80 redirects there. It signs in with a passkey through Pocket ID
(`https://id.local.zila.dev`, a TrueNAS app behind the NAS's proxy), as the
OIDC client `hermes-dashboard` (public, PKCE, callback
`https://hermes.local.zila.dev/auth/callback`).

1. For the tailnet: allow your devices `tag:hermes:443` and `tag:hermes:80`
   in the tailnet policy, and make `hermes.local.zila.dev` resolve to the
   VM's tailnet address there (the dashboard only accepts that name).

## The deploy runner

CI's `Deploy (hermes)` job runs on the VM's `nixfiles` runner, which asks the
VM to deploy (`deploy.nix`). Its container starts once its credentials
directory exists. From argo (a registration token is valid for an hour):

```sh
gh api -X POST repos/jzila/nixfiles/actions/runners/registration-token -q .token \
  | ssh root@hermes.local.zila.dev \
      'install -d -m 0700 /etc/nixfiles-runner && install -m 0600 /dev/stdin /etc/nixfiles-runner/runner-token && systemctl start container@nixfiles'
```

It registers as `hermes-nixfiles`. Until then, deploy jobs wait in GitHub's
queue (up to a day). A job queued while the VM is down runs when it is back.

## Later: the NAS on NixOS

When the TrueNAS box becomes a NixOS host from this repo, its configuration
declares this VM (UEFI/OVMF, the same vCPUs, memory and LAN bridge, e.g. with
libvirt or plain QEMU under systemd) and attaches **the same zvol** as its
disk. Nothing in the VM changes: same system, same state, and it keeps
deploying itself. Re-pin the NIC's MAC so the address stays put.

## Day to day

- Each push to main shows its deploy as CI's `Deploy (hermes)` job, with the
  log; the repo's Deployments page lists them. "Re-run" retries a failed one.
- Pause the self-deploy: `touch /var/lib/nixos-deploy/paused` (remove to
  resume, then re-run the job). Deploy jobs fail meanwhile, saying so.
- Logs: the job's, or `journalctl -u nixos-deploy -u nixos-deploy-switch -u nixos-deploy-rollback`,
  `journalctl -M hermes -u hermes-agent`, Hermes's own in `/var/lib/hermes/.hermes/logs`;
  runners: `nixos-container run ha -- journalctl -u github-runner-ha`.
- Booting an older generation from the boot menu works, but the next deploy
  switches back to the deployed commit; pause first to stay there.
- `gateway.env` changes: `systemctl restart container@hermes` (the container's
  mount holds the file it started with, so a replaced file needs a restart of
  the container, not just the gateway).
- A deploy that changes the container's system restarts the container (the
  switch does), then checks its health from inside. The `nixfiles` runner's
  container is the exception: the deploy restarts it after its job is done.
