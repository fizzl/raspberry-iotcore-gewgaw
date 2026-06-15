# raspberry-iotcore-gewgaw

A Yocto/Poky build harness for a minimal, systemd-based Linux image for the
**Raspberry Pi 3** (scarthgap / 5.0 LTS, tested on Model B v1.2) that turns the Pi
into a travelling passive sensor: it records nearby **2.4 GHz Wi-Fi APs** and
**BLE devices** into a local SQLite presence database and **opportunistically
uploads** new observations to **AWS IoT Core** whenever it can reach the internet
over a known or open Wi-Fi network.

The repo tracks only the driver/helper scripts and the project layer
`meta-gewgaw/`; the heavy inputs (`poky/`, `meta-raspberrypi/`,
`meta-openembedded/`, `build/`) are cloned or generated locally and gitignored.

> Per-feature deep dives live in **[`doc/`](doc/README.md)**. This page is the
> minimal path from a clean checkout to a device pushing data to AWS.

## Prerequisites

- A Debian/Ubuntu build host (other distros: install the Yocto scarthgap host
  deps yourself and use `SKIP_APT=1`). Disk: tens of GB for the build.
- A microSD card + reader, and a Pi 3.
- An AWS account with IoT Core, and the AWS CLI configured (optional but makes
  setup hands-off).
- `bmaptool` for flashing (`sudo apt-get install bmap-tools`).

## 1. Create the AWS IoT thing, cert, and policy

Do this once, before building. You need an IoT **thing**, an **active
certificate** (download `device.crt` + `device.key` into this repo), a **policy**
scoped to `gewgaw/<thing>/*`, and your account's **ATS data endpoint**. Full
console + CLI steps are in **[doc/aws-iot.md](doc/aws-iot.md#manual-aws-side-setup-do-this-once-before-building)**.

Keep the **thing name**, **endpoint**, and **region** handy.

## 2. Set up the host and source tree

```sh
AWS_IOT_ENDPOINT="xxxxxxxxxxxx-ats.iot.<region>.amazonaws.com" \
AWS_IOT_THING="<your-thing-name>" \
./setup.sh
```

Installs host deps, clones the upstream layers, generates the SSH keypair
(`target-root.pem`), fetches the Amazon Root CA, and writes the gitignored
`aws-iot.conf`. If the AWS CLI is configured you can omit the env vars and let
`setup.sh` look them up. Idempotent and non-destructive — re-run any time.

## 3. Build the image

```sh
./build.sh
```

Configures BitBake (a marker-delimited managed block in `local.conf`, plus layer
registration) and runs `bitbake core-image-base`. The flashable image lands at:

```
build/tmp/deploy/images/raspberrypi3/core-image-base-raspberrypi3.rootfs.wic.bz2
```

## 4. Flash and boot

```sh
./flash.sh /dev/sdX        # whole removable disk; refuses partitions/mounted/non-removable
```

Insert the card, power on the Pi, and connect over the wired link (the device is
fixed at `192.168.55.5/24` on `eth0`, key auth only):

```sh
# give your host an address on the same /24, then:
ssh -i target-root.pem root@192.168.55.5
```

## 5. Provision the device certificate

The device cert + key are **never** baked into the image — push them to the
running target over SSH:

```sh
./provision-device.sh device.crt device.key   # installs to /etc/aws-iot/certs, then self-tests
```

A successful run ends with `aws-iot-mqtt: OK`. Re-run after every reflash.

## 6. Register Wi-Fi for the upload cycle

For normal (opportunistic) operation, tell the device which networks it may use —
this does **not** connect anything; `gewgaw-submit` associates transiently during
its upload window:

```sh
./add-network.sh "HomeNet"          # prompts for PSK; default priority 50
./add-network.sh "CafeOpen" "" 10   # open network
```

That's it. On the next boot the boot beacon comes online, syncs NTP, and publishes
to `gewgaw/<thing>/status` and `gewgaw/<thing>/sightings`; thereafter the hourly
timer uploads new sightings whenever a known/open AP is reachable. Watch it from
the AWS IoT **MQTT test client** (in the device's region) on `gewgaw/#`.

> **Dev shortcut:** if you just want the Pi continuously online (e.g. to poke at
> `aws-iot-mqtt`) instead of the opportunistic cycle, run `./setup-wlan.sh
> "MySSID"` — but this pins the radio permanently and disables the
> collector/submit cycle. The two modes are mutually exclusive; see
> [doc/wifi.md](doc/wifi.md).

## What you get

- **Yocto** scarthgap (5.0 LTS), **machine** `raspberrypi3` (32-bit), **init**
  systemd, **image** `core-image-base` + OpenSSH.
- **Networking**: static `192.168.55.5/24` on `eth0` (management; no default
  route); `wlan0` for internet via systemd-networkd.
- **SSH**: locally-generated ed25519 key preinstalled for `root`; password auth
  disabled.
- **AWS IoT**: `aws-iot-mqtt` mutual-TLS helper, the public Amazon Root CA, and a
  first-boot provisioning self-test. Device cert/key provisioned over SSH.
- **Sensor stack**: `gewgaw-collector` (Wi-Fi + BLE → SQLite presence model +
  single-radio arbiter) and `gewgaw-submit` (opportunistic upload, boot beacon,
  per-BSSID uplink blacklist).
- **Storage**: root partition auto-grows to fill the SD card on first boot.

On the device you can drive MQTT directly:

```sh
aws-iot-mqtt check                 # connect + publish to a self-test topic
aws-iot-mqtt pub [topic] [message]
aws-iot-mqtt sub [topic]
```

## Documentation

| Doc | Covers |
| --- | --- |
| [doc/build-system.md](doc/build-system.md) | The Yocto harness, managed `local.conf`, layers, image contents, partitioning, rootfs growth, all four scripts. |
| [doc/networking.md](doc/networking.md) | Static `eth0`, SSH key flow, sshd policy. |
| [doc/wifi.md](doc/wifi.md) | The two `wlan0` modes, `setup-wlan.sh` vs `add-network.sh`, the regdomain caveat. |
| [doc/aws-iot.md](doc/aws-iot.md) | The `aws-iot-mqtt` helper, cert/secret flow, manual AWS setup, topics, policy. |
| [doc/collector.md](doc/collector.md) | Scanning, the SQLite presence model, the radio arbiter. |
| [doc/submit.md](doc/submit.md) | Opportunistic upload, `net_health` blacklist, boot beacon, upload format, clock handling. |

## Repository layout

| Path | Description |
| --- | --- |
| `setup.sh` | Host prep, layer cloning (FF-only), SSH key gen, Root CA + `aws-iot.conf`. |
| `build.sh` | Configures `local.conf` / `bblayers.conf` and runs `bitbake`. |
| `flash.sh` | Guard-railed image write to a removable device. |
| `boot.sh` | Reboot the running target over SSH and wait for it to return. |
| `provision-device.sh` | Push the AWS IoT device cert + key to the target. |
| `setup-wlan.sh` | Dev Wi-Fi (permanent association) on the target. |
| `add-network.sh` | Register a known network for the opportunistic uplink. |
| `meta-gewgaw/` | Project layer: static IP, authorized_keys + sshd policy, rootfs grow, AWS IoT helper, collector/submit daemons. |
| `poky/`, `meta-raspberrypi/`, `meta-openembedded/`, `build/` | Cloned/generated by the scripts (gitignored). |
| `target-root.pem` / `.pub` | Generated locally; private key gitignored. |
| `device.crt` / `device.key` | AWS IoT device credentials; gitignored, never baked in. |

## Useful overrides

```sh
IMAGE=core-image-minimal ./build.sh                    # smaller image
MACHINE=raspberrypi3-64 ./build.sh                     # 64-bit userland
POKY_REF=yocto-5.0.7 ./setup.sh                        # pin to a tag
SKIP_APT=1 ./setup.sh                                  # non-Debian host
TARGET=root@10.0.0.9 ./provision-device.sh c.crt c.key # non-default address
```

See each script's header comment and [`doc/`](doc/README.md) for the complete
knob list.

[meta-raspberrypi]: https://github.com/agherzan/meta-raspberrypi
</content>
