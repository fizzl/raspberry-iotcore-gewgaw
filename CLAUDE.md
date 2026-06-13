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
  - `wic/sdimage-gewgaw.wks` → the partition layout (`WKS_FILE`); root partition is grown on first boot, not at image time

When adding a feature to the image you generally add a recipe under
`meta-gewgaw/recipes-*/` and append its package name to `IMAGE_INSTALL` in
`build.sh`'s `managed_block()`.
