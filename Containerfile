# Stage 1: Context for build scripts (always at the top for clarity and common mounts)
FROM scratch AS ctx
COPY build_files /

# -------------------------------------------------------------
# Stage 2: Bazzite Base for Kernel Version & Module Paths
#          This stage is used to determine the *exact* kernel version Bazzite:latest is using
#          and to locate where Waydroid modules (if .ko files) are.
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bazzite:latest AS bazzite_kernel_info

# Determine Bazzite's kernel version and save it to a file
# This is crucial for retrieving the correct AKMODS later.
# We also want to find the exact paths of binder_linux.ko and ashmem_linux.ko
# if they exist as separate files in this base.
RUN BAZZITE_KERNEL_VERSION=$(uname -r) && echo "${BAZZITE_KERNEL_VERSION}" > /tmp/bazzite_kernel_version.txt
RUN find /usr/lib/modules/ -name "binder_linux.ko" -print -quit > /tmp/binder_ko_path.txt || true
RUN find /usr/lib/modules/ -name "ashmem_linux.ko" -print -quit > /tmp/ashmem_ko_path.txt || true
RUN cp /etc/modules-load.d/anbox.conf /tmp/anbox.conf || true
RUN cp /lib/udev/rules.d/99-anbox.rules /tmp/99-anbox.rules || true

# -------------------------------------------------------------
# Stage 3: AKMODS Extractor (if modules are in akmods image)
#          This is the complex part to get the .ko files if not directly found in Stage 2.
#          We need the exact kernel version from Stage 2.
# -------------------------------------------------------------
FROM fedora:latest AS akmods_extractor # Use a minimal fedora image for skopeo/jq

# Install tools needed to pull and extract AKMODS
RUN dnf install -y skopeo jq tar gzip && dnf clean all && rm -rf /var/cache/dnf

# Get the BAZZITE_KERNEL_VERSION from the bazzite_kernel_info stage
COPY --from=bazzite_kernel_info /tmp/bazzite_kernel_version.txt /tmp/bazzite_kernel_version.txt
ARG BAZZITE_KERNEL_VERSION=$(cat /tmp/bazzite_kernel_version.txt)

# Define the AKMODS image and tag structure for Bazzite
ARG UBLUE_AKMODS_IMAGE="ghcr.io/ublue-os/akmods"
# The Bazzite akmods tags typically look like bazzite-42-6.15.6-103.bazzite.fc42.x86_64
ARG BAZZITE_FEDORA_VERSION=$(echo "${BAZZITE_KERNEL_VERSION}" | cut -d'.' -f3 | cut -d'f' -f2 | cut -d'.' -f1) # Extracts 42 from fc42
ARG AKMODS_TAG_FOR_BAZZITE="bazzite-${BAZZITE_FEDORA_VERSION}-${BAZZITE_KERNEL_VERSION}"

# Pull the Bazzite AKMODS image
RUN mkdir -p /tmp/bazzite_akmods \
    && skopeo copy --retry-times 3 "docker://${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}" "dir:/tmp/bazzite_akmods" \
    || (echo "Warning: Failed to pull AKMODS image ${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}. Modules might be built-in or not available in akmods." && exit 0)

# Extract the RPMs from the tarball within the skopeo-pulled content
RUN AKMODS_TARGZ_DIGEST=$(jq -r '.layers[].digest' </tmp/bazzite_akmods/manifest.json | cut -d : -f 2) \
    && tar -xvzf "/tmp/bazzite_akmods/${AKMODS_TARGZ_DIGEST}" -C "/tmp/bazzite_akmods/"

# Move the rpms/kmods/* content to a central location for easy copying
# These are the kmod RPMs themselves, e.g., kmod-anbox-binder-XYZ.rpm
RUN mkdir -p /extracted_modules/kmod_rpms/ \
    && find /tmp/bazzite_akmods/rpms/kmods/ -name "*.rpm" -exec mv {} /extracted_modules/kmod_rpms/ \; \
    || true # Allow if no kmods are found (e.g., if modules are built-in)

# Now, extract the .ko files from these kmod RPMs
# This will unpack the .ko files from the RPMs into standard /usr/lib/modules structure relative to current working dir
RUN for rpm in /extracted_modules/kmod_rpms/*.rpm; do rpm2cpio "$rpm" | cpio -idmv; done \
    || true # Allow if no kmod rpms were moved

# Copy the specific .ko files and config files to /final_extracted_modules/ for main stage to pick up
RUN mkdir -p /final_extracted_modules/ \
    && find /usr/lib/modules/ -name "ashmem_linux.ko" -exec cp {} /final_extracted_modules/ashmem_linux.ko \; \
    && find /usr/lib/modules/ -name "binder_linux.ko" -exec cp {} /final_extracted_modules/binder_linux.ko \; \
    || true # Allow if files not found
# Also copy config files if they exist directly from akmods (less likely)
RUN cp /tmp/bazzite_akmods/anbox.conf /final_extracted_modules/anbox.conf || true
RUN cp /tmp/bazzite_akmods/99-anbox.rules /final_extracted_modules/99-anbox.rules || true

# -------------------------------------------------------------
# Stage 4: Your Main Custom Bluefin-DX Image Build
#          This now only copies the *already located/extracted* files.
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bluefin-dx:latest

# Copy your build scripts from the ctx stage
COPY --from=ctx / build_files/ /ctx/

# Copy kernel modules and config files from either bazzite_kernel_info or akmods_extractor
# Preference for the directly found .ko from bazzite_kernel_info if they exist
COPY --from=bazzite_kernel_info /usr/lib/modules/ /usr/lib/modules/ || true # Copy existing modules if present
COPY --from=bazzite_kernel_info /tmp/anbox.conf /etc/modules-load.d/anbox.conf || true
COPY --from=bazzite_kernel_info /tmp/99-anbox.rules /lib/udev/rules.d/99-anbox.rules || true

# If not found directly, copy from akmods_extractor (this will overwrite if both exist, which is fine)
COPY --from=akmods_extractor /final_extracted_modules/ashmem_linux.ko /usr/lib/modules/$(uname -r)/extra/ashmem_linux.ko || true
COPY --from=akmods_extractor /final_extracted_modules/binder_linux.ko /usr/lib/modules/$(uname -r)/extra/binder_linux.ko || true
COPY --from=akmods_extractor /final_extracted_modules/anbox.conf /etc/modules-load.d/anbox.conf || true
COPY --from=akmods_extractor /final_extracted_modules/99-anbox.rules /lib/udev/rules.d/99-anbox.rules || true


# Your original RUN directive, now calling a modified build.sh
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh && \
    ostree container commit
    
### LINTING
## Verify final image and contents are correct.
RUN bootc container lint