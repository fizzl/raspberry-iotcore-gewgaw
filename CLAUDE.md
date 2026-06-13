# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Yocto/Poky build harness that produces a minimal systemd-based Linux image for
the Raspberry Pi 3 (scarthgap / 5.0 LTS). The repo itself contains only two driver
scripts plus the project layer `meta-gewgaw/`; the bulk of the build inputs
(`poky/`, `meta-raspberrypi/`, `build/`) are cloned/generated locally and gitignored.

## Workflow

```sh
./setup.sh   # host deps (apt), clone poky + meta-raspberrypi (FF-only), gen target-root.pem
./build.sh   # write managed local.conf block, register layers, run bitbake
```

Run `setup.sh` before `build.sh`; `build.sh` preflight-checks that `poky/`,
`meta-raspberrypi/`, and the staged public key exist and dies otherwise. Both
scripts are idempotent and **non-destructive** — they only fast-forward existing
clones and never overwrite local changes. Logs land in `logs/`.

Output image: `build/tmp/deploy/images/raspberrypi3/core-image-base-raspberrypi3.wic.bz2`
(flash with `bmaptool`, see README). Connect: `ssh -i target-root.pem root@192.168.55.5`.

### Override knobs (env vars)

- `build.sh`: `IMAGE` (default `core-image-base`), `MACHINE` (`raspberrypi3`), `BUILD_DIR` (`build`)
- `setup.sh`: `POKY_REF`/`META_RPI_REF` (`scarthgap`), `POKY_URL`/`META_RPI_URL`, `SKIP_APT=1` (non-Debian host)

There is no test suite; iteration means re-running `build.sh` and booting the image.

## Architecture notes

- **`build.sh` owns `build/conf/local.conf`** only inside a marker-delimited block
  (`# >>> gewgaw managed >>>` … `# <<< gewgaw managed <<<`), rewritten via awk on each
  run. Edits outside that block are preserved; edits inside it are overwritten. The
  block pins MACHINE, systemd init, `LICENSE_FLAGS_ACCEPTED += synaptics-killswitch`
  (gates the Pi Wi-Fi firmware), image features, and the custom `WKS_FILE`.
  Layers are registered with `bitbake-layers add-layer` (a no-op when present).

- **SSH key flow**: `setup.sh generate_ssh_key` creates `target-root.pem` (ed25519)
  and copies the `.pub` into `meta-gewgaw/recipes-core/ssh-keys/files/` so the
  `target-root-authorized-keys` recipe can pull it via `SRC_URI=file://`. The private
  key is gitignored; the staged public key is a build prerequisite.

- **`meta-gewgaw/` recipes** are all pure-data (no compile/configure) installs of
  config/units, each pulled into the image via `IMAGE_INSTALL` in the managed block:
  - `network-config-static` → systemd-networkd `.network` giving eth0 `192.168.55.5/24`
  - `target-root-authorized-keys` → root `authorized_keys` + sshd_config.d snippet forcing pubkey auth
  - `grow-rootfs` → first-boot systemd oneshot that expands the root partition/ext4 to fill the SD card
  - `aws-iot-mqtt` (`recipes-iot/`) → mosquitto-based mutual-TLS MQTT helper (`/usr/bin/aws-iot-mqtt pub|sub|check`), `/etc/aws-iot/aws-iot.conf`, the public `AmazonRootCA1.pem`, and a first-boot `aws-iot-provision.service` self-test. Pulls `mosquitto-clients` from `meta-openembedded/meta-networking` (cloned by `setup.sh`, layers registered in `build.sh`).
  - `wic/sdimage-gewgaw.wks` → the partition layout (`WKS_FILE`); root partition is grown on first boot, not at image time

- **AWS IoT cert flow**: device cert + private key are **never** baked into the image or
  committed (both gitignored). `setup.sh` fetches the public `AmazonRootCA1.pem` into the
  recipe's `files/`. The per-device cert/key are pushed to the running target over SSH by
  `provision-device.sh <device.crt> <device.key>` into `/etc/aws-iot/certs/`, then
  `aws-iot-mqtt check` self-tests. Account-specific values (ATS endpoint, thing name)
  are NOT committed: only `aws-iot.conf.sample` is tracked, and `setup.sh` generates the
  gitignored `aws-iot.conf` from `$AWS_IOT_ENDPOINT`/`$AWS_IOT_THING` or via AWS CLI
  lookup. The device IoT policy should be scoped to `iot:Connect` as the device's client
  id and pub/sub/receive under `gewgaw/<thing>/*`.

- **Dev Wi-Fi**: the image already ships the Pi 3 WLAN stack (`kernel-module-brcmfmac`,
  `linux-firmware-rpidistro-bcm43430`, `wpa-supplicant`, `iw`) — only config is missing.
  `setup-wlan.sh <SSID> [PSK]` pushes a `wpa_supplicant-wlan0.conf` (PSK hashed on-device
  via `wpa_passphrase`) and a `25-wlan0.network` (DHCP) to the running target over eth0,
  enables `wpa_supplicant@wlan0`, and verifies internet. Like `provision-device.sh` it is
  runtime-only: nothing baked into the image, no Wi-Fi secret committed, re-run after each
  flash. Both host scripts use reflash-tolerant SSH opts (no host-key checking).

When adding a feature to the image you generally add a recipe under
`meta-gewgaw/recipes-*/` and append its package name to `IMAGE_INSTALL` in
`build.sh`'s `managed_block()`.
