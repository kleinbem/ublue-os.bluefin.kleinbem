# Stage 1: Context for build scripts (always at the top)
FROM scratch AS ctx
COPY build_files /

# -------------------------------------------------------------
# Stage 2: Bazzite Base for Kernel Version & Initial Module Path Check
#          This stage determines the *exact* kernel version Bazzite:latest is using
#          and attempts to find .ko files and config files directly from its base.
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bazzite:latest AS bazzite_kernel_info

# Determine Bazzite's kernel version and save it to a file
RUN BAZZITE_KERNEL_VERSION=$(uname -r) && echo "${BAZZITE_KERNEL_VERSION}" > /tmp/bazzite_kernel_version.txt

# Attempt to find pre-existing .ko files and config files directly in Bazzite base.
# Use || true to prevent stage failure if files aren't found.
# These will be copied to /tmp/<filename> if found.
RUN find /usr/lib/modules/ -name "binder_linux.ko" -exec cp {} /tmp/binder_linux.ko \; || true
RUN find /usr/lib/modules/ -name "ashmem_linux.ko" -exec cp {} /tmp/ashmem_linux.ko \; || true
RUN cp /etc/modules-load.d/anbox.conf /tmp/anbox.conf || true
RUN cp /lib/udev/rules.d/99-anbox.rules /tmp/99-anbox.rules || true


# -------------------------------------------------------------
# Stage 3: AKMODS Extractor (if modules are not found directly in Stage 2)
#          This stage fetches the .ko files from Bazzite's AKMODS registry.
# -------------------------------------------------------------
FROM fedora:latest AS akmods_extractor # Use a minimal fedora image for skopeo/jq

# Install tools needed to pull and extract AKMODS
RUN dnf install -y skopeo jq tar gzip && dnf clean all && rm -rf /var/cache/dnf

# Get the BAZZITE_KERNEL_VERSION from the bazzite_kernel_info stage
COPY --from=bazzite_kernel_info /tmp/bazzite_kernel_version.txt /tmp/bazzite_kernel_version.txt
ARG BAZZITE_KERNEL_VERSION=$(cat /tmp/bazzite_kernel_version.txt)

# Define the AKMODS image and tag structure for Bazzite
ARG UBLUE_AKMODS_IMAGE="ghcr.io/ublue-os/akmods"
# Extracts 42 from fc42, e.g., 6.15.6-103.bazzite.fc42.x86_64 -> 42
ARG BAZZITE_FEDORA_VERSION=$(echo "${BAZZITE_KERNEL_VERSION}" | sed -E 's/.*fc([0-9]+)\.x86_64/\1/')
# Example Bazzite akmods tag: bazzite-42-6.15.6-103.bazzite.fc42.x86_64
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
RUN mkdir -p /extracted_modules_from_akmods/ \
    && find /tmp/bazzite_akmods/rpms/kmods/ -name "*.rpm" -exec mv {} /extracted_modules_from_akmods/ \; \
    || true # Allow if no kmods are found

# Now, extract the .ko files from these kmod RPMs using rpm2cpio
# This unpacks the .ko files into standard /usr/lib/modules structure relative to current working dir.
# We then copy them to /final_extracted_modules for the main stage.
RUN mkdir -p /final_extracted_modules/ \
    && for rpm in /extracted_modules_from_akmods/*.rpm; do rpm2cpio "$rpm" | cpio -idmv; done \
    && cp /usr/lib/modules/${BAZZITE_KERNEL_VERSION}/extra/ashmem_linux.ko /final_extracted_modules/ashmem_linux.ko \
    && cp /usr/lib/modules/${BAZZITE_KERNEL_VERSION}/extra/binder_linux.ko /final_extracted_modules/binder_linux.ko \
    || true # Allow if files not found or cpio/cp fails

# Also copy config files if they exist directly from akmods (less likely)
RUN cp /tmp/bazzite_akmods/anbox.conf /final_extracted_modules/anbox.conf || true
RUN cp /tmp/bazzite_akmods/99-anbox.rules /final_extracted_modules/99-anbox.rules || true


# -------------------------------------------------------------
# Stage 4: Your Main Custom Bluefin-DX Image Build
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bluefin-dx:latest

# Copy your build scripts from the ctx stage
COPY --from=ctx /ctx /ctx # Correct syntax: copy /ctx from ctx stage to /ctx in this stage

# Copy the extracted .ko modules and config files from previous stages
# These will be copied to the /tmp/ of the main image, to be processed by build.sh
# Check preference: modules found directly in bazzite_kernel_info stage take precedence.
COPY --from=bazzite_kernel_info /tmp/binder_linux.ko /tmp/binder_linux.ko || true
COPY --from=bazzite_kernel_info /tmp/ashmem_linux.ko /tmp/ashmem_linux.ko || true
COPY --from=bazzite_kernel_info /tmp/anbox.conf /tmp/anbox.conf || true
COPY --from=bazzite_kernel_info /tmp/99-anbox.rules /tmp/99-anbox.rules || true

# If not found directly, try from akmods_extractor stage (this will only add if they didn't exist before)
COPY --from=akmods_extractor /final_extracted_modules/ashmem_linux.ko /tmp/ashmem_linux.ko || true
COPY --from=akmods_extractor /final_extracted_modules/binder_linux.ko /tmp/binder_linux.ko || true
COPY --from=akmods_extractor /final_extracted_modules/anbox.conf /tmp/anbox.conf || true
COPY --from=akmods_extractor /final_extracted_modules/99-anbox.rules /tmp/99-anbox.rules || true

# Your original RUN directive, which calls build.sh
# build.sh will find the copied .ko files in /tmp/
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh && \
    ostree container commit
    
### LINTING
## Verify final image and contents are correct.
RUN bootc container lint