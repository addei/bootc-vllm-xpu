#!/bin/bash
# create-disk-image.sh — Create a bootable disk image (qcow2/raw/iso) via bootc-image-builder
# Usage:
#   ./create-disk-image.sh                          # qcow2 for QEMU testing
#   ./create-disk-image.sh --type raw               # Raw disk image for VMs
#   ./create-disk-image.sh --type iso               # ISO installer for bare metal
#
# Intel GPU hosts are x86_64; images are built for linux/amd64.

set -euo pipefail

# Source project config if present
[[ -f "${BASH_SOURCE[0]%/*}/.env" ]] && source "${BASH_SOURCE[0]%/*}/.env"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-bootc-vllm-xpu}"
REGISTRY="${REGISTRY:-}"
if [[ -n "$REGISTRY" ]]; then
    IMAGE_REF="${REGISTRY}/${IMAGE_NAME}:latest"
else
    IMAGE_REF="localhost/${IMAGE_NAME}:latest"
fi
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
IMAGE_TYPE="${IMAGE_TYPE:-qcow2}"
CONFIG_FILE="${CONFIG_FILE:-}"
TARGET_ARCH="${TARGET_ARCH:-linux/amd64}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create a bootable disk image from the bootc-vllm-xpu container.
bootc-image-builder pulls the image directly from the registry (or local store).

Options:
  --type TYPE         Image type: qcow2 (default), raw, or iso
  --platform PLAT     Target platform (default: linux/amd64)
  --config FILE       Path to config.toml for user/fs customizations
  --image REF         Full image reference (default: \$REGISTRY/\$IMAGE_NAME:latest)
  --output DIR        Output directory (default: ./output)
  -h, --help          Show this help

Examples:
  $(basename "$0")                          # qcow2 for QEMU testing
  $(basename "$0") --type raw               # Raw disk image for VMs
  $(basename "$0") --type iso               # ISO for bare-metal install
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type) IMAGE_TYPE="$2"; shift 2 ;;
        --platform) TARGET_ARCH="$2"; shift 2 ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --image) IMAGE_REF="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Auto-detect config.toml if not specified
if [[ -z "$CONFIG_FILE" && -f "${SCRIPT_DIR}/config.toml" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/config.toml"
fi

# Validate image type
case "$IMAGE_TYPE" in
    qcow2|raw|iso) ;;
    *) echo "ERROR: Unsupported type '${IMAGE_TYPE}'. Use: qcow2, raw, or iso"; exit 1 ;;
esac

echo "=== bootc-vllm-xpu disk image creation ==="
echo "  Source:  ${IMAGE_REF}"
echo "  Type:    ${IMAGE_TYPE}"
echo "  Arch:    ${TARGET_ARCH}"
echo "  Config:  ${CONFIG_FILE:-none}"
echo "  Output:  ${OUTPUT_DIR}"
echo ""

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

echo "=== Building ${IMAGE_TYPE} image ==="
echo ""

# bootc-image-builder no longer pulls images itself; it reads the local
# (root) podman store. Ensure the source image is present there first.
# (Run 'sudo podman login <registry>' once if this fails on a private registry.)
if ! sudo podman image exists "${IMAGE_REF}"; then
    echo "    Pulling ${IMAGE_REF} into root's store..."
    sudo podman pull "${IMAGE_REF}"
fi
echo ""

# --- Run bootc-image-builder ---
# Registry auth passed via containers auth.json; SELinux :Z on volume mounts.
AUTH_MOUNT=""
for f in /run/containers/0/auth.json \
         "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json" \
         "$HOME/.config/containers/auth.json"; do
    if [[ -f "$f" ]]; then
        AUTH_MOUNT="-v ${f}:/run/containers/0/auth.json:ro,Z"
        break
    fi
done

# Config file mount
CONFIG_MOUNT=""
if [[ -n "${CONFIG_FILE}" && -f "${CONFIG_FILE}" ]]; then
    CONFIG_MOUNT="-v ${CONFIG_FILE}:/config.toml:ro,Z"
fi

# Target arch flag
ARCH_FLAG=""
if [[ -n "${TARGET_ARCH}" ]]; then
    ARCH_FLAG="--target-arch ${TARGET_ARCH#*/}"
fi

sudo podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    --pull=newer \
    -v "${OUTPUT_DIR}":/output:Z \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    ${AUTH_MOUNT} \
    ${CONFIG_MOUNT} \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type "${IMAGE_TYPE}" \
    --rootfs ext4 \
    ${ARCH_FLAG} \
    "${IMAGE_REF}"

# --- Locate output file ---
DISK_IMAGE=$(find "${OUTPUT_DIR}" -type f \( -name "disk.*" -o -name "*.iso" \) | head -1)

if [[ ! -f "$DISK_IMAGE" ]]; then
    echo "ERROR: Disk image not found in ${OUTPUT_DIR}"
    exit 1
fi

echo ""
echo "=== Disk image created ==="
echo "  File: ${DISK_IMAGE}"
echo "  Size: $(du -h "${DISK_IMAGE}" | cut -f1)"

if [[ "$IMAGE_TYPE" == "qcow2" ]]; then
    echo ""
    echo "To test with QEMU (GPU passthrough required for inference):"
    echo "  qemu-system-x86_64 -m 32768 -cpu host -enable-kvm -nographic \\"
    echo "    -drive file=${DISK_IMAGE},format=qcow2 \\"
    echo "    -nic user,hostfwd=tcp::2222-:22,hostfwd=tcp::8000-:8000"
    echo ""
    echo "  ssh -p 2222 <user>@localhost"
fi
