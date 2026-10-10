#!/bin/bash
# build.sh — Build the bootc-vllm-xpu image (Fedora 45)
# Usage:
#   ./build.sh                                          # Build image (local only)
#   ./build.sh --registry registry.example.com --push  # Build + push to registry
#   ./build.sh --cookbook-ref <sha>                     # Pin the MTP patch source

set -euo pipefail

[[ -f "${BASH_SOURCE[0]%/*}/.env" ]] && source "${BASH_SOURCE[0]%/*}/.env"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-bootc-vllm-xpu}"
REGISTRY="${REGISTRY:-}"
PUSH=false
PLATFORM="${PLATFORM:-linux/amd64}"
COOKBOOK_REF="${COOKBOOK_REF:-master}"
DATE_TAG=$(date +%Y%m%d)

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --registry HOST       Registry hostname (e.g. registry.internal)
  --push                Push image to registry after build
  --platform PLAT       Target platform (default: linux/amd64)
  --name NAME           Image name (default: bootc-vllm-xpu)
  --cookbook-ref REF    intel-arc-pro-b70-inference-cookbook ref for MTP patches (default: master)
  -h, --help            Show this help

Tags applied: f45-DATE_TAG (f45-${DATE_TAG}), f45 and 'latest'
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry) REGISTRY="$2"; shift 2 ;;
        --push) PUSH=true; shift ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --name) IMAGE_NAME="$2"; shift 2 ;;
        --cookbook-ref) COOKBOOK_REF="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -n "$REGISTRY" ]]; then
    IMAGE_REF="${REGISTRY}/${IMAGE_NAME}"
else
    IMAGE_REF="localhost/${IMAGE_NAME}"
fi
TAGS=("f45-${DATE_TAG}" "f45" "latest")

echo "=== bootc-vllm-xpu build ==="
echo "  Fedora:     45"
echo "  Platform:   ${PLATFORM}"
echo "  Cookbook:   ${COOKBOOK_REF}"
echo "  Image:      ${IMAGE_REF}"
echo "  Tags:       ${TAGS[*]}"
echo "  Push:       ${PUSH}"
echo ""

TAG_ARGS=()
for tag in "${TAGS[@]}"; do TAG_ARGS+=(-t "${IMAGE_REF}:${tag}"); done

podman build \
    --platform "${PLATFORM}" \
    --build-arg "COOKBOOK_REF=${COOKBOOK_REF}" \
    "${TAG_ARGS[@]}" \
    "${SCRIPT_DIR}"

echo ""
echo "=== Build complete ==="

if [[ "$PUSH" == true ]]; then
    if [[ -z "$REGISTRY" ]]; then
        echo "ERROR: --push requires --registry"
        exit 1
    fi
    echo "=== Pushing to ${REGISTRY} ==="
    for tag in "${TAGS[@]}"; do
        podman push "${IMAGE_REF}:${tag}"
        echo "  Pushed ${IMAGE_REF}:${tag}"
    done
fi

echo "=== Done ==="
