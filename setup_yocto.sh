#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/setup_yocto_$(date -u +%Y%m%dT%H%M%SZ).log"

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

if ! command -v git >/dev/null 2>&1; then
  error "git was not found. Install dependencies first with ./setup_dependencies.sh"
  exit 1
fi

YOCTO_BASE_DIR="${YOCTO_BASE_DIR:-${SCRIPT_DIR}/yocto}"
LAYERS_DIR="${YOCTO_BASE_DIR}/layers"

# Whinlatter moved away from the legacy poky single-repository workflow.
# Default to the latest known Yocto 5.3 release tag for bitbake, and whinlatter
# branches for OE-Core and Yocto layers.
YOCTO_RELEASE="${YOCTO_RELEASE:-yocto-5.3.3}"
BITBAKE_REF="${BITBAKE_REF:-${YOCTO_RELEASE}}"
OECORE_REF="${OECORE_REF:-whinlatter}"
META_YOCTO_REF="${META_YOCTO_REF:-whinlatter}"
META_RPI_REF="${META_RPI_REF:-whinlatter}"

BITBAKE_REPO="${BITBAKE_REPO:-https://git.openembedded.org/bitbake}"
OECORE_REPO="${OECORE_REPO:-https://git.openembedded.org/openembedded-core}"
META_YOCTO_REPO="${META_YOCTO_REPO:-https://git.yoctoproject.org/meta-yocto}"
META_RPI_REPO="${META_RPI_REPO:-https://github.com/agherzan/meta-raspberrypi.git}"
MACHINE_NAME="${MACHINE_NAME:-raspberrypi3}"

BITBAKE_DIR="${LAYERS_DIR}/bitbake"
OECORE_DIR="${LAYERS_DIR}/openembedded-core"
META_YOCTO_DIR="${LAYERS_DIR}/meta-yocto"
META_RPI_DIR="${LAYERS_DIR}/meta-raspberrypi"

CONF_SNIPPETS_DIR="${YOCTO_BASE_DIR}/conf-snippets"
RPI_CONF_FILE="${CONF_SNIPPETS_DIR}/rpi3-model-b-v1_2.conf"
RPI_BBLAYERS_FILE="${CONF_SNIPPETS_DIR}/rpi3-model-b-v1_2.bblayers.conf.append"

ensure_repo_exists() {
  local repo_name=$1
  local repo_url=$2
  local repo_dir=$3

  if [[ ! -d "${repo_dir}" ]]; then
    log "Cloning ${repo_name} into ${repo_dir}"
    git clone "${repo_url}" "${repo_dir}"
    return
  fi

  if [[ ! -d "${repo_dir}/.git" ]]; then
    error "${repo_dir} exists but is not a git repository. Refusing to modify it."
    return 1
  fi

  local current_remote
  current_remote="$(git -C "${repo_dir}" remote get-url origin)"
  if [[ "${current_remote}" != "${repo_url}" ]]; then
    warn "${repo_name}: origin remote differs (${current_remote}). Skipping remote changes for safety."
    return 0
  fi

  return 0
}

ensure_repo_at_ref() {
  local repo_name=$1
  local repo_url=$2
  local repo_dir=$3
  local ref=$4

  ensure_repo_exists "${repo_name}" "${repo_url}" "${repo_dir}"

  if [[ -n "$(git -C "${repo_dir}" status --porcelain)" ]]; then
    warn "${repo_name}: local working tree is dirty; skipping checkout/update to avoid destructive changes."
    return 0
  fi

  log "Fetching latest refs for ${repo_name}"
  git -C "${repo_dir}" fetch origin --prune --tags

  if git -C "${repo_dir}" show-ref --verify --quiet "refs/remotes/origin/${ref}"; then
    local current_branch
    current_branch="$(git -C "${repo_dir}" rev-parse --abbrev-ref HEAD)"

    if git -C "${repo_dir}" show-ref --verify --quiet "refs/heads/${ref}"; then
      if [[ "${current_branch}" != "${ref}" ]]; then
        log "${repo_name}: switching branch ${current_branch} -> ${ref}"
        git -C "${repo_dir}" checkout "${ref}"
      fi
    else
      log "${repo_name}: creating local branch ${ref} from origin/${ref}"
      git -C "${repo_dir}" checkout -b "${ref}" "origin/${ref}"
    fi

    log "${repo_name}: fast-forwarding ${ref} from origin/${ref}"
    git -C "${repo_dir}" merge --ff-only "origin/${ref}"
    return 0
  fi

  if git -C "${repo_dir}" rev-parse -q --verify "refs/tags/${ref}^{commit}" >/dev/null; then
    local current_commit
    local target_commit
    current_commit="$(git -C "${repo_dir}" rev-parse HEAD)"
    target_commit="$(git -C "${repo_dir}" rev-list -n 1 "${ref}")"

    if [[ "${current_commit}" == "${target_commit}" ]]; then
      log "${repo_name}: already at tag ${ref}"
      return 0
    fi

    log "${repo_name}: checking out tag ${ref} (detached HEAD)"
    git -C "${repo_dir}" checkout --detach "${ref}"
    return 0
  fi

  error "${repo_name}: ref '${ref}' was not found as either origin branch or tag."
  return 1
}

write_file_if_changed() {
  local target_file=$1
  local tmp_file=$2

  if [[ -f "${target_file}" ]] && cmp -s "${tmp_file}" "${target_file}"; then
    rm -f "${tmp_file}"
    return 0
  fi

  mv "${tmp_file}" "${target_file}"
  return 1
}

write_rpi_config_snippet() {
  mkdir -p "${CONF_SNIPPETS_DIR}"

  local tmp_file
  tmp_file="$(mktemp)"

  cat >"${tmp_file}" <<EOF
# Raspberry Pi 3 Model B v1.2 target configuration.
# In Yocto terms this board maps to MACHINE="raspberrypi3".
MACHINE ?= "${MACHINE_NAME}"
EOF

  if write_file_if_changed "${RPI_CONF_FILE}" "${tmp_file}"; then
    log "Raspberry Pi configuration snippet is already up to date: ${RPI_CONF_FILE}"
  else
    log "Wrote Raspberry Pi configuration snippet: ${RPI_CONF_FILE}"
  fi
}

write_rpi_bblayers_snippet() {
  mkdir -p "${CONF_SNIPPETS_DIR}"

  local tmp_file
  tmp_file="$(mktemp)"

  cat >"${tmp_file}" <<'EOF'
# Add Raspberry Pi BSP layer (path is relative to build directory).
BBLAYERS:append = " ${TOPDIR}/../layers/meta-raspberrypi"
EOF

  if write_file_if_changed "${RPI_BBLAYERS_FILE}" "${tmp_file}"; then
    log "Raspberry Pi bblayers snippet is already up to date: ${RPI_BBLAYERS_FILE}"
  else
    log "Wrote Raspberry Pi bblayers snippet: ${RPI_BBLAYERS_FILE}"
  fi
}

log "Yocto setup started. Log file: ${LOG_FILE}"
log "Using base directory: ${YOCTO_BASE_DIR}"
log "Using release reference: ${YOCTO_RELEASE}"
log "Using refs: bitbake=${BITBAKE_REF}, openembedded-core=${OECORE_REF}, meta-yocto=${META_YOCTO_REF}, meta-raspberrypi=${META_RPI_REF}"

mkdir -p "${YOCTO_BASE_DIR}"
mkdir -p "${LAYERS_DIR}"

ensure_repo_at_ref "bitbake" "${BITBAKE_REPO}" "${BITBAKE_DIR}" "${BITBAKE_REF}"
ensure_repo_at_ref "openembedded-core" "${OECORE_REPO}" "${OECORE_DIR}" "${OECORE_REF}"
ensure_repo_at_ref "meta-yocto" "${META_YOCTO_REPO}" "${META_YOCTO_DIR}" "${META_YOCTO_REF}"
ensure_repo_at_ref "meta-raspberrypi" "${META_RPI_REPO}" "${META_RPI_DIR}" "${META_RPI_REF}"
write_rpi_config_snippet
write_rpi_bblayers_snippet

log "Yocto setup finished successfully."
log "Next step (manual): cd ${YOCTO_BASE_DIR}"
log "Next step (manual): source ${OECORE_DIR}/oe-init-build-env"
log "Next step (manual): bitbake-layers add-layer ../layers/meta-yocto/meta-yocto-bsp ../layers/meta-yocto/meta-poky ../layers/meta-raspberrypi"
log "Next step (manual): add the snippet in ${RPI_CONF_FILE} to build/conf/local.conf"
log "Optional: add ${RPI_BBLAYERS_FILE} content into build/conf/bblayers.conf if you prefer manual edits over bitbake-layers add-layer"
