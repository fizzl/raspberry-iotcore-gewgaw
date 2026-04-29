#!/usr/bin/env bash
# setup.sh — prepare the host and source tree for a Raspberry Pi 3 Yocto build.
#
# This script is idempotent and non-destructive:
#   * Host packages are installed via apt-get (no-op when already present).
#   * Existing poky / meta-raspberrypi clones are only fast-forwarded; if a
#     non-FF state is detected, we leave them alone and warn.
#   * target-root.pem is generated only when missing.
#
# Override knobs (env vars):
#   POKY_REF       — git ref for poky          (default: scarthgap)
#   META_RPI_REF   — git ref for meta-raspberrypi (default: scarthgap)
#   POKY_URL       — poky remote               (default: git://git.yoctoproject.org/poky)
#   META_RPI_URL   — meta-raspberrypi remote   (default: https://github.com/agherzan/meta-raspberrypi.git)
#   SKIP_APT=1     — skip the apt-get install step (e.g. on non-Debian hosts)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

POKY_REF="${POKY_REF:-scarthgap}"
META_RPI_REF="${META_RPI_REF:-scarthgap}"
POKY_URL="${POKY_URL:-git://git.yoctoproject.org/poky}"
META_RPI_URL="${META_RPI_URL:-https://github.com/agherzan/meta-raspberrypi.git}"

# --- logging --------------------------------------------------------------
mkdir -p logs
LOG_FILE="logs/setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf '[setup] %s\n'      "$*"; }
warn() { printf '[setup] WARN: %s\n' "$*" >&2; }
die()  { printf '[setup] ERROR: %s\n' "$*" >&2; exit 1; }

log "Logging to $LOG_FILE"

# --- host package install -------------------------------------------------
install_host_packages() {
    if [[ "${SKIP_APT:-0}" == "1" ]]; then
        log "SKIP_APT=1 set, skipping apt-get install."
        return 0
    fi

    if [[ ! -r /etc/os-release ]]; then
        die "/etc/os-release not found; cannot detect host distro. Re-run with SKIP_APT=1 if you have installed the Yocto host deps manually."
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
        *debian*|*ubuntu*) ;;
        *) die "This script's apt path supports Debian/Ubuntu hosts only (got ID=${ID:-?}). Install the Yocto host deps manually and re-run with SKIP_APT=1." ;;
    esac

    if ! command -v sudo >/dev/null 2>&1; then
        die "sudo is required to install host packages. Install Yocto's host deps manually and re-run with SKIP_APT=1."
    fi

    # Yocto Project (scarthgap) Ubuntu/Debian build host requirements.
    local pkgs=(
        gawk wget git diffstat unzip texinfo gcc build-essential chrpath
        socat cpio python3 python3-pip python3-pexpect xz-utils debianutils
        iputils-ping python3-git python3-jinja2 python3-subunit zstd
        lz4 file locales libacl1
    )

    log "Updating apt package index..."
    sudo apt-get update -y

    log "Installing host build dependencies (${#pkgs[@]} packages)..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"

    # Yocto/bitbake requires en_US.UTF-8.
    if ! locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
        log "Generating en_US.UTF-8 locale..."
        sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
        sudo locale-gen en_US.UTF-8
    fi
}

# --- git clone / fast-forward (never destructive) -------------------------
sync_repo() {
    local url="$1" ref="$2" dir="$3"

    if [[ ! -d "$dir/.git" ]]; then
        log "Cloning $url ($ref) -> $dir"
        git clone --branch "$ref" "$url" "$dir"
        return 0
    fi

    log "Updating existing $dir (target ref: $ref)..."

    if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
        warn "$dir has local uncommitted changes; skipping update to avoid clobbering work."
        return 0
    fi

    git -C "$dir" fetch --tags origin

    # Resolve the desired ref (branch, tag, or sha) on the remote first.
    local target_sha
    if target_sha=$(git -C "$dir" rev-parse --verify --quiet "origin/$ref"); then
        :
    elif target_sha=$(git -C "$dir" rev-parse --verify --quiet "refs/tags/$ref"); then
        :
    elif target_sha=$(git -C "$dir" rev-parse --verify --quiet "$ref"); then
        :
    else
        warn "Could not resolve ref '$ref' in $dir; leaving it untouched."
        return 0
    fi

    local current_sha
    current_sha=$(git -C "$dir" rev-parse HEAD)
    if [[ "$current_sha" == "$target_sha" ]]; then
        log "$dir already at $ref ($target_sha)."
        return 0
    fi

    # Only advance if it's a fast-forward from current HEAD.
    if git -C "$dir" merge-base --is-ancestor "$current_sha" "$target_sha"; then
        log "Fast-forwarding $dir to $ref..."
        git -C "$dir" merge --ff-only "$target_sha"
    else
        warn "$dir HEAD ($current_sha) is not an ancestor of $ref ($target_sha); refusing to move it. Update manually if intended."
    fi
}

# --- SSH key generation ---------------------------------------------------
generate_ssh_key() {
    local key="$REPO_ROOT/target-root.pem"
    if [[ -f "$key" ]]; then
        log "target-root.pem already exists; leaving it as-is."
    else
        log "Generating target-root.pem (ed25519, no passphrase)..."
        ssh-keygen -t ed25519 -f "$key" -N "" -C "target-root@gewgaw" -q
        chmod 600 "$key"
    fi

    if [[ ! -f "$key.pub" ]]; then
        die "$key.pub missing after key generation; aborting."
    fi

    # Sync the public key into meta-gewgaw so the target-root-authorized-keys
    # recipe can pick it up via SRC_URI=file://target-root.pem.pub.
    local dest="$REPO_ROOT/meta-gewgaw/recipes-core/ssh-keys/files/target-root.pem.pub"
    install -d "$(dirname "$dest")"
    if ! cmp -s "$key.pub" "$dest"; then
        log "Updating $dest from target-root.pem.pub"
        install -m 0644 "$key.pub" "$dest"
    else
        log "meta-gewgaw public key already up to date."
    fi
}

# --- main -----------------------------------------------------------------
install_host_packages
sync_repo "$POKY_URL"     "$POKY_REF"     "$REPO_ROOT/poky"
sync_repo "$META_RPI_URL" "$META_RPI_REF" "$REPO_ROOT/meta-raspberrypi"
generate_ssh_key

log "Setup complete. Next: ./build.sh"
