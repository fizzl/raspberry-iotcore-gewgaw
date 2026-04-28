#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/setup_dependencies_$(date -u +%Y%m%dT%H%M%SZ).log"

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

if ! command -v apt-get >/dev/null 2>&1; then
  error "apt-get was not found. This script supports Debian/Ubuntu-like systems only."
  exit 1
fi

if [[ -n "${CI:-}" ]]; then
  export DEBIAN_FRONTEND=noninteractive
fi

SUDO=()
if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    error "This script needs root privileges. Install sudo or run as root."
    exit 1
  fi
fi

run_apt() {
  "${SUDO[@]}" apt-get "$@"
}

PACKAGES=(
  gawk
  wget
  git
  diffstat
  unzip
  texinfo
  gcc
  build-essential
  chrpath
  socat
  cpio
  python3
  python3-pip
  python3-pexpect
  xz-utils
  debianutils
  iputils-ping
  python3-git
  python3-jinja2
  libsdl1.2-dev
  xterm
  zstd
  lz4
  file
  locales
)

is_installed() {
  local package_name=$1
  dpkg-query -W -f='${Status}' "${package_name}" 2>/dev/null | grep -q 'install ok installed'
}

missing_packages=()
for package_name in "${PACKAGES[@]}"; do
  if ! is_installed "${package_name}"; then
    missing_packages+=("${package_name}")
  fi
done

log "Dependency setup started. Log file: ${LOG_FILE}"
log "Total dependency list size: ${#PACKAGES[@]}"

if [[ ${#missing_packages[@]} -eq 0 ]]; then
  log "All dependencies are already installed. Nothing to do."
  exit 0
fi

log "Missing packages (${#missing_packages[@]}): ${missing_packages[*]}"
log "Running apt-get update..."
run_apt update

log "Installing missing packages with --no-install-recommends..."
run_apt install --yes --no-install-recommends "${missing_packages[@]}"

log "Dependency setup finished successfully."
