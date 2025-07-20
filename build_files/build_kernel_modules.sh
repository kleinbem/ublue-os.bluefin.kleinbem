#!/bin/bash
set -euxo pipefail

echo "Starting build_kernel_modules.sh - Checking and potentially building kernel modules."

# -------------------------------------------------------------
# 1. Determine the exact kernel version of the base image (MUST BE FIRST)
# -------------------------------------------------------------
TARGET_KERNEL_VERSION=$(uname -r)
echo "Target Kernel Version detected: ${TARGET_KERNEL_VERSION}"


# --- Configuration ---
REQUIRED_MODULES=(
    "binder_linux"
    "ashmem_linux"
)
ANBOX_SOURCE_DIRS=(
    "binder"
    "ashmem"
)
DKMS_MODULE_NAMES=(
    "anbox-binder"
    "anbox-ashmem"
)
DKMS_MODULE_VERSIONS=(
    "1"
    "1"
)

# Common build dependencies for kernel modules (re-including skopeo and jq)
COMMON_BUILD_DEPS=(
    git
    make
    gcc
    dkms
    skopeo # <-- Need skopeo to pull the akmods image
    jq     # <-- Need jq to parse manifest.json
)

# Universal Blue's AKMODS image for fetching kernel-devel
UBLUE_AKMODS_IMAGE="ghcr.io/ublue-os/akmods"
# **CRITICAL:** Hardcode a known-good, *generic* Fedora 42 kernel tag from the akmods list.
# This kernel-devel will be used for compilation, hoping it's ABI-compatible with TARGET_KERNEL_VERSION.
# Pick the highest 'main-42' kernel from your 'skopeo list-tags' output.
AKMODS_TAG_FOR_KERNEL_DEVEL="main-42-6.15.6-200.fc42.x86_64" # <-- Adjust this to the *absolute latest* 'main-42' kernel tag you see.

ANBOX_MODULES_REPO_URL="https://github.com/choff/anbox-modules.git"
ANBOX_MODULES_REPO_COMMIT="" # Or your specific compatible commit hash for this kernel

# --- Functions ---

check_modules_present() {
    local modules_missing=false
    for module in "${REQUIRED_MODULES[@]}"; do
        if ! modprobe -n "${module}" &>/dev/null; then
            echo "  - ${module} module not found."
            modules_missing=true
        else
            echo "  - ${module} module found."
        fi
    done
    echo "${modules_missing}"
}

install_temp_build_deps() {
    echo "Installing temporary build dependencies for kernel modules (including skopeo and jq)..."
    rpm-ostree install --apply-live --allow-inactive "${COMMON_BUILD_DEPS[@]}"
    echo "Temporary build dependencies installed."
}

remove_temp_build_deps() {
    echo "Cleaning up temporary build dependencies..."
    # We will remove COMMON_BUILD_DEPS and also the specific kernel-devel package
    # for the kernel we pulled.
    rpm-ostree override remove "${COMMON_BUILD_DEPS[@]}" \
        "kernel-devel-${KERNEL_VERSION_FROM_AKMODS_TAG}" \
        || true
    echo "Temporary build dependencies cleaned up."
}

# --- Main Logic ---

# 0. Check if all required modules are already present
echo "Checking if all required kernel modules are already available..."
MODULES_STILL_MISSING=$(check_modules_present)

if [ "${MODULES_STILL_MISSING}" = "false" ]; then
    echo "All required kernel modules are already present. Skipping module build process."
    echo "build_kernel_modules.sh finished (skipped)."
    exit 0
fi

echo "One or more kernel modules are missing. Proceeding with full module build."

# KERNEL_SOURCE_DIR definition will be based on the kernel-devel we *pull and install*
KERNEL_SOURCE_DIR_FOR_BUILD="" # This will be set after installing the devel RPM

# 2. Temporarily install general build tools (NOW INCLUDING SKOPEO & JQ)
install_temp_build_deps

# 2a. Fetch and Install a specific kernel-devel RPM from UBlue's akmods
echo "Fetching and installing specific kernel-devel RPM using skopeo for AKMODS_TAG: ${AKMODS_TAG_FOR_KERNEL_DEVEL}..."
KERNEL_RPM_DIR="/tmp/akmods_kernel_rpms"
mkdir -p "${KERNEL_RPM_DIR}"

skopeo copy --retry-times 3 "docker://${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_KERNEL_DEVEL}" "dir:${KERNEL_RPM_DIR}"

# Extract the RPMs (especially kernel-devel)
AKMODS_TARGZ_DIGEST=$(jq -r '.layers[].digest' <"${KERNEL_RPM_DIR}/manifest.json" | cut -d : -f 2)
tar -xvzf "${KERNEL_RPM_DIR}/${AKMODS_TARGZ_DIGEST}" -C "${KERNEL_RPM_DIR}"/

if [ -d "${KERNEL_RPM_DIR}/rpms" ]; then
    mv "${KERNEL_RPM_DIR}/rpms"/* "${KERNEL_RPM_DIR}/"
fi

# Determine the kernel version from the AKMODS tag to install the specific devel package
# Example: "main-42-6.15.6-200.fc42.x86_64" -> "6.15.6-200.fc42.x86_64"
# This might need adjustment depending on the exact AKMODS_TAG_FOR_KERNEL_DEVEL format
KERNEL_VERSION_FROM_AKMODS_TAG=$(echo "${AKMODS_TAG_FOR_KERNEL_DEVEL}" | sed -E 's/^(main|coreos-stable|bazzite|surface)-[0-9]+-(.*)$/\2/')

# Install the specific kernel-devel RPM
echo "Installing kernel-devel RPM: ${KERNEL_RPM_DIR}/kernel-devel-${KERNEL_VERSION_FROM_AKMODS_TAG}.rpm"
dnf5 install -y "${KERNEL_RPM_DIR}/kernel-devel-${KERNEL_VERSION_FROM_AKMODS_TAG}.rpm"
echo "Specific kernel-devel RPM for AKMODS_TAG installed."

# Set the KERNEL_SOURCE_DIR for DKMS build to match the installed devel package
KERNEL_SOURCE_DIR="/usr/src/kernels/${KERNEL_VERSION_FROM_AKMODS_TAG}"
echo "DKMS will use kernel source directory: ${KERNEL_SOURCE_DIR}"


# >>> Verify kernel source directory *after* installation <<<
echo "Verifying kernel source directory contents AFTER kernel-devel installation:"
ls -l "${KERNEL_SOURCE_DIR}" || true
if [ ! -d "${KERNEL_SOURCE_DIR}" ] || [ -z "$(ls -A "${KERNEL_SOURCE_DIR}")" ]; then
    echo "CRITICAL ERROR: Kernel source directory ${KERNEL_SOURCE_DIR} is still empty or does NOT exist after attempting installation!"
    echo "This indicates a fundamental issue with kernel-devel package extraction. Cannot proceed."
    exit 1 # Exit with error, as this is unrecoverable without headers
fi

# >>> Create the expected DKMS symlink <<<
echo "Creating /lib/modules/${TARGET_KERNEL_VERSION}/build symlink for DKMS..."
mkdir -p /lib/modules/"${TARGET_KERNEL_VERSION}"/
ln -sfn "${KERNEL_SOURCE_DIR}" /lib/modules/"${TARGET_KERNEL_VERSION}"/build
echo "Symlink created. Verifying symlink target:"
ls -l /lib/modules/"${TARGET_KERNEL_VERSION}"/build


# 3. Clone Anbox Kernel Modules source
echo "Cloning Anbox kernel modules source from ${ANBOX_MODULES_REPO_URL}..."
ANBOX_MODULES_REPO_DIR="/tmp/anbox-modules-repo"
git clone --depth 1 "${ANBOX_MODULES_REPO_URL}" "${ANBOX_MODULES_REPO_DIR}"
cd "${ANBOX_MODULES_REPO_DIR}"

if [ -n "${ANBOX_MODULES_REPO_COMMIT}" ]; then
    echo "Checking out specific commit: ${ANBOX_MODULES_REPO_COMMIT}"
    git checkout "${ANBOX_MODULES_REPO_COMMIT}"
fi

# 4. Copy module sources to /usr/src/ and use dkms to build and install
echo "Copying module sources to /usr/src/ and building/installing with DKMS..."
TEMP_SRC_DIRS=()

for i in "${!ANBOX_SOURCE_DIRS[@]}"; do
    SOURCE_DIR="${ANBOX_SOURCE_DIRS[$i]}"
    DKMS_NAME="${DKMS_MODULE_NAMES[$i]}"
    DKMS_VERSION="${DKMS_MODULE_VERSIONS[$i]}"
    MODULE_PATH="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"

    echo "  - Processing ${SOURCE_DIR} (DKMS: ${DKMS_NAME}/${DKMS_VERSION})..."
    cp -rT "${SOURCE_DIR}" "${MODULE_PATH}"
    TEMP_SRC_DIRS+=("${MODULE_PATH}")

    echo "Attempting DKMS build for ${DKMS_NAME}/${DKMS_VERSION} (verbose output follows)..."
    # Build with --kernelsourcedir pointing to the *pulled* kernel-devel headers
    # and --arch x86_64 for clarity.
    dkms build "${DKMS_NAME}/${DKMS_VERSION}" --kernelsourcedir "${KERNEL_SOURCE_DIR}" --arch x86_64 --verbose
    
    BUILD_LOG_PATH="/var/lib/dkms/${DKMS_NAME}/${DKMS_VERSION}/build/make.log"
    if [ -f "${BUILD_LOG_PATH}" ]; then
        echo "DKMS build log for ${DKMS_NAME} at ${BUILD_LOG_PATH}:"
        cat "${BUILD_LOG_PATH}"
    else
        echo "DKMS build log not found at ${BUILD_LOG_PATH}."
    fi
    
    echo "Attempting DKMS install for ${DKMS_NAME}/${DKMS_VERSION}..."
    # Install for the TARGET_KERNEL_VERSION (the running kernel)
    dkms install "${DKMS_NAME}/${DKMS_VERSION}"

done
echo "All specified kernel modules built and installed via DKMS."

# 5. Update kernel module dependencies
echo "Running depmod -a..."
depmod -a "${TARGET_KERNEL_VERSION}"
echo "depmod complete."

# 6. Install configuration files (specific to Anbox)
echo "Installing Anbox configuration files..."
cp anbox.conf /etc/modules-load.d/
cp 99-anbox.rules /lib/udev/rules.d/
echo "Anbox configuration files installed."

# 7. Cleanup temporary build dependencies
remove_temp_build_deps

# 8. Clean up source directories
echo "Cleaning up source directories..."
rm -rf "${ANBOX_MODULES_REPO_DIR}"
for dir in "${TEMP_SRC_DIRS[@]}"; do
    rm -rf "${dir}"
done
rm -rf "${KERNEL_RPM_DIR}" # Clean up the pulled akmods content
echo "Source directories cleaned up."

echo "build_kernel_modules.sh finished (completed build)."
