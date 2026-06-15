# Build system

A thin, idempotent harness around Yocto/Poky (scarthgap / 5.0 LTS) that produces
a minimal systemd image for the Raspberry Pi 3. The repository tracks only the
two driver scripts, the helper scripts, and the project layer `meta-gewgaw/`;
everything heavy (`poky/`, `meta-raspberrypi/`, `meta-openembedded/`, `build/`)
is cloned or generated locally and gitignored.

## Scripts at a glance

| Script | Role |
| --- | --- |
| `setup.sh` | Host prep + source fetch. Installs apt build deps, clones/fast-forwards the upstream layers, generates the SSH keypair, stages the Amazon Root CA, generates `aws-iot.conf`. |
| `build.sh` | Configures `local.conf` + `bblayers.conf` and runs `bitbake`. |
| `flash.sh` | Writes the built image to a removable block device (guard-railed). |
| `boot.sh` | Reboots a running target over SSH and waits for it to return (dev convenience). |

All four are **idempotent and non-destructive** and log to `logs/` (gitignored).

## `setup.sh`

Run once before the first build, and again whenever you want to pull upstream
updates. Steps:

1. **Host packages** (Debian/Ubuntu) — the Yocto scarthgap host requirement set,
   via `apt-get install --no-install-recommends`. Also generates the
   `en_US.UTF-8` locale BitBake needs. Skip on non-Debian hosts with `SKIP_APT=1`
   (install the deps yourself first).
2. **Source layers** — clones `poky`, `meta-raspberrypi`, `meta-openembedded` at
   `scarthgap`. Existing clones are only **fast-forwarded**; a clone with local
   commits/changes or a non-FF target is left untouched with a warning, so your
   work is never clobbered.
3. **SSH keypair** — `generate_ssh_key` creates `target-root.pem` (ed25519, no
   passphrase) if missing and copies the public half into
   `meta-gewgaw/recipes-core/ssh-keys/files/` for the image to pick up. See
   [networking.md](networking.md).
4. **Amazon Root CA** — downloads the public `AmazonRootCA1.pem` into the aws-iot
   recipe (a public cert, not a secret). See [aws-iot.md](aws-iot.md).
5. **`aws-iot.conf`** — renders the gitignored runtime config from
   `aws-iot.conf.sample`, filling the ATS endpoint + thing name from
   `$AWS_IOT_ENDPOINT`/`$AWS_IOT_THING` or, failing that, an AWS CLI lookup.

### `setup.sh` knobs

| Env var | Default | Meaning |
| --- | --- | --- |
| `POKY_REF` / `META_RPI_REF` / `META_OE_REF` | `scarthgap` | git ref per layer |
| `POKY_URL` / `META_RPI_URL` / `META_OE_URL` | upstreams | clone remotes |
| `SKIP_APT` | unset | `1` skips the apt step (non-Debian host) |
| `AWS_IOT_ENDPOINT` / `AWS_IOT_THING` | AWS CLI lookup | values for `aws-iot.conf` |
| `AMAZON_ROOT_CA_URL` | amazontrust.com | Root CA source |

## `build.sh`

Preflight-checks that `poky/`, `meta-raspberrypi/`, `meta-openembedded/`,
`meta-gewgaw/`, the staged SSH public key, the Root CA, and `aws-iot.conf` all
exist (and dies pointing at `setup.sh` otherwise). Then it sources the OE
environment and does two managed edits before `bitbake`:

### The managed `local.conf` block

`build.sh` owns **only** a marker-delimited region of `build/conf/local.conf`:

```
# >>> gewgaw managed >>>
…
# <<< gewgaw managed <<<
```

On every run the block is regenerated (via `awk`) and everything outside it is
preserved — so you can hand-edit `local.conf` freely as long as you stay out of
the markers. The block pins:

- `MACHINE` (default `raspberrypi3`),
- `usrmerge` + `systemd` distro features and systemd as init manager,
- `LICENSE_FLAGS_ACCEPTED += synaptics-killswitch` (gates the Pi 3 Wi-Fi
  firmware — see `meta-raspberrypi/docs/ipcompliance.md`),
- `IMAGE_FEATURES += ssh-server-openssh tools-debug`,
- the `IMAGE_INSTALL` list (see below),
- `WKS_FILE = "sdimage-gewgaw.wks"` (partition layout),
- parallelism (`BB_NUMBER_THREADS` / `PARALLEL_MAKE`).

### Layer registration

Layers are added to `bblayers.conf` by **direct text insertion**, not
`bitbake-layers add-layer`. This is deliberate: once `meta-gewgaw` is registered,
its `LAYERDEPENDS` on the meta-openembedded layers would make every
`bitbake-layers` invocation re-parse and fail until those layers are also present
— a chicken-and-egg. Direct insertion sidesteps the parse. Order added:
`meta-raspberrypi`, `meta-openembedded/{meta-oe,meta-python,meta-networking}`,
then `meta-gewgaw`.

### `build.sh` knobs

| Env var | Default | Meaning |
| --- | --- | --- |
| `IMAGE` | `core-image-base` | bitbake target |
| `MACHINE` | `raspberrypi3` | target machine (use `raspberrypi3-64` for 64-bit) |
| `BUILD_DIR` | `build` | build directory name |

## What ends up in the image

`IMAGE_INSTALL` (managed block) pulls in, on top of `core-image-base`:

| Package | Provides | Doc |
| --- | --- | --- |
| `network-config-static` | static `eth0` 192.168.55.5/24 | [networking.md](networking.md) |
| `target-root-authorized-keys` | root `authorized_keys` + sshd policy | [networking.md](networking.md) |
| `grow-rootfs` | first-boot rootfs expansion | this doc, below |
| `aws-iot-mqtt` | mutual-TLS MQTT helper + provisioning self-test | [aws-iot.md](aws-iot.md) |
| `mosquitto-clients` | `mosquitto_pub`/`sub` (from meta-networking) | [aws-iot.md](aws-iot.md) |
| `gewgaw-collector` | the collector + submit daemons + units | [collector.md](collector.md), [submit.md](submit.md) |
| `packagegroup-core-full-cmdline` | a usable busybox-plus userland | — |

The Pi 3 WLAN stack (`brcmfmac` + BCM43430 firmware + `wpa-supplicant` + `iw`)
comes in via the `raspberrypi3` machine — only config is missing
([wifi.md](wifi.md)).

Output artifact:

```
build/tmp/deploy/images/raspberrypi3/core-image-base-raspberrypi3.rootfs.wic.bz2
```

## Partition layout & first-boot growth

`meta-gewgaw/wic/sdimage-gewgaw.wks` defines two partitions on `mmcblk0`:

- `p1` — 100 MB vfat `boot` (active),
- `p2` — ext4 `root`, sized to the rootfs **content** at image time.

To avoid baking a card-size assumption into the image, the root partition is left
content-sized and grown on first boot: the `grow-rootfs` recipe ships a oneshot
(`grow-rootfs.service`, `ConditionPathExists=!/var/lib/rootfs-grown.stamp`) that
runs `grow-rootfs.sh` — `sfdisk` extends `mmcblk0p2` to fill the card, `partx -u`
updates the kernel view, and `resize2fs` grows the ext4 online. A stamp file
makes it run exactly once. This headroom (GBs) is what lets the sighting DB
accumulate without a purge policy.

## `flash.sh`

`./flash.sh /dev/sdX` writes `…rootfs.wic.bz2` with `bmaptool`. Guard rails: the
target must be a **whole** removable block device with **no mounted** partitions,
and you must retype the device path to confirm before the destructive write.
Honors the same `IMAGE`/`MACHINE`/`BUILD_DIR` overrides as `build.sh`.

## `boot.sh`

`./boot.sh` reboots the running target over SSH and polls until it's back
(`--no-wait` to fire-and-forget). Uses reflash-tolerant SSH options (no host-key
checking — the target's key changes every flash). Knobs: `TARGET`
(default `root@192.168.55.5`), `SSH_KEY` (default `./target-root.pem`),
`WAIT_SECS` (default 180).

## Typical loops

```sh
./setup.sh                 # once (or to pull upstream updates)
./build.sh                 # iterate: rebuild after recipe/daemon edits
./flash.sh /dev/sdX        # write a fresh card
# …boot, provision, register Wi-Fi (see top-level README)…
./boot.sh                  # quick reboot to retest the boot beacon
```

There is no unit/integration test suite for the image itself: iteration means
rebuild + boot. The daemons' pure-Python logic can be exercised on the host
(`python3 -m py_compile …`, ad-hoc imports against `schema.sql`).
</content>
