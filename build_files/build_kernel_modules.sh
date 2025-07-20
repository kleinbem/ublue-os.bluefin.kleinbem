#!/bin/bash
set -euxo pipefail # Strict error checking, unbound variables, echoing commands

echo "Starting build_kernel_modules.sh - Performing all kernel module extraction and setup."

# --- Configuration (for Waydroid and extraction) ---
REQUIRED_MODULES=(
    "binder_linux"
    "ashmem_linux"
)
ANBOX_MODULES_REPO_URL="https://github.com/choff/anbox-modules.git" # For config files
ANBOX_MODULES_REPO_COMMIT="" # Or your specific compatible commit hash for Linux 6.15.x

UBLUE_AKMODS_IMAGE="ghcr.io/ublue-os/akmods"

# Hardcode a known-good Bazzite kernel version for extraction.
# This will be used to pull the correct akmods image.
# Example from your previous skopeo list-tags output.
BAZZITE_KERNEL_VERSION_FOR_EXTRACTION="6.15.6-103.bazzite.fc42.x86_64"
BAZZITE_FEDORA_VERSION_FOR_EXTRACTION="42" # From fc42 in the kernel version
AKMODS_TAG_FOR_BAZZITE="bazzite-${BAZZITE_FEDORA_VERSION_FOR_EXTRACTION}-${BAZZITE_KERNEL_VERSION_FOR_EXTRACTION}"


# --- Functions ---

check_modules_present() {
    local modules_missing=false
    local current_running_kernel=$(uname -r)
    echo "  (Internal) Current running kernel for modprobe check: ${current_running_kernel}"

    if ! modprobe -n binder_linux &>/dev/null; then
        echo "  - binder_linux module not found."
        modules_missing=true
    else
        echo "  - binder_linux module found."
    fi

    if ! modprobe -n ashmem_linux &>/dev/null; then
        echo "  - ashmem_linux module not found."
        modules_missing=true
    else
        echo "  - ashmem_linux module found."
    fi
    echo "${modules_missing}"
}

# --- Main Logic ---

# 0. Check if all required modules are already present (on the bluefin-dx kernel)
echo "Checking if all required kernel modules are already available on current system..."
MODULES_STILL_MISSING=$(check_modules_present)

if [ "${MODULES_STILL_MISSING}" = "false" ]; then
    echo "All required kernel modules are present. Skipping module build/copy process."
    echo "build_kernel_modules.sh finished (skipped)."
    exit 0
fi

echo "One or more kernel modules are missing. Proceeding with module extraction and installation."

# -------------------------------------------------------------
# 1. Install temporary tools needed for extraction
# -------------------------------------------------------------
echo "Installing temporary tools: skopeo, jq, tar, gzip, rpm-build..."
dnf5 install -y skopeo jq tar gzip rpm-build
echo "Temporary tools installed."

# -------------------------------------------------------------
# 2. Extract .ko files from Bazzite AKMODS image
# -------------------------------------------------------------
echo "Fetching Bazzite AKMODS image: ${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}"
KERNEL_RPM_DIR="/tmp/bazzite_akmods_content"
mkdir -p "${KERNEL_RPM_DIR}"

skopeo copy --retry-times 3 "docker://${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}" "dir:${KERNEL_RPM_DIR}" \
    || (echo "CRITICAL ERROR: Failed to pull AKMODS image ${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}. Cannot proceed with module extraction." && exit 1)

echo "Extracting RPMs from pulled AKMODS content..."
AKMODS_TARGZ_DIGEST=$(jq -r '.layers[].digest' <"${KERNEL_RPM_DIR}/manifest.json" | cut -d : -f 2)
tar -xvzf "${KERNEL_RPM_DIR}/${AKMODS_TARGZ_DIGEST}" -C "${KERNEL_RPM_DIR}"/

# Move the rpms/kmods/* content to a central location for processing
echo "Moving extracted kmod RPMs for processing..."
EXTRACTED_RPMS_DIR="${KERNEL_RPM_DIR}/extracted_rpms"
mkdir -p "${EXTRACTED_RPMS_DIR}"
find "${KERNEL_RPM_DIR}/rpms/kmods/" -name "*.rpm" -exec mv {} "${EXTRACTED_RPMS_DIR}/" \; \
    || (echo "Warning: No kmod RPMs found in ${KERNEL_RPM_DIR}/rpms/kmods/" || true)
echo "kmod RPMs moved."

# Now, extract the .ko files from these kmod RPMs using rpm2cpio
# Modules should be extracted to /usr/lib/modules/<kernel_version>/extra/
# We need to manually set the target path for cpio or copy after extraction.
# We will extract to a temporary location and then copy specific .ko files.
TEMP_KO_EXTRACT_DIR="/tmp/temp_ko_extract"
mkdir -p "${TEMP_KO_EXTRACT_DIR}"

echo "Extracting .ko files from kmod RPMs using rpm2cpio..."
for rpm in "${EXTRACTED_RPMS_DIR}"/*.rpm; do
    echo "  - Processing RPM: $(basename "$rpm")"
    rpm2cpio "$rpm" | cpio -idmv --quiet -D "${TEMP_KO_EXTRACT_DIR}" \
    || (echo "Warning: Failed to extract modules from $(basename "$rpm")." || true)
done
echo ".ko files extracted to temporary directory."

# -------------------------------------------------------------
# 3. Copy the extracted .ko files and config files to final /usr/lib/modules/ location
# -------------------------------------------------------------
TARGET_RUNNING_KERNEL_VERSION=$(uname -r) # Get the actual running kernel of the Bluefin image
MODULE_FINAL_DEST_DIR="/usr/lib/modules/${TARGET_RUNNING_KERNEL_VERSION}/extra"
mkdir -p "${MODULE_FINAL_DEST_DIR}"

echo "Copying extracted .ko files to final destination: ${MODULE_FINAL_DEST_DIR}..."
cp "${TEMP_KO_EXTRACT_DIR}/usr/lib/modules/${BAZZITE_KERNEL_VERSION_FOR_EXTRACTION}/extra/ashmem_linux.ko" "${MODULE_FINAL_DEST_DIR}/" \
    || (echo "ERROR: Failed to copy ashmem_linux.ko to final location!" && exit 1)
cp "${TEMP_KO_EXTRACT_DIR}/usr/lib/modules/${BAZZITE_KERNEL_VERSION_FOR_EXTRACTION}/extra/binder_linux.ko" "${MODULE_FINAL_DEST_DIR}/" \
    || (echo "ERROR: Failed to copy binder_linux.ko to final location!" && exit 1)
echo ".ko files copied."

# Copy Anbox configuration files (from /ctx/build_files/ where Containerfile copied them)
echo "Copying Anbox configuration files..."
cp /ctx/build_files/anbox.conf /etc/modules-load.d/anbox.conf \
    || (echo "ERROR: Failed to copy anbox.conf!" && exit 1)
cp /ctx/build_files/99-anbox.rules /lib/udev/rules.d/99-anbox.rules \
    || (echo "ERROR: Failed to copy 99-anbox.rules!" && exit 1)
echo "Config files copied."

# -------------------------------------------------------------
# 4. Update kernel module dependencies
# -------------------------------------------------------------
echo "Running depmod -a..."
depmod -a "${TARGET_RUNNING_KERNEL_VERSION}"
echo "depmod complete."

# -------------------------------------------------------------
# 5. Cleanup temporary tools and extracted content
# -------------------------------------------------------------
echo "Cleaning up temporary files and tools..."
dnf5 remove -y skopeo jq tar gzip rpm-build || true
rm -rf "${KERNEL_RPM_DIR}" "${TEMP_KO_EXTRACT_DIR}"
echo "Cleanup complete."

echo "build_kernel_modules.sh finished (completed module extraction and installation)."