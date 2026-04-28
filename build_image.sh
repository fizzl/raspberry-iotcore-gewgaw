#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/build_image_$(date -u +%Y%m%dT%H%M%SZ).log"

exec > >(tee -a "${LOG_FILE}") 2>&1

log() {
  printf '[%s] [INFO] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

warn() {
  printf '[%s] [WARN] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

error() {
  printf '[%s] [ERROR] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

on_error() {
  local exit_code=$?
  error "Script failed at line ${BASH_LINENO[0]} with exit code ${exit_code}."
  exit "${exit_code}"
}
trap on_error ERR

YOCTO_BASE_DIR="${YOCTO_BASE_DIR:-${SCRIPT_DIR}/yocto}"
LAYERS_DIR="${LAYERS_DIR:-${YOCTO_BASE_DIR}/layers}"
OECORE_DIR="${OECORE_DIR:-${LAYERS_DIR}/openembedded-core}"
META_YOCTO_DIR="${META_YOCTO_DIR:-${LAYERS_DIR}/meta-yocto}"
META_RPI_DIR="${META_RPI_DIR:-${LAYERS_DIR}/meta-raspberrypi}"
BUILD_DIR="${BUILD_DIR:-${YOCTO_BASE_DIR}/build}"
MACHINE_NAME="${MACHINE_NAME:-raspberrypi3}"
IMAGE_NAME="${1:-${IMAGE_NAME:-core-image-minimal}}"

LOCAL_CONF="${BUILD_DIR}/conf/local.conf"

require_path() {
  local path=$1
  local description=$2
  if [[ ! -e "${path}" ]]; then
    error "Missing ${description}: ${path}"
    error "Run ./setup_yocto.sh first, or set the relevant *_DIR environment variables."
    exit 1
  fi
}

set_conf_var() {
  local key=$1
  local value=$2

  if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "${LOCAL_CONF}"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = \"${value}\"|" "${LOCAL_CONF}"
    log "Updated ${key} in ${LOCAL_CONF}"
  else
    printf '\n%s = "%s"\n' "${key}" "${value}" >>"${LOCAL_CONF}"
    log "Added ${key} to ${LOCAL_CONF}"
  fi
}

add_layer_if_missing() {
  local layer_path=$1
  if bitbake-layers show-layers | awk 'NR > 2 {print $2}' | grep -Fxq "${layer_path}"; then
    log "Layer already present: ${layer_path}"
  else
    log "Adding layer: ${layer_path}"
    bitbake-layers add-layer "${layer_path}"
  fi
}

log "Build script started. Log file: ${LOG_FILE}"
log "Using build dir: ${BUILD_DIR}"
log "Using machine: ${MACHINE_NAME}"
log "Using image: ${IMAGE_NAME}"

require_path "${OECORE_DIR}/oe-init-build-env" "OpenEmbedded init script"
require_path "${META_YOCTO_DIR}/meta-poky/conf/layer.conf" "meta-poky layer"
require_path "${META_YOCTO_DIR}/meta-yocto-bsp/conf/layer.conf" "meta-yocto-bsp layer"
require_path "${META_RPI_DIR}/conf/layer.conf" "meta-raspberrypi layer"

# oe-init-build-env is not nounset-safe in all releases. Disable nounset while sourcing.
set +u
# shellcheck source=/dev/null
source "${OECORE_DIR}/oe-init-build-env" "${BUILD_DIR}" >/dev/null
set -u

if ! command -v bitbake-layers >/dev/null 2>&1; then
  error "bitbake-layers was not found after sourcing the environment."
  exit 1
fi

if [[ ! -f "${LOCAL_CONF}" ]]; then
  error "local.conf was not found: ${LOCAL_CONF}"
  exit 1
fi

add_layer_if_missing "${META_YOCTO_DIR}/meta-poky"
add_layer_if_missing "${META_YOCTO_DIR}/meta-yocto-bsp"
add_layer_if_missing "${META_RPI_DIR}"

set_conf_var "MACHINE" "${MACHINE_NAME}"

log "Starting BitBake build for image: ${IMAGE_NAME}"
bitbake "${IMAGE_NAME}"

log "Build finished successfully."
