#!/usr/bin/env bash
# build.sh — set up the BitBake environment and build the gewgaw image.
#
# The script is idempotent: it manages a small block in build/conf/local.conf
# delimited by markers, and uses `bitbake-layers add-layer` (which is a no-op
# when a layer is already present) for layer registration. It never rewrites
# user-edited content outside the managed block.
#
# Override knobs (env vars):
#   IMAGE         — bitbake target image (default: core-image-base)
#   MACHINE       — target machine        (default: raspberrypi3)
#   BUILD_DIR     — build directory name  (default: build)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

IMAGE="${IMAGE:-core-image-base}"
MACHINE="${MACHINE:-raspberrypi3}"
BUILD_DIR="${BUILD_DIR:-build}"

# --- logging --------------------------------------------------------------
mkdir -p logs
LOG_FILE="logs/build-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf '[build] %s\n'      "$*"; }
die()  { printf '[build] ERROR: %s\n' "$*" >&2; exit 1; }

log "Logging to $LOG_FILE"

# --- preflight ------------------------------------------------------------
[[ -f "$REPO_ROOT/poky/oe-init-build-env" ]] \
    || die "poky/ not found. Run ./setup.sh first."
[[ -d "$REPO_ROOT/meta-raspberrypi" ]] \
    || die "meta-raspberrypi/ not found. Run ./setup.sh first."
[[ -d "$REPO_ROOT/meta-openembedded" ]] \
    || die "meta-openembedded/ not found. Run ./setup.sh first."
[[ -d "$REPO_ROOT/meta-gewgaw" ]] \
    || die "meta-gewgaw/ missing from the repo; cannot continue."
[[ -f "$REPO_ROOT/meta-gewgaw/recipes-core/ssh-keys/files/target-root.pem.pub" ]] \
    || die "target-root public key not staged in meta-gewgaw. Run ./setup.sh first."
[[ -s "$REPO_ROOT/meta-gewgaw/recipes-iot/aws-iot/files/AmazonRootCA1.pem" ]] \
    || die "Amazon Root CA not staged in meta-gewgaw. Run ./setup.sh first."
[[ -f "$REPO_ROOT/meta-gewgaw/recipes-iot/aws-iot/files/aws-iot.conf" ]] \
    || die "aws-iot.conf not generated in meta-gewgaw. Run ./setup.sh first."

# --- source the OE env (disables nounset around it; OE scripts trip set -u)
log "Sourcing poky/oe-init-build-env $BUILD_DIR ..."
set +u
# shellcheck disable=SC1091
source "$REPO_ROOT/poky/oe-init-build-env" "$REPO_ROOT/$BUILD_DIR" >/dev/null
set -u

# After sourcing, $PWD is $REPO_ROOT/$BUILD_DIR.
LOCAL_CONF="conf/local.conf"
BBLAYERS_CONF="conf/bblayers.conf"
[[ -f "$LOCAL_CONF" ]]   || die "Expected $LOCAL_CONF after sourcing OE env."
[[ -f "$BBLAYERS_CONF" ]] || die "Expected $BBLAYERS_CONF after sourcing OE env."

# --- managed local.conf block --------------------------------------------
MARK_BEGIN="# >>> gewgaw managed >>>"
MARK_END="# <<< gewgaw managed <<<"

managed_block() {
    cat <<EOF
$MARK_BEGIN
# Managed by build.sh — do not edit by hand; changes here will be overwritten.
MACHINE = "$MACHINE"
DISTRO_FEATURES:append = " usrmerge"
DISTRO_FEATURES:append = " systemd"
LICENSE_FLAGS_ACCEPTED:append = " synaptics-killswitch"
VIRTUAL-RUNTIME_init_manager = "systemd"
VIRTUAL-RUNTIME_initscripts = ""
IMAGE_FEATURES:append = " ssh-server-openssh tools-debug"
IMAGE_INSTALL:append = " network-config-static target-root-authorized-keys packagegroup-core-full-cmdline grow-rootfs aws-iot-mqtt mosquitto-clients"
WKS_FILE = "sdimage-gewgaw.wks"
BB_NUMBER_THREADS ?= "\${@oe.utils.cpu_count()}"
PARALLEL_MAKE     ?= "-j \${@oe.utils.cpu_count()}"
$MARK_END
EOF
}

update_managed_block() {
    local file="$1"
    local tmp
    tmp="$(mktemp)"

    if grep -qF "$MARK_BEGIN" "$file"; then
        # Replace existing managed block in place.
        awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip   { print }
        ' "$file" > "$tmp"
    else
        cp "$file" "$tmp"
        printf '\n' >> "$tmp"
    fi

    managed_block >> "$tmp"
    if ! cmp -s "$tmp" "$file"; then
        log "Updating managed block in $file"
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        log "$file managed block already up to date."
    fi
}

update_managed_block "$LOCAL_CONF"

# --- bblayers: add layers idempotently ------------------------------------
# We edit bblayers.conf directly rather than via `bitbake-layers add-layer`,
# because that command re-parses the whole config on every call. Once
# meta-gewgaw is registered, its LAYERDEPENDS on the meta-openembedded layers
# would make every bitbake-layers invocation fail until those layers are
# present — a chicken-and-egg that blocks us from adding them. Direct text
# insertion sidesteps the parse; bitbake resolves layer order itself.
add_layer_idempotent() {
    local layer="$1"
    [[ -d "$layer" ]] || die "layer path not found: $layer"
    if grep -qF "$layer" "$BBLAYERS_CONF"; then
        log "Layer $(basename "$layer") already registered."
        return
    fi
    log "Adding layer $layer"
    local tmp; tmp="$(mktemp)"
    awk -v entry="  $layer \\\\" '
        !done && /^[[:space:]]*BBLAYERS[[:space:]]*\??=[[:space:]]*"/ {
            print; print entry; done = 1; next
        }
        { print }
        END { if (!done) { print "ERROR: BBLAYERS not found" > "/dev/stderr"; exit 3 } }
    ' "$BBLAYERS_CONF" > "$tmp" || { rm -f "$tmp"; die "failed to edit $BBLAYERS_CONF"; }
    mv "$tmp" "$BBLAYERS_CONF"
}

add_layer_idempotent "$REPO_ROOT/meta-raspberrypi"
# meta-oe + meta-python + meta-networking (mosquitto lives here) must precede
# meta-gewgaw, which depends on them.
add_layer_idempotent "$REPO_ROOT/meta-openembedded/meta-oe"
add_layer_idempotent "$REPO_ROOT/meta-openembedded/meta-python"
add_layer_idempotent "$REPO_ROOT/meta-openembedded/meta-networking"
add_layer_idempotent "$REPO_ROOT/meta-gewgaw"

# --- build ---------------------------------------------------------------
log "Starting bitbake $IMAGE for MACHINE=$MACHINE ..."
bitbake "$IMAGE"

DEPLOY_DIR="$REPO_ROOT/$BUILD_DIR/tmp/deploy/images/$MACHINE"
log "Build complete."
log "Artifacts directory: $DEPLOY_DIR"
if compgen -G "$DEPLOY_DIR/${IMAGE}-${MACHINE}.wic*" >/dev/null; then
    log "Image: $(ls -1 "$DEPLOY_DIR"/${IMAGE}-${MACHINE}.wic* 2>/dev/null | head -n1)"
fi
