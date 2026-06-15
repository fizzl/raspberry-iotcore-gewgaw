# Networking & SSH (the wired management plane)

The image treats `eth0` as a fixed, link-local **management** interface and
`wlan0` as the **internet/uplink** interface. This doc covers `eth0` and SSH; the
Wi-Fi side is in [wifi.md](wifi.md).

## Static `eth0`

The `network-config-static` recipe drops a single systemd-networkd unit,
`/etc/systemd/network/10-eth0-static.network`:

```ini
[Match]
Name=eth0

[Network]
Address=192.168.55.5/24
```

Deliberately **no gateway and no DNS** — `eth0` carries SSH management traffic on
a point-to-point or small LAN segment and is never a default route. Internet
egress (NTP, AWS IoT) goes out `wlan0`. Point your host at the same `/24`, e.g.:

```sh
sudo ip addr add 192.168.55.1/24 dev <your-nic>   # or a static profile
ssh -i target-root.pem root@192.168.55.5
```

## SSH key flow

There is no password login. Access is via a single ed25519 keypair generated on
the host by `setup.sh`:

1. `setup.sh generate_ssh_key` creates `target-root.pem` (+ `.pub`) if absent and
   copies the public half to
   `meta-gewgaw/recipes-core/ssh-keys/files/target-root.pem.pub`.
2. `build.sh` preflight refuses to build if that staged public key is missing.
3. The `target-root-authorized-keys` recipe installs it at build time as
   `/home/root/.ssh/authorized_keys` (mode 0600).

The **private** key `target-root.pem` is gitignored; the staged public key is a
build prerequisite. Losing `target-root.pem` means re-running `setup.sh` (which
regenerates it) and rebuilding/reflashing.

## sshd policy

`target-root-authorized-keys` also drops `/etc/ssh/sshd_config.d/10-gewgaw.conf`:

```
PermitRootLogin prohibit-password
PasswordAuthentication no
```

So root may log in **only** by key, and password auth is off image-wide.

## Reflash-tolerant host helpers

The target is reflashed often, so its SSH host key changes every time. All host
helper scripts (`provision-device.sh`, `setup-wlan.sh`, `add-network.sh`,
`boot.sh`) connect with:

```
-i target-root.pem -o IdentitiesOnly=yes
-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
-o GlobalKnownHostsFile=/dev/null
```

i.e. host-key checking disabled and kept out of `known_hosts`, so a stale entry
can't block you. This is appropriate for a trusted point-to-point LAN link only —
**do not** reuse these options for anything reachable off the local segment. Each
helper honors `TARGET` (default `root@192.168.55.5`) and `SSH_KEY` (default
`./target-root.pem`).
</content>
