# raspberry-iotcore-gewgaw

Home for building a custom minimal Linux image for Raspberry Pi 3 (tested on
Model B v1.2) with Yocto / Poky and [meta-raspberrypi].

## Quick start

On an Ubuntu / Debian host:

```sh
./setup.sh   # installs host deps, clones poky + meta-raspberrypi, generates target-root.pem
./build.sh   # configures bitbake and builds core-image-base for raspberrypi3
```

Both scripts are idempotent and never discard local changes in the source
trees they manage. Logs are written under `logs/`.

The flashable image lands at:

```
build/tmp/deploy/images/raspberrypi3/core-image-base-raspberrypi3.wic.bz2
```

## What you get

- **Yocto release**: scarthgap (5.0 LTS).
- **Machine**: `raspberrypi3` (32-bit; suits Pi 3 B v1.2).
- **Init**: systemd.
- **Image**: `core-image-base` with OpenSSH server.
- **Networking**: static `192.168.55.5/24` on `eth0` via systemd-networkd.
- **SSH**: `target-root.pem` (ed25519, generated locally) is preinstalled as
  `root`'s `authorized_keys`; password login is disabled for root.

Connect to the device from a host on the same LAN:

```sh
ssh -i target-root.pem root@192.168.55.5
```

## Repository layout

| Path | Description |
| --- | --- |
| `setup.sh` | Host prep, repo cloning (FF-only), SSH key generation. |
| `build.sh` | Configures `local.conf` / `bblayers.conf` and runs `bitbake`. |
| `meta-gewgaw/` | Project layer: static-IP unit, root authorized_keys, sshd policy. |
| `poky/` | Cloned by `setup.sh` (gitignored). |
| `meta-raspberrypi/` | Cloned by `setup.sh` (gitignored). |
| `build/` | BitBake build directory (gitignored). |
| `target-root.pem` / `.pub` | Generated locally; private key is gitignored. |

## Useful overrides

```sh
IMAGE=core-image-minimal ./build.sh                       # smaller image
MACHINE=raspberrypi3-64 ./build.sh                        # 64-bit userland
POKY_REF=yocto-5.0.7 META_RPI_REF=scarthgap ./setup.sh    # pin to a tag
SKIP_APT=1 ./setup.sh                                     # non-Debian host
```

[meta-raspberrypi]: https://github.com/agherzan/meta-raspberrypi
