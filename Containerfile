# syntax=docker/dockerfile:1
#
# bootc image: Fedora 45 host that runs the pinned vLLM XPU container (Quadlet)
# on an Intel Arc Pro B70. vLLM, PyTorch-XPU and the GPU user-space stack all
# live in the container; the host only provides the xe kernel driver + /dev/dri.
#
# Build:  ./build.sh
# Deploy: bootc switch <registry>/bootc-vllm-xpu:latest

# Git ref of SergiioB/intel-arc-pro-b70-inference-cookbook to take the MTP patches
# from. The patches target the pinned vLLM image digest in quadlet/vllm.container,
# so bump both together.
ARG COOKBOOK_REF=master

# ---------------------------------------------------------------------------
# Stage 1: fetch the B70 MTP patches
# ---------------------------------------------------------------------------
FROM registry.fedoraproject.org/fedora:45 AS patches

ARG COOKBOOK_REF

RUN dnf install -y --setopt=install_weak_deps=False git && dnf clean all
RUN git clone https://github.com/SergiioB/intel-arc-pro-b70-inference-cookbook.git /cookbook \
    && cd /cookbook \
    && git checkout "${COOKBOOK_REF}" \
    && test -f patches/patch_mtp_nightly.py \
    && test -f patches/patch_mtp_boundary.py

# ---------------------------------------------------------------------------
# Stage 2: final (bootc-bootable)
# ---------------------------------------------------------------------------
FROM quay.io/fedora/fedora-bootc:45 AS final

LABEL containers.bootc=1 \
      org.opencontainers.image.title="bootc-vllm-xpu" \
      org.opencontainers.image.description="Fedora 45 bootc image: vLLM XPU (Quadlet) for Intel Arc Pro B70"

# Diagnostics + model download (`hf`). podman ships in the base.
RUN dnf install -y --setopt=install_weak_deps=False \
        python3-huggingface-hub \
        intel-gpu-tools \
    && dnf clean all

COPY --from=patches /cookbook/patches/patch_mtp_nightly.py  /usr/share/vllm-xpu/patches/patch_mtp_nightly.py
COPY --from=patches /cookbook/patches/patch_mtp_boundary.py /usr/share/vllm-xpu/patches/patch_mtp_boundary.py
COPY --chmod=0755 libexec/vllm-xpu-entrypoint /usr/libexec/vllm-xpu-entrypoint

COPY quadlet/vllm.container /usr/share/containers/systemd/vllm.container
COPY quadlet/vllm.env       /usr/share/vllm-xpu/vllm.env
RUN mkdir -p /etc/vllm \
    && [ -f /etc/vllm/vllm.env ] || cp /usr/share/vllm-xpu/vllm.env /etc/vllm/vllm.env

COPY tmpfiles.d/vllm.conf /usr/lib/tmpfiles.d/vllm.conf
COPY --chmod=0440 sudoers.d/wheel-passwordless-sudo /etc/sudoers.d/wheel-passwordless-sudo

RUN rm -rf /var/cache/* /var/log/* /var/tmp/* /var/lib/dnf/* /tmp/* /run/dnf

RUN bootc container lint
