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
#   META_OE_REF    — git ref for meta-openembedded (default: scarthgap)
#   POKY_URL       — poky remote               (default: git://git.yoctoproject.org/poky)
#   META_RPI_URL   — meta-raspberrypi remote   (default: https://github.com/agherzan/meta-raspberrypi.git)
#   META_OE_URL    — meta-openembedded remote  (default: https://github.com/openembedded/meta-openembedded.git)
#   SKIP_APT=1     — skip the apt-get install step (e.g. on non-Debian hosts)
#   AWS_IOT_ENDPOINT — ATS data endpoint for aws-iot.conf (default: AWS CLI lookup)
#   AWS_IOT_THING    — thing name / MQTT client id        (default: AWS CLI lookup)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

POKY_REF="${POKY_REF:-scarthgap}"
META_RPI_REF="${META_RPI_REF:-scarthgap}"
META_OE_REF="${META_OE_REF:-scarthgap}"
POKY_URL="${POKY_URL:-git://git.yoctoproject.org/poky}"
META_RPI_URL="${META_RPI_URL:-https://github.com/agherzan/meta-raspberrypi.git}"
META_OE_URL="${META_OE_URL:-https://github.com/openembedded/meta-openembedded.git}"

# Public Amazon Root CA 1, staged into the aws-iot recipe so the device can
# verify the AWS IoT endpoint. This is a public certificate — not a secret.
AMAZON_ROOT_CA_URL="${AMAZON_ROOT_CA_URL:-https://www.amazontrust.com/repository/AmazonRootCA1.pem}"

# AWS IoT connection identity. These are account-specific, so they live only in
# the generated (gitignored) aws-iot.conf — never in the committed template.
# Left empty here: resolved from the environment or the AWS CLI at setup time.
AWS_IOT_ENDPOINT="${AWS_IOT_ENDPOINT:-}"
AWS_IOT_THING="${AWS_IOT_THING:-}"

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

stage_amazon_root_ca() {
    local dest="$REPO_ROOT/meta-gewgaw/recipes-iot/aws-iot/files/AmazonRootCA1.pem"
    if [[ -s "$dest" ]]; then
        log "Amazon Root CA already staged; leaving it as-is."
        return
    fi
    log "Fetching Amazon Root CA from $AMAZON_ROOT_CA_URL"
    install -d "$(dirname "$dest")"
    wget -qO "$dest" "$AMAZON_ROOT_CA_URL" \
        || die "failed to download Amazon Root CA from $AMAZON_ROOT_CA_URL"
    grep -q "BEGIN CERTIFICATE" "$dest" \
        || { rm -f "$dest"; die "downloaded Amazon Root CA looks invalid"; }
}

generate_aws_iot_conf() {
    local dir="$REPO_ROOT/meta-gewgaw/recipes-iot/aws-iot/files"
    local sample="$dir/aws-iot.conf.sample"
    local dest="$dir/aws-iot.conf"

    [[ -f "$sample" ]] || die "missing $sample"
    if [[ -f "$dest" ]]; then
        log "aws-iot.conf already present; leaving it as-is."
        return
    fi

    # Resolve endpoint/thing: explicit env wins, else ask the AWS CLI (best
    # effort — owner convenience; failures fall back to template placeholders).
    local endpoint="$AWS_IOT_ENDPOINT" thing="$AWS_IOT_THING"
    if [[ -z "$endpoint" ]] && command -v aws >/dev/null 2>&1; then
        endpoint="$(aws iot describe-endpoint --endpoint-type iot:Data-ATS \
            --query endpointAddress --output text 2>/dev/null || true)"
    fi
    if [[ -z "$thing" ]] && command -v aws >/dev/null 2>&1; then
        thing="$(aws iot list-things --max-results 1 \
            --query 'things[0].thingName' --output text 2>/dev/null || true)"
        [[ "$thing" == "None" ]] && thing=""
    fi

    log "Generating aws-iot.conf (endpoint='${endpoint:-<unset>}', thing='${thing:-<unset>}')"
    sed -e "s|__AWS_IOT_ENDPOINT__|${endpoint}|g" \
        -e "s|__AWS_IOT_THING__|${thing}|g" \
        "$sample" > "$dest"

    if [[ -z "$endpoint" || -z "$thing" ]]; then
        log "WARNING: aws-iot.conf has unresolved fields — edit $dest or set"
        log "         AWS_IOT_ENDPOINT / AWS_IOT_THING and re-run, before ./build.sh."
    fi
}

# --- main -----------------------------------------------------------------
install_host_packages
sync_repo "$POKY_URL"     "$POKY_REF"     "$REPO_ROOT/poky"
sync_repo "$META_RPI_URL" "$META_RPI_REF" "$REPO_ROOT/meta-raspberrypi"
sync_repo "$META_OE_URL"  "$META_OE_REF"  "$REPO_ROOT/meta-openembedded"
generate_ssh_key
stage_amazon_root_ca
generate_aws_iot_conf

log "Setup complete. Next: ./build.sh"
