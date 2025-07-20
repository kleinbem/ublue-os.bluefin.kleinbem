# Stage 1: Context for all build-related files (scripts, configs, etc.)
FROM scratch AS ctx
COPY build_files /ctx_data/


# -------------------------------------------------------------
# Stage 2: AKMODS Extractor - Direct Download & Extract .ko files
#          This stage will extract kernel modules and config files from Bazzite's AKMODS.
#          It hardcodes a recent Bazzite kernel version for extraction for reliability.
# -------------------------------------------------------------
FROM fedora:latest AS akmods_extractor # Use a minimal fedora image for skopeo/jq

# Install tools needed to pull and extract AKMODS, plus rpm2cpio
RUN dnf install -y skopeo jq tar gzip rpm-build # rpm-build for rpm2cpio
RUN dnf clean all && rm -rf /var/cache/dnf

# Hardcode a known-good Bazzite kernel version from your skopeo list-tags output.
# Example from your previous output: bazzite-42-6.15.6-103.bazzite.fc42.x86_64
ARG BAZZITE_KERNEL_VERSION="6.15.6-103.bazzite.fc42.x86_64"
ARG UBLUE_AKMODS_IMAGE="ghcr.io/ublue-os/akmods"

# Dynamically construct the AKMODS tag using the hardcoded version
ARG BAZZITE_FEDORA_VERSION="42" # Hardcoded based on fc42
ARG AKMODS_TAG_FOR_BAZZITE="bazzite-${BAZZITE_FEDORA_VERSION}-${BAZZITE_KERNEL_VERSION}"

# Pull the Bazzite AKMODS image
RUN echo "Attempting to pull AKMODS image: ${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}" && \
    mkdir -p /tmp/bazzite_akmods && \
    skopeo copy --retry-times 3 "docker://${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}" "dir:/tmp/bazzite_akmods" \
    || (echo "Warning: Failed to pull AKMODS image ${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}. Modules might be built-in or not available in akmods." && exit 0)

# Extract the RPMs from the tarball within the skopeo-pulled content
RUN AKMODS_TARGZ_DIGEST=$(jq -r '.layers[].digest' </tmp/bazzite_akmods/manifest.json | cut -d : -f 2) \
    && tar -xvzf "/tmp/bazzite_akmods/${AKMODS_TARGZ_DIGEST}" -C "/tmp/bazzite_akmods/"

# Move the rpms/kmods/* content to a central location for easy processing
RUN mkdir -p /extracted_rpms/ \
    && find /tmp/bazzite_akmods/rpms/kmods/ -name "*.rpm" -exec mv {} /extracted_rpms/ \; \
    || true

# Now, extract the .ko files from these kmod RPMs using rpm2cpio
# And copy them to a final destination /final_extracted_modules/ for the main stage.
RUN mkdir -p /final_extracted_modules/ \
    && for rpm in /extracted_rpms/*.rpm; do rpm2cpio "$rpm" | cpio -idmv --quiet; done \
    && cp /usr/lib/modules/${BAZZITE_KERNEL_VERSION}/extra/ashmem_linux.ko /final_extracted_modules/ashmem_linux.ko \
    && cp /usr/lib/modules/${BAZZITE_KERNEL_VERSION}/extra/binder_linux.ko /final_extracted_modules/binder_linux.ko \
    || true # Allow failure if files not found in extracted RPMs (e.g., built-in)


# -------------------------------------------------------------
# Stage 4: Your Main Custom Bluefin-DX Image Build
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bluefin-dx:latest

# Copy your build scripts from the ctx stage
COPY --from=ctx /ctx_data /ctx/build_files

# Copy the extracted .ko modules and config files from previous stages to /tmp/ in the main image.
# NOTE: /tmp/ is used as a staging area. Your build.sh will then copy to final /usr/lib/modules.

# From akmods_extractor (this will create /tmp/extracted_ashmem_linux.ko etc.)
COPY --from=akmods_extractor /final_extracted_modules/ashmem_linux.ko /tmp/extracted_ashmem_linux.ko || true
COPY --from=akmods_extractor /final_extracted_modules/binder_linux.ko /tmp/extracted_binder_linux.ko || true
# Config files are from ctx
COPY --from=ctx /ctx_data/anbox.conf /tmp/anbox.conf || true
COPY --from=ctx /ctx_data/99-anbox.rules /tmp/99-anbox.rules || true


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