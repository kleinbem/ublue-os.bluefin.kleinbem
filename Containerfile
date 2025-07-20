# Stage 1: Context for all build-related files (scripts, configs, etc.)
# Copy the entire contents of your local 'build_files' directory into /ctx_data/ in this stage.
FROM scratch AS ctx
COPY build_files /ctx_data/ # Correct source path: 'build_files' is relative to local repo root


# -------------------------------------------------------------
# Stage 2: Bazzite Kernel Info - Get Bazzite's precise kernel version
#          This stage is purely for figuring out what kernel bazzite:latest uses.
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bazzite:latest AS bazzite_kernel_info

# Get Bazzite's kernel version and save it to a file.
RUN KERNEL_VERSION_FOR_BAZZITE=$(uname -r) && echo "${KERNEL_VERSION_FOR_BAZZITE}" > /tmp/kernel_version_bazzite.txt

# Attempt to find pre-existing .ko files within this base image.
# Use || true to prevent stage failure if files aren't found.
# These will be copied to /tmp/<filename> if found.
RUN find /usr/lib/modules/ -name "binder_linux.ko" -exec cp {} /tmp/binder_linux.ko \; || true
RUN find /usr/lib/modules/ -name "ashmem_linux.ko" -exec cp {} /tmp/ashmem_linux.ko \; || true


# -------------------------------------------------------------
# Stage 3: AKMODS Extractor - Pull and extract .ko files from Bazzite's AKMODS image
#          This stage will use skopeo to get the pre-compiled kernel modules.
# -------------------------------------------------------------
FROM fedora:latest AS akmods_extractor # Use a minimal fedora image with necessary tools

# Install tools needed for skopeo and RPM extraction
RUN dnf install -y skopeo jq tar gzip rpm-build \
    && dnf clean all && rm -rf /var/cache/dnf

# Copy the Bazzite kernel version from Stage 2.
COPY --from=bazzite_kernel_info /tmp/kernel_version_bazzite.txt /tmp/kernel_version_bazzite.txt

# Dynamically set variables and execute skopeo within a single RUN command
# This avoids ARG parsing issues and ensures values are available for commands.
RUN KERNEL_VERSION_FOR_BAZZITE=$(cat /tmp/kernel_version_bazzite.txt) && \
    BAZZITE_FEDORA_VERSION=$(echo "${KERNEL_VERSION_FOR_BAZZITE}" | sed -E 's/.*fc([0-9]+)\.x86_64/\1/') && \
    AKMODS_TAG_FOR_BAZZITE="bazzite-${BAZZITE_FEDORA_VERSION}-${KERNEL_VERSION_FOR_BAZZITE}" && \
    UBLUE_AKMODS_IMAGE="ghcr.io/ublue-os/akmods" && \
    \
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
    # Now, extract the .ko files from these kmod RPMs using rpm2cpio
    # And copy them to a final destination /final_extracted_modules/ for the main stage.
    mkdir -p /final_extracted_modules/usr/lib/modules/${KERNEL_VERSION_FOR_BAZZITE}/extra/ && \
    for rpm in /extracted_rpms/*.rpm; do rpm2cpio "$rpm" | cpio -idmv --quiet --to-stdout | tar x -C /final_extracted_modules/; done \
    && cp /final_extracted_modules/usr/lib/modules/${KERNEL_VERSION_FOR_BAZZITE}/extra/ashmem_linux.ko /final_extracted_modules/ashmem_linux.ko \
    && cp /final_extracted_modules/usr/lib/modules/${KERNEL_VERSION_FOR_BAZZITE}/extra/binder_linux.ko /final_extracted_modules/binder_linux.ko \
    || true


# -------------------------------------------------------------
# Stage 4: Your Main Custom Bluefin-DX Image Build
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bluefin-dx:latest

# Copy your build scripts from the ctx stage
COPY --from=ctx /ctx_data /ctx/build_files

# Copy the extracted .ko modules and config files from previous stages to /tmp/ in the main image.
# NOTE: /tmp/ is used as a staging area. Your build.sh will then copy to final /usr/lib/modules.

# Modules from bazzite_module_source (if found directly in base)
COPY --from=bazzite_module_source /tmp/binder_linux.ko /tmp/extracted_binder_linux.ko || true
COPY --from=bazzite_module_source /tmp/ashmem_linux.ko /tmp/extracted_ashmem_linux.ko || true

# Config files from ctx stage (where they are copied from your local build_files/)
COPY --from=ctx /ctx_data/anbox.conf /tmp/anbox.conf || true
COPY --from=ctx /ctx_data/99-anbox.rules /tmp/99-anbox.rules || true

# If not found directly, try from akmods_extractor stage (this will only add if they didn't exist before)
COPY --from=akmods_extractor /final_extracted_modules/ashmem_linux.ko /tmp/extracted_ashmem_linux.ko || true
COPY --from=akmods_extractor /final_extracted_modules/binder_linux.ko /tmp/extracted_binder_linux.ko || true


# Your main RUN directive, which calls build.sh
RUN --mount=type=bind,from=ctx,source=/ctx/build_files,target=/ctx/build_files \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build_files/build.sh && \
    ostree container commit
    
### LINTING
## Verify final image and contents are correct.
RUN bootc container lint