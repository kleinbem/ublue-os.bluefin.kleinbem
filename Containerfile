# Stage 1: Context for all build-related files (scripts, configs, etc.)
FROM scratch AS ctx
COPY build_files /ctx_data/

# Add an explicit blank line after the stage definition
# -------------------------------------------------------------


# -------------------------------------------------------------
# Stage 2: Bazzite Base for Kernel Version & Direct Module Check
#          This stage determines the *exact* kernel version Bazzite:latest is using
#          and attempts to find .ko files directly within its base filesystem.
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bazzite:latest AS bazzite_module_source

# Get Bazzite's kernel version
RUN BAZZITE_KERNEL_VERSION=$(uname -r) && echo "${BAZZITE_KERNEL_VERSION}" > /tmp/bazzite_kernel_version.txt

# Attempt to find pre-existing .ko files within this base image.
# Use || true to prevent stage failure if files aren't found.
# These will be copied to /tmp/<filename> if found.
RUN find /usr/lib/modules/ -name "binder_linux.ko" -exec cp {} /tmp/binder_linux.ko \; || true
RUN find /usr/lib/modules/ -name "ashmem_linux.ko" -exec cp {} /tmp/ashmem_linux.ko \; || true

# Add an explicit blank line after the stage definition
# -------------------------------------------------------------


# -------------------------------------------------------------
# Stage 3: AKMODS Extractor (if modules are not found directly in Stage 2)
#          This stage fetches the .ko files from Bazzite's AKMODS registry.
# -------------------------------------------------------------
FROM fedora:latest AS akmods_extractor # Use a minimal fedora image for skopeo/jq

# Install tools needed to pull and extract AKMODS
RUN dnf install -y skopeo jq tar gzip rpm-build \
    && dnf clean all && rm -rf /var/cache/dnf

# Copy the BAZZITE_KERNEL_VERSION from the bazzite_module_source stage
COPY --from=bazzite_module_source /tmp/bazzite_kernel_version.txt /tmp/bazzite_kernel_version.txt

# Hardcode the BAZZITE_FEDORA_VERSION as 42, as it's static for Fedora 42
ARG BAZZITE_FEDORA_VERSION="42"

# Pull the Bazzite AKMODS image and extract modules
RUN BAZZITE_KERNEL_VERSION_ACTUAL=$(cat /tmp/bazzite_kernel_version.txt) && \
    AKMODS_TAG_FOR_BAZZITE="bazzite-${BAZZITE_FEDORA_VERSION}-${BAZZITE_KERNEL_VERSION_ACTUAL}" && \
    UBLUE_AKMODS_IMAGE="ghcr.io/ublue-os/akmods" && \
    echo "Attempting to pull AKMODS image: ${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}" && \
    mkdir -p /tmp/bazzite_akmods && \
    skopeo copy --retry-times 3 "docker://${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}" "dir:/tmp/bazzite_akmods" \
    || (echo "Warning: Failed to pull AKMODS image ${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}. Modules might be built-in or not available in akmods." && exit 0) && \
    \
    AKMODS_TARGZ_DIGEST=$(jq -r '.layers[].digest' </tmp/bazzite_akmods/manifest.json | cut -d : -f 2) && \
    tar -xvzf "/tmp/bazzite_akmods/${AKMODS_TARGZ_DIGEST}" -C "/tmp/bazzite_akmods/" && \
    \
    mkdir -p /extracted_rpms/ && \
    find /tmp/bazzite_akmods/rpms/kmods/ -name "*.rpm" -exec mv {} /extracted_rpms/ \; && \
    \
    mkdir -p /final_extracted_modules/ && \
    for rpm in /extracted_rpms/*.rpm; do rpm2cpio "$rpm" | cpio -idmv --quiet; done && \
    cp /usr/lib/modules/${BAZZITE_KERNEL_VERSION_ACTUAL}/extra/ashmem_linux.ko /final_extracted_modules/ashmem_linux.ko \
    && cp /usr/lib/modules/${BAZZITE_KERNEL_VERSION_ACTUAL}/extra/binder_linux.ko /final_extracted_modules/binder_linux.ko \
    || true # Allow failure if files not found in extracted RPMs

# Add an explicit blank line after the stage definition
# -------------------------------------------------------------


# -------------------------------------------------------------
# Stage 4: Your Main Custom Bluefin-DX Image Build
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bluefin-dx:latest

# Copy your build scripts from the ctx stage
COPY --from=ctx /ctx_data /ctx/build_files

# Copy the extracted .ko modules and config files from previous stages to /tmp/ in the main image.
# NOTE: /tmp/ is used as a staging area. Your build.sh will then copy to final /usr/lib/modules.

# Modules from bazzite_module_source (if found