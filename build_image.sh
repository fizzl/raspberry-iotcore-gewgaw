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
CUSTOM_LAYER_DIR="${CUSTOM_LAYER_DIR:-${SCRIPT_DIR}/meta-gewgaw}"
BUILD_DIR="${BUILD_DIR:-${YOCTO_BASE_DIR}/build}"
MACHINE_NAME="${MACHINE_NAME:-raspberrypi3}"
IMAGE_NAME="${1:-${IMAGE_NAME:-core-image-minimal}}"
TARGET_ROOT_KEY_PATH="${TARGET_ROOT_KEY_PATH:-${SCRIPT_DIR}/target-root.pem}"
TARGET_ROOT_PUBLIC_KEY_PATH="${TARGET_ROOT_PUBLIC_KEY_PATH:-${TARGET_ROOT_KEY_PATH}.pub}"
ROOT_AUTHORIZED_KEYS_SOURCE="${ROOT_AUTHORIZED_KEYS_SOURCE:-${CUSTOM_LAYER_DIR}/recipes-core/root-authorized-key/files/authorized_keys}"

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

ensure_target_root_ssh_keypair() {
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    error "ssh-keygen was not found. Install OpenSSH client tools on the build host."
    exit 1
  fi

  if [[ -f "${TARGET_ROOT_KEY_PATH}" ]]; then
    log "Using existing target root SSH private key: ${TARGET_ROOT_KEY_PATH}"
  else
    log "Generating target root SSH keypair: ${TARGET_ROOT_KEY_PATH}"
    ssh-keygen -t rsa -b 4096 -m PEM -N "" -f "${TARGET_ROOT_KEY_PATH}" >/dev/null
  fi

  chmod 0600 "${TARGET_ROOT_KEY_PATH}"

  if [[ ! -f "${TARGET_ROOT_PUBLIC_KEY_PATH}" ]]; then
    log "Generating missing target root SSH public key: ${TARGET_ROOT_PUBLIC_KEY_PATH}"
    ssh-keygen -y -f "${TARGET_ROOT_KEY_PATH}" >"${TARGET_ROOT_PUBLIC_KEY_PATH}"
  fi

  chmod 0644 "${TARGET_ROOT_PUBLIC_KEY_PATH}"
}

sync_root_authorized_key() {
  local pub_key_line
  local tmp_file

  pub_key_line="$(awk 'NF { print; exit }' "${TARGET_ROOT_PUBLIC_KEY_PATH}")"
  if [[ -z "${pub_key_line}" ]]; then
    error "Public key file is empty: ${TARGET_ROOT_PUBLIC_KEY_PATH}"
    exit 1
  fi

  mkdir -p "$(dirname "${ROOT_AUTHORIZED_KEYS_SOURCE}")"

  tmp_file="$(mktemp)"
  printf '%s\n' "${pub_key_line}" >"${tmp_file}"

  if [[ -f "${ROOT_AUTHORIZED_KEYS_SOURCE}" ]] && cmp -s "${tmp_file}" "${ROOT_AUTHORIZED_KEYS_SOURCE}"; then
    rm -f "${tmp_file}"
    log "Root authorized_keys source is already up to date: ${ROOT_AUTHORIZED_KEYS_SOURCE}"
    return
  fi

  mv "${tmp_file}" "${ROOT_AUTHORIZED_KEYS_SOURCE}"
  chmod 0644 "${ROOT_AUTHORIZED_KEYS_SOURCE}"
  log "Updated root authorized_keys source: ${ROOT_AUTHORIZED_KEYS_SOURCE}"
}

log "Build script started. Log file: ${LOG_FILE}"
log "Using build dir: ${BUILD_DIR}"
log "Using machine: ${MACHINE_NAME}"
log "Using image: ${IMAGE_NAME}"
log "Using custom layer: ${CUSTOM_LAYER_DIR}"
log "Using target root key: ${TARGET_ROOT_KEY_PATH}"

require_path "${OECORE_DIR}/oe-init-build-env" "OpenEmbedded init script"
require_path "${META_YOCTO_DIR}/meta-poky/conf/layer.conf" "meta-poky layer"
require_path "${META_YOCTO_DIR}/meta-yocto-bsp/conf/layer.conf" "meta-yocto-bsp layer"
require_path "${META_RPI_DIR}/conf/layer.conf" "meta-raspberrypi layer"
require_path "${CUSTOM_LAYER_DIR}/conf/layer.conf" "custom layer"

ensure_target_root_ssh_keypair
sync_root_authorized_key

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
add_layer_if_missing "${CUSTOM_LAYER_DIR}"

set_conf_var "MACHINE" "${MACHINE_NAME}"

log "Starting BitBake build for image: ${IMAGE_NAME}"
bitbake "${IMAGE_NAME}"

log "Build finished successfully."
