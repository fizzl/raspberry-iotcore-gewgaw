# raspberry-iotcore-gewgaw

Home for building a custom minimal Linux image for Raspberry Pi 3 (tested on
Model B v1.2) with Yocto / Poky and [meta-raspberrypi].

## Quick start

On an Ubuntu / Debian host:

```sh
./setup.sh   # host deps, clone poky + meta-raspberrypi + meta-openembedded, target-root.pem, Amazon Root CA
./build.sh   # configures bitbake and builds core-image-base for raspberrypi3
```

Both scripts are idempotent and never discard local changes in the source
trees they manage. Logs are written under `logs/`.

`build.sh` also appends `LICENSE_FLAGS_ACCEPTED += "synaptics-killswitch"`
so the Raspberry Pi Wi-Fi firmware packages recommended by `raspberrypi3` are
buildable. See `meta-raspberrypi/docs/ipcompliance.md` for the upstream note on
that license gate.

The flashable image lands at:

```
build/tmp/deploy/images/raspberrypi3/core-image-base-raspberrypi3.wic.bz2
```

## Flash the image to a microssd for testing

```
cd build/tmp/deploy/images/raspberrypi3
sudo bmaptool copy \
  --bmap core-image-base-raspberrypi3.rootfs.wic.bmap \
  core-image-base-raspberrypi3.rootfs.wic.bz2 \
  /dev/sdX
sync
```

Where /dev/sdX is a writable microSD device root.

After this, you can insert the microSD into the Raspberry and power it on.

## What you get

- **Yocto release**: scarthgap (5.0 LTS).
- **Machine**: `raspberrypi3` (32-bit; suits Pi 3 B v1.2).
- **Init**: systemd.
- **Image**: `core-image-base` with OpenSSH server.
- **Networking**: static `192.168.55.5/24` on `eth0` via systemd-networkd.
- **SSH**: `target-root.pem` (ed25519, generated locally) is preinstalled as
  `root`'s `authorized_keys`; password login is disabled for root.
- **AWS IoT MQTT**: a mosquitto-based mutual-TLS helper (`aws-iot-mqtt`), the
  connection config, and the public Amazon Root CA. The device cert + key are
  *not* baked in — they are provisioned over SSH (see below).
- **Wi-Fi stack**: Pi 3 WLAN driver + firmware + `wpa-supplicant` are present;
  only runtime config is needed (see below).

Connect to the device from a host on the same LAN:

```sh
ssh -i target-root.pem root@192.168.55.5
```

## Provision AWS IoT credentials

The image ships only the public Amazon Root CA; the per-device certificate and
private key are pushed to the running target over SSH and never committed or
baked into the image.

```sh
./provision-device.sh device.crt device.key   # copies into /etc/aws-iot/certs, then self-tests
```

On the device you can then publish / subscribe / self-test:

```sh
aws-iot-mqtt check                 # connect + publish to a self-test topic
aws-iot-mqtt pub [topic] [message] # defaults from /etc/aws-iot/aws-iot.conf
aws-iot-mqtt sub [topic]
```

The endpoint and thing name are account-specific and live only in the generated
(gitignored) `aws-iot.conf`. `setup.sh` fills them in from the AWS CLI, or set
them explicitly:

```sh
AWS_IOT_ENDPOINT="xxxxxxxxxxxx-ats.iot.<region>.amazonaws.com" \
AWS_IOT_THING="my-thing-name" ./setup.sh
```

The device's IoT policy should be scoped to that client id and a
`gewgaw/<thing>/*` topic space.

## Dev Wi-Fi

`core-image-base` for `raspberrypi3` already includes the WLAN driver
(`brcmfmac`), the BCM43430 firmware, and `wpa-supplicant`; only configuration is
missing. Push it to the running target over eth0 (the PSK is hashed on-device,
nothing is committed or baked in):

```sh
./setup-wlan.sh "MySSID"        # prompts for the passphrase (no echo)
./setup-wlan.sh "MySSID" ""     # open network
```

Re-run after each flash. `eth0` stays the preferred default route; `wlan0` is
used for internet (e.g. so `aws-iot-mqtt check` can reach AWS).

## Repository layout

| Path | Description |
| --- | --- |
| `setup.sh` | Host prep, repo cloning (FF-only), SSH key gen, Amazon Root CA fetch. |
| `build.sh` | Configures `local.conf` / `bblayers.conf` and runs `bitbake`. |
| `provision-device.sh` | Pushes the AWS IoT device cert + key to the running target over SSH. |
| `setup-wlan.sh` | Configures dev Wi-Fi on the running target over SSH. |
| `meta-gewgaw/` | Project layer: static-IP unit, authorized_keys, sshd policy, rootfs grow, AWS IoT MQTT. |
| `poky/` | Cloned by `setup.sh` (gitignored). |
| `meta-raspberrypi/` | Cloned by `setup.sh` (gitignored). |
| `meta-openembedded/` | Cloned by `setup.sh` (gitignored); provides `mosquitto`. |
| `build/` | BitBake build directory (gitignored). |
| `target-root.pem` / `.pub` | Generated locally; private key is gitignored. |
| `device.crt` / `device.key` | AWS IoT device credentials; gitignored, never baked in. |

## Useful overrides

```sh
IMAGE=core-image-minimal ./build.sh                       # smaller image
MACHINE=raspberrypi3-64 ./build.sh                        # 64-bit userland
POKY_REF=yocto-5.0.7 META_RPI_REF=scarthgap ./setup.sh    # pin to a tag
SKIP_APT=1 ./setup.sh                                     # non-Debian host
```

[meta-raspberrypi]: https://github.com/agherzan/meta-raspberrypi
