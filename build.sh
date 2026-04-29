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
[[ -d "$REPO_ROOT/meta-gewgaw" ]] \
    || die "meta-gewgaw/ missing from the repo; cannot continue."
[[ -f "$REPO_ROOT/meta-gewgaw/recipes-core/ssh-keys/files/target-root.pem.pub" ]] \
    || die "target-root public key not staged in meta-gewgaw. Run ./setup.sh first."

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
IMAGE_FEATURES:append = " ssh-server-openssh"
IMAGE_INSTALL:append = " network-config-static target-root-authorized-keys"
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
add_layer_idempotent() {
    local layer="$1"
    if bitbake-layers show-layers 2>/dev/null | awk '{print $1}' | grep -qx "$(basename "$layer")"; then
        log "Layer $(basename "$layer") already registered."
    else
        log "Adding layer $layer"
        bitbake-layers add-layer "$layer"
    fi
}

add_layer_idempotent "$REPO_ROOT/meta-raspberrypi"
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
