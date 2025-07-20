# Your existing ctx stage
FROM scratch AS ctx
COPY build_files /

# -------------------------------------------------------------
# NEW STAGE: Extract Waydroid kernel modules from Bazzite's AKMODS image
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bazzite:latest AS bazzite_base_for_kernel_version_info # We use this to get the *exact* Bazzite kernel version

# This determines the precise kernel version of the bazzite:latest image
ARG BAZZITE_KERNEL_VERSION
RUN BAZZITE_KERNEL_VERSION=$(uname -r) && echo ${BAZZITE_KERNEL_VERSION} > /tmp/bazzite_kernel_version.txt

# This is where we will fetch the AKMODS (including binder_linux/ashmem_linux)
FROM fedora:latest AS akmods_extractor # Use a minimal fedora image for skopeo/jq

# Install tools needed to pull and extract AKMODS
RUN dnf install -y skopeo jq tar gzip && dnf clean all && rm -rf /var/cache/dnf

# Get the BAZZITE_KERNEL_VERSION from the previous stage
COPY --from=bazzite_base_for_kernel_version_info /tmp/bazzite_kernel_version.txt /tmp/bazzite_kernel_version.txt
ARG BAZZITE_KERNEL_VERSION=$(cat /tmp/bazzite_kernel_version.txt)

# Define the AKMODS image and tag structure for Bazzite
ARG UBLUE_AKMODS_IMAGE="ghcr.io/ublue-os/akmods"
# The Bazzite akmods tags typically look like bazzite-42-6.15.6-103.bazzite.fc42.x86_64
ARG AKMODS_TAG_FOR_BAZZITE="bazzite-$(rpm -E %fedora)-${BAZZITE_KERNEL_VERSION}"

# Pull the Bazzite AKMODS image
RUN mkdir -p /tmp/bazzite_akmods \
    && skopeo copy --retry-times 3 "docker://${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}" "dir:/tmp/bazzite_akmods"

# Extract the RPMs (which contain the .ko files)
# The tarball within the akmods image contains the actual RPMs.
RUN AKMODS_TARGZ_DIGEST=$(jq -r '.layers[].digest' </tmp/bazzite_akmods/manifest.json | cut -d : -f 2) \
    && tar -xvzf "/tmp/bazzite_akmods/${AKMODS_TARGZ_DIGEST}" -C "/tmp/bazzite_akmods/"

# Move the rpms/kmods/* content to a central location for easy copying
RUN mkdir -p /extracted_modules/ko_files/ \
    && mv /tmp/bazzite_akmods/rpms/kmods/* /extracted_modules/ko_files/ \
    && rm -rf /tmp/bazzite_akmods/rpms/kmods/

# Find and copy the specific kernel modules (binder_linux.ko, ashmem_linux.ko)
# They are typically part of a kmod-anbox or kmod-waydroid RPM, but might be direct.
# Let's search by name within the extracted kmods.
RUN find /extracted_modules/ko_files/ -name "kmod-*-${BAZZITE_KERNEL_VERSION}-*rpm" | xargs -I {} rpm2cpio {} | cpio -idmv \
    && cp /usr/lib/modules/${BAZZITE_KERNEL_VERSION}/extra/ashmem_linux.ko /extracted_modules/ \
    && cp /usr/lib/modules/${BAZZITE_KERNEL_VERSION}/extra/binder_linux.ko /extracted_modules/

# Copy configuration files for Waydroid (if they exist directly in Bazzite base)
# These are typically in the base Bazzite image, not the akmods.
# We'll need to manually copy these in the main image's build.sh if they are not part of akmods.
# For now, let's assume the .ko files are sufficient.

# -------------------------------------------------------------
# Your main custom Bluefin-DX image build
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bluefin-dx:latest

# Copy your build scripts
COPY --from=ctx / build_files/ /ctx/ # Copy build_files into /ctx

# Copy pre-compiled modules from the akmods_extractor stage
# These are the actual .ko files we extracted.
COPY --from=akmods_extractor /extracted_modules/binder_linux.ko /tmp/extracted_binder_linux.ko
COPY --from=akmods_extractor /extracted_modules/ashmem_linux.ko /tmp/extracted_ashmem_linux.ko

# Your original RUN directive, now calling a modified build.sh
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh && \
    ostree container commit

# ... (rest of your Containerfile) ...