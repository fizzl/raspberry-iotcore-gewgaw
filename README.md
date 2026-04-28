# raspberry-iotcore-gewgaw

Home for building a custom minimal Linux image for Raspberry Pi with Yocto.

This repository currently provides bootstrap scripts for:

- host dependency installation
- Yocto source/layer checkout for the Whinlatter-era workflow
- one-command build flow for Raspberry Pi

## What Is In This Repo

- `setup_dependencies.sh`
- `setup_yocto.sh`
- `build_image.sh`

All scripts are designed to be:

- idempotent (safe to re-run)
- non-destructive (no forced resets, no destructive git operations)
- verbose (timestamped logs in `./logs/`)

## Why This Setup Looks Different In 5.3+

Yocto 5.3 (Whinlatter) changed setup expectations compared to older "clone poky and go" flows.

This repo uses split sources by default:

- BitBake: `https://git.openembedded.org/bitbake`
- OpenEmbedded-Core: `https://git.openembedded.org/openembedded-core`
- meta-yocto: `https://git.yoctoproject.org/meta-yocto`
- meta-raspberrypi: `https://github.com/agherzan/meta-raspberrypi.git`

## Quick Start

From the repository root:

```bash
./setup_dependencies.sh
./setup_yocto.sh
./build_image.sh
```

Default build image is `core-image-minimal`.

To build a different image:

```bash
./build_image.sh core-image-base
```

## Script Details

### 1) setup_dependencies.sh

Installs required host packages with `apt` (Debian/Ubuntu/Kali style systems).

Behavior:

- checks which packages are already installed
- only installs missing packages
- writes a timestamped log under `logs/`

### 2) setup_yocto.sh

Bootstraps Yocto sources and Raspberry Pi layer in `./yocto/`.

Behavior:

- clones repositories if missing
- fetches and updates existing repositories when safe
- skips risky updates if a working tree is dirty
- refuses to modify non-git directories
- writes helper snippets into `yocto/conf-snippets/`

Generated snippets:

- `yocto/conf-snippets/rpi3-model-b-v1_2.conf`
- `yocto/conf-snippets/rpi3-model-b-v1_2.bblayers.conf.append`

Default refs:

- `BITBAKE_REF=yocto-5.3.3` (tag)
- `OECORE_REF=whinlatter`
- `META_YOCTO_REF=whinlatter`
- `META_RPI_REF=whinlatter`

### 3) build_image.sh

Performs the actual build flow:

1. sources `oe-init-build-env`
2. idempotently adds required layers
3. sets `MACHINE` (default `raspberrypi3`)
4. runs `bitbake` for the selected image

Defaults:

- machine: `raspberrypi3` (Raspberry Pi 3 Model B v1.2 mapping)
- image: `core-image-minimal`

## Useful Overrides

All scripts support overrides through environment variables.

Examples:

```bash
# Use a custom Yocto workspace location
YOCTO_BASE_DIR="$HOME/work/yocto-rpi" ./setup_yocto.sh

# Build with a different machine
MACHINE_NAME="raspberrypi3-64" ./build_image.sh

# Build a different image
IMAGE_NAME="core-image-base" ./build_image.sh
```

## Logs

Each run writes logs to:

- `logs/setup_dependencies_<timestamp>.log`
- `logs/setup_yocto_<timestamp>.log`
- `logs/build_image_<timestamp>.log`

## Beginner Notes

- First run can take a long time (network + full toolchain build).
- Disk and RAM needs are significant for Yocto builds.
- If `build_image.sh` fails quickly, check that `setup_yocto.sh` finished successfully first.
- If host distro support becomes an issue, consider Yocto Buildtools or a supported distro/container workflow.
