# Stage 1: Context for all build-related files (scripts, configs, etc.)
FROM scratch AS ctx
# Copy the entire contents of your local 'build_files' directory into /ctx_data/ in this stage.
COPY build_files /ctx_data/


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


# -------------------------------------------------------------
# Stage 3: AKMODS Extractor (if modules are not found directly in Stage 2)
#          This stage fetches the .ko files from Bazzite's AKMODS registry.
# -------------------------------------------------------------
FROM fedora:latest AS akmods_extractor # Use a minimal fedora image for skopeo/jq

# Install tools needed to pull and extract AKMODS
RUN dnf install -y skopeo jq tar gzip && dnf clean all && rm -rf /var/cache/dnf

# Copy the BAZZITE_KERNEL_VERSION from the bazzite_module_source stage
COPY --from=bazzite_module_source /tmp/bazzite_kernel_version.txt /tmp/bazzite_kernel_version.txt
ARG BAZZITE_KERNEL_VERSION=$(cat /tmp/bazzite_kernel_version.txt)

# Define the AKMODS image and tag structure for Bazzite
ARG UBLUE_AKMODS_IMAGE="ghcr.io/ublue-os/akmods"
ARG BAZZITE_FEDORA_VERSION=$(echo "${BAZZITE_KERNEL_VERSION}" | sed -E 's/.*fc([0-9]+)\.x86_64/\1/')
ARG AKMODS_TAG_FOR_BAZZITE="bazzite-${BAZZITE_FEDORA_VERSION}-${BAZZITE_KERNEL_VERSION}"

# Pull the Bazzite AKMODS image
RUN mkdir -p /tmp/bazzite_akmods \
    && skopeo copy --retry-times 3 "docker://${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}" "dir:/tmp/bazzite_akmods" \
    || (echo "Warning: Failed to pull AKMODS image ${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}. Modules might be built-in or not available in akmods." && exit 0)

# Extract the RPMs from the tarball within the skopeo-pulled content
RUN AKMODS_TARGZ_DIGEST=$(jq -r '.layers[].digest' </tmp/bazzite_akmods/manifest.json | cut -d : -f 2) \
    && tar -xvzf "/tmp/bazzite_akmods/${AKMODS_TARGZ_DIGEST}" -C "/tmp/bazzite_akmods/"

# Move the rpms/kmods/* content to a central location for easy copying
RUN mkdir -p /extracted_modules_from_akmods/ \
    && find /tmp/bazzite_akmods/rpms/kmods/ -name "*.rpm" -exec mv {} /extracted_modules_from_akmods/ \; \
    || true

# Now, extract the .ko files from these kmod RPMs using rpm2cpio
RUN mkdir -p /final_extracted_modules/ \
    && for rpm in /extracted_modules_from_akmods/*.rpm; do rpm2cpio "$rpm" | cpio -idmv; done \
    && cp /usr/lib/modules/${BAZZITE_KERNEL_VERSION}/extra/ashmem_linux.ko /final_extracted_modules/ashmem_linux.ko \
    && cp /usr/lib/modules/${BAZZITE_KERNEL_VERSION}/extra/binder_linux.ko /final_extracted_modules/binder_linux.ko \
    || true


# -------------------------------------------------------------
# Stage 4: Your Main Custom Bluefin-DX Image Build
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bluefin-dx:latest

# Copy your build scripts from the ctx stage
# Corrected: copy /ctx_data (where build_files content is) to /ctx/build_files in this stage.
COPY --from=ctx /ctx_data /ctx/build_files

# Copy the extracted .ko modules and config files from previous stages to /tmp/ in the main image.
# Preference: modules found directly in bazzite_module_source take precedence.
# Corrected SOURCE paths to include /tmp/
COPY --from=bazzite_module_source /tmp/binder_linux.ko /tmp/extracted_binder_linux.ko || true
COPY --from=bazzite_module_source /tmp/ashmem_linux.ko /tmp/extracted_ashmem_linux.ko || true

# Corrected: config files are from /ctx_data/ in ctx stage
COPY --from=ctx /ctx_data/anbox.conf /tmp/anbox.conf || true
COPY --from=ctx /ctx_data/99-anbox.rules /tmp/99-anbox.rules || true

# If not found directly, try from akmods_extractor stage (this will only add if they didn't exist before)
# Corrected SOURCE paths to include /final_extracted_modules/
COPY --from=akmods_extractor /final_extracted_modules/ashmem_linux.ko /tmp/extracted_ashmem_linux.ko || true
COPY --from=akmods_extractor /final_extracted_modules/binder_linux.ko /tmp/extracted_binder_linux.ko || true
# Configs are now handled exclusively from ctx_data, so no need to try from akmods_extractor for them.


# Your original RUN directive, which calls build.sh
# build.sh will find the copied .ko files and config files in /tmp/ and /ctx/build_files/
RUN --mount=type=bind,from=ctx,source=/build_files,target=/ctx/build_files \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build_files/build.sh && \
    ostree container commit
    
### LINTING
## Verify final image and contents are correct.
RUN bootc container lint